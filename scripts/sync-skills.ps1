#requires -Version 7
[CmdletBinding()]
param(
    [switch]$DryRun,
    [string]$Upstream   # clone of mattpocock/skills; default: $env:AI_SKILLS_UPSTREAM, else a per-OS path below
)

$ErrorActionPreference = 'Stop'
$Repo      = Split-Path -Parent $PSScriptRoot
if (-not $Upstream) {
    $Upstream = if ($env:AI_SKILLS_UPSTREAM) { $env:AI_SKILLS_UPSTREAM }
                elseif ($IsWindows)          { 'C:\git\mattpocock-ai-skills' }
                else                         { Join-Path $HOME 'git/mattpocock-ai-skills' }
}
$Target    = Join-Path $HOME '.agents/skills'
$Manifest  = Join-Path $Repo 'skills-manifest.txt'
$Mine      = Join-Path $Repo 'skills/my-skills'
$Marker    = '.managed-by-ai-workstation'

function Get-SkillName([string]$dir) {
    $m = Get-Content (Join-Path $dir 'SKILL.md') -TotalCount 20 |
         Select-String -Pattern '^name:\s*(.+)$' | Select-Object -First 1
    if (-not $m) { throw "No 'name:' in frontmatter of $(Join-Path $dir 'SKILL.md')" }
    return $m.Matches[0].Groups[1].Value.Trim().Trim('"', "'")
}

# 1. Desired set: leaf-name -> source dir
$want = [ordered]@{}
Get-Content $Manifest |
    ForEach-Object { ($_ -replace '#.*$', '').Trim() } |
    Where-Object { $_ } |
    ForEach-Object {
        $src = Join-Path (Join-Path $Upstream 'skills') $_
        if (-not (Test-Path (Join-Path $src 'SKILL.md'))) { throw "Missing upstream skill: $_" }
        $want[(Split-Path -Leaf $src)] = $src
    }

if (Test-Path $Mine) {
    Get-ChildItem $Mine -Directory | Where-Object { Test-Path (Join-Path $_.FullName 'SKILL.md') } |
        ForEach-Object { $want[$_.Name] = $_.FullName }
}

# 2. Validate: frontmatter name must equal directory name (Kilo requires it)
foreach ($k in $want.Keys) {
    $n = Get-SkillName $want[$k]
    if ($n -ne $k) { throw "Skill '$k': frontmatter name is '$n' (must match folder)" }
}

Write-Host "Upstream commit: $(git -C $Upstream rev-parse --short HEAD)"
Write-Host "Skills to install ($($want.Count)): $($want.Keys -join ', ')"
if ($DryRun) { return }

# 3. Mirror each wanted skill (works the same on Windows and Linux)
function Copy-Skill([string]$From, [string]$To) {   # skips folders named 'agents' or '.git' at any depth
    if (Test-Path -LiteralPath $To) { Remove-Item -LiteralPath $To -Recurse -Force }
    New-Item -ItemType Directory -Force $To | Out-Null
    $root = (Resolve-Path -LiteralPath $From).Path
    Get-ChildItem -LiteralPath $root -Recurse -Force -File | ForEach-Object {
        $rel = [IO.Path]::GetRelativePath($root, $_.FullName)
        if ($rel -split '[\\/]' | Select-Object -SkipLast 1 | Where-Object { $_ -in 'agents', '.git' }) { return }
        $dest = Join-Path $To $rel
        New-Item -ItemType Directory -Force (Split-Path -Parent $dest) | Out-Null
        Copy-Item -LiteralPath $_.FullName -Destination $dest -Force
    }
}

New-Item -ItemType Directory -Force $Target | Out-Null
foreach ($k in $want.Keys) {
    $dst = Join-Path $Target $k
    Copy-Skill $want[$k] $dst
    New-Item -ItemType File -Force (Join-Path $dst $Marker) | Out-Null
}

# 4. Remove stale skills that this script installed earlier (never touches skills you added by hand)
Get-ChildItem $Target -Directory | Where-Object {
    (Test-Path (Join-Path $_.FullName $Marker)) -and -not $want.Contains($_.Name)
} | ForEach-Object { Write-Host "Removing stale: $($_.Name)"; Remove-Item $_.FullName -Recurse -Force }

# 5. Security report: anything executable inside the installed skills
Write-Host "`n--- Embedded shell commands in SKILL.md (Kilo runs these for trusted global skills) ---"
Get-ChildItem $Target -Recurse -Filter SKILL.md |
    Select-String -Pattern '!`' | ForEach-Object { "{0}:{1}: {2}" -f $_.Path, $_.LineNumber, $_.Line.Trim() }
Write-Host "`n--- Script files bundled with skills ---"
Get-ChildItem $Target -Recurse -Include *.sh, *.ps1, *.py, *.js, *.mjs, *.cjs, *.bat, *.cmd |
    ForEach-Object { $_.FullName }
Write-Host "`nDone. Review anything listed above before trusting it."