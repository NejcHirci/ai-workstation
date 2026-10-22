#requires -Version 7
<#
.SYNOPSIS
  Add, remove or list domains in the Squid allowlist and reload Squid without a restart.

.EXAMPLE
  allow-site.ps1 doc.qt.io                  # permanent, includes all subdomains
  allow-site.ps1 https://docs.example.org/a/b -Minutes 60   # accepts a URL, expires in 60 minutes
  allow-site.ps1 www.example.org -Exact     # only this exact host
  allow-site.ps1 docs.example.org -Remove
  allow-site.ps1 -List
  allow-site.ps1 -Prune                     # drop expired entries

.NOTES
  Run this on the host, never inside the agent container. The agent only sees the allowlist
  read-only through the proxy and cannot change it.
  Expiry is enforced when this script runs (any mode), not by a background timer.
#>
[CmdletBinding(DefaultParameterSetName = 'Add')]
param(
    [Parameter(ParameterSetName = 'Add',    Mandatory, Position = 0)]
    [Parameter(ParameterSetName = 'Remove', Mandatory, Position = 0)]
    [string[]]$Domain,

    [Parameter(ParameterSetName = 'Add')][switch]$Exact,                       # no subdomains
    [Parameter(ParameterSetName = 'Add')][ValidateRange(1, 10080)][int]$Minutes, # temporary entry
    [Parameter(ParameterSetName = 'Add')][switch]$Force,                       # allow risky upload/hosting domains

    [Parameter(ParameterSetName = 'Remove', Mandatory)][switch]$Remove,
    [Parameter(ParameterSetName = 'List',   Mandatory)][switch]$List,
    [Parameter(ParameterSetName = 'Prune',  Mandatory)][switch]$Prune
)

. (Join-Path $PSScriptRoot 'lib.ps1')

# "pwsh -File" passes a comma list as one string; accept "a.org,b.org" in every invocation style.
if ($Domain) { $Domain = @($Domain | ForEach-Object { $_ -split '[,\s]+' } | Where-Object { $_ }) }

$allowFile  = Resolve-RepoPath 'images/squid/allowlist.txt'
$expiryFile = Resolve-RepoPath 'images/squid/allowlist.expiry.json'   # host only, not mounted

# Domains where an approval would also allow uploading data (paste sites, file hosts, tunnels, user-content hosting).
$risky = @(
    'github.com', 'gist.github.com', 'gitlab.com', 'bitbucket.org', 'pastebin.com', 'hastebin.com',
    'transfer.sh', 'file.io', 'drive.google.com', 'docs.google.com', 'googleusercontent.com',
    'storage.googleapis.com', 'dropbox.com', 'onedrive.live.com', 'amazonaws.com',
    'blob.core.windows.net', 'discord.com', 'slack.com', 'telegram.org', 'webhook.site',
    'requestbin.com', 'ngrok.io', 'ngrok-free.app', 'workers.dev', 'pages.dev', 'herokuapp.com',
    'vercel.app', 'netlify.app', 'huggingface.co'
)

# ---------- helpers ----------

function Read-Lines {
    if (Test-Path -LiteralPath $allowFile) { return @(Get-Content -LiteralPath $allowFile) }
    return @()
}

function Get-Entries([string[]]$Lines) {
    return @($Lines | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') })
}

function Write-Lines([string[]]$Lines) {
    # Overwrite in place (same inode) so the bind mount in the Squid container sees the change.
    $text = ($Lines -join "`n") + "`n"
    [System.IO.File]::WriteAllText($allowFile, $text, [System.Text.UTF8Encoding]::new($false))
}

function Read-Expiry {
    $h = @{}
    if (Test-Path -LiteralPath $expiryFile) {
        $obj = Get-Content -LiteralPath $expiryFile -Raw | ConvertFrom-Json
        if ($obj) { $obj.PSObject.Properties | ForEach-Object { $h[$_.Name] = [DateTimeOffset]::FromUnixTimeSeconds([long]$_.Value).UtcDateTime } }
    }
    return $h
}

function Write-Expiry([hashtable]$Map) {
    $o = [ordered]@{}
    foreach ($k in ($Map.Keys | Sort-Object)) { $o[$k] = [DateTimeOffset]::new($Map[$k].ToUniversalTime()).ToUnixTimeSeconds() }   # unix seconds: no date/culture parsing issues
    ($o | ConvertTo-Json) | Set-Content -LiteralPath $expiryFile -Encoding utf8NoBOM
}

function ConvertTo-HostName([string]$InputText) {
    $s = $InputText.Trim().ToLowerInvariant()
    if ($s -match '^[a-z][a-z0-9+.-]*://') {
        try { $s = ([uri]$s).DnsSafeHost } catch { throw "Cannot parse URL: $InputText" }
    }
    $s = $s.TrimStart('.').TrimEnd('.')
    if ($s -notmatch '^(?=.{1,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]{1,62}$') {
        throw "'$InputText' is not a valid host name (no wildcards, ports, paths or IP addresses)."
    }
    return $s
}

function Test-Risky([string]$HostName) {
    foreach ($r in $risky) {
        if ($HostName -eq $r -or $HostName.EndsWith(".$r") -or $r.EndsWith(".$HostName")) { return $r }
    }
    return $null
}

function Test-Covered([string]$Entry, [string[]]$Existing) {
    $name = $Entry.TrimStart('.')
    $wild = $Entry.StartsWith('.')
    foreach ($e in $Existing) {
        if ($e.StartsWith('.')) {
            $base = $e.Substring(1)
            if ($name -eq $base -or $name.EndsWith(".$base")) { return $true }
        } elseif (-not $wild -and $e -eq $name) { return $true }
    }
    return $false
}

function Remove-Expired {
    # Returns $true if anything was removed.
    $map = Read-Expiry
    if ($map.Count -eq 0) { return $false }
    $now = [datetime]::UtcNow
    $gone = @($map.Keys | Where-Object { $map[$_].ToUniversalTime() -le $now })
    if (-not $gone) { return $false }
    $lines = Read-Lines | Where-Object { $_.Trim() -notin $gone }
    Write-Lines @($lines)
    foreach ($g in $gone) { $map.Remove($g); Write-Host "Expired and removed: $g" }
    Write-Expiry $map
    return $true
}

function Update-Squid {
    if (-not (Test-Podman info)) { Write-Host 'Podman machine is not running; the list applies when Squid next starts.'; return }
    $running = & podman ps --filter 'name=^egress-squid$' --format '{{.Names}}'
    if (-not $running) { Write-Host 'Squid is not running; the list applies on next start (agent.ps1 -Docs).'; return }

    Invoke-Podman exec egress-squid squid -k reconfigure 2>&1 | Out-Null
    # Confirm the container sees the same file contents (a stale bind mount would show an old copy).
    $inside = Get-Entries @(& podman exec egress-squid cat /etc/squid/allowlist.txt)
    $onDisk = Get-Entries (Read-Lines)
    if ((($inside | Sort-Object) -join '|') -ne (($onDisk | Sort-Object) -join '|')) {
        Write-Warning 'Squid sees a different allowlist than the file on disk. Run: podman rm -f egress-squid  (agent.ps1 -Docs recreates it).'
    } else {
        Write-Host 'Squid reloaded and in sync.'
    }
}

# ---------- main ----------

$changed = Remove-Expired

switch ($PSCmdlet.ParameterSetName) {
    'List' {
        $map = Read-Expiry
        $entries = Get-Entries (Read-Lines)
        if (-not $entries) { Write-Host '(allowlist is empty)' }
        foreach ($e in $entries) {
            $exp = if ($map.ContainsKey($e)) { "expires $($map[$e].ToLocalTime().ToString('yyyy-MM-dd HH:mm'))" } else { 'permanent' }
            '{0,-40} {1}' -f $e, $exp
        }
    }

    'Prune' { if (-not $changed) { Write-Host 'Nothing to prune.' } }

    'Remove' {
        $map = Read-Expiry
        $lines = Read-Lines
        foreach ($d in $Domain) {
            $h = ConvertTo-HostName $d
            $targets = @($h, ".$h")
            $hit = @($lines | Where-Object { $_.Trim() -in $targets })
            if (-not $hit) { Write-Warning "$h is not in the allowlist."; continue }
            $lines = @($lines | Where-Object { $_.Trim() -notin $targets })
            foreach ($t in $targets) { $map.Remove($t) }
            Write-Host "Removed: $h"
            $changed = $true
        }
        if ($changed) { Write-Lines $lines; Write-Expiry $map }
    }

    'Add' {
        $map = Read-Expiry
        $lines = Read-Lines
        foreach ($d in $Domain) {
            $h = ConvertTo-HostName $d
            $entry = if ($Exact) { $h } else { ".$h" }

            $bad = Test-Risky $h
            if ($bad -and -not $Force) {
                Write-Warning "Refusing ${h}: it overlaps '$bad', where the agent could also upload data. Re-run with -Force only if you accept that."
                continue
            }

            $existing = Get-Entries $lines
            $isPermanentHit = (Test-Covered $entry $existing) -and -not ($map.ContainsKey($entry))
            # An exact duplicate with an expiry can be extended or made permanent; a permanent cover is left alone.
            if ($isPermanentHit -and $entry -notin $existing) {
                Write-Host "Already allowed by a broader entry: $h"
                continue
            }
            if ($entry -in $existing -and -not $map.ContainsKey($entry)) {
                Write-Host "Already allowed (permanent): $entry"
                continue
            }

            if ($entry -notin $existing) { $lines += $entry; $changed = $true }

            if ($Minutes) {
                $map[$entry] = [datetime]::UtcNow.AddMinutes($Minutes)
                Write-Host "Allowed $entry for $Minutes minute(s) (until $($map[$entry].ToLocalTime().ToString('HH:mm')))."
            } else {
                $map.Remove($entry)
                Write-Host "Allowed $entry permanently."
            }
            $changed = $true
        }
        if ($changed) { Write-Lines $lines; Write-Expiry $map }
    }
}

if ($changed) { Update-Squid }
