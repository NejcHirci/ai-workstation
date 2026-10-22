Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:RepoRoot    = Split-Path -Parent $PSScriptRoot
$script:AgentImage  = 'localhost/ai-agent:latest'
$script:GatewayImg  = 'docker.io/nginxinc/nginx-unprivileged:1.27-alpine'   # pin to a digest once verified
$script:SquidImg    = 'docker.io/ubuntu/squid:latest'                       # pin to a digest once verified
$script:NetInternal = 'agent-internal'
$script:NetEgress   = 'agent-egress'
$script:GatewayIp   = '10.89.77.10'
$script:SquidIp     = '10.89.77.11'
$script:Controllers = $null   # cgroup controllers delegated to rootless Podman (filled lazily)
$script:SeLinux     = $null   # $true when SELinux is enforcing (Linux only; filled lazily)

function Resolve-RepoPath([string]$Relative) {   # Relative uses '/' on every OS; the result uses the native separator
    return [IO.Path]::GetFullPath((Join-Path $script:RepoRoot $Relative))
}

function Get-BindArg([string]$Source, [string]$Target, [string]$Mode = 'ro') {   # value for podman -v
    if ($null -eq $script:SeLinux) {
        $script:SeLinux = $false
        if ($IsLinux -and (Get-Command getenforce -ErrorAction SilentlyContinue)) {
            $script:SeLinux = ((& getenforce) -eq 'Enforcing')
        }
    }
    $opts = if ($script:SeLinux) { "$Mode,z" } else { $Mode }   # ',z' relabels the host path for containers
    return "${Source}:${Target}:${opts}"
}

function Invoke-Podman {
    $global:LASTEXITCODE = 0
    & podman @args
    if ($LASTEXITCODE -ne 0) { throw "podman $($args -join ' ') failed with exit code $LASTEXITCODE" }
}

function Test-Podman {   # true when the command succeeds; output is discarded
    & podman @args *> $null
    return ($LASTEXITCODE -eq 0)
}

function Assert-Machine {
    if (Test-Podman info) { return }
    if ($IsWindows -or $IsMacOS) {   # Podman runs inside a VM here
        Write-Host 'Starting Podman machine...'
        Invoke-Podman machine start
    } else {
        throw 'Podman is not usable. Run "podman info" to see why (see GUIDE.md section 3L).'
    }
}

function Get-LimitArgs {   # emits --pids-limit/--memory/--cpus only for cgroup controllers the machine delegates
    param([int]$PidsLimit, [string]$Memory, [double]$Cpus)
    if ($null -eq $script:Controllers) {
        $raw = (& podman info --format '{{range .Host.CgroupControllers}}{{.}} {{end}}') -join ' '
        $script:Controllers = @($raw -split '\s+' | Where-Object { $_ })
        $missing = @('pids', 'memory', 'cpu') | Where-Object { $_ -notin $script:Controllers }
        if ($missing) {
            Write-Warning "Cgroup controllers not delegated to rootless Podman: $($missing -join ', '). Those limits are skipped (see GUIDE.md, Troubleshooting)."
        }
    }
    $l = @()
    if ($PidsLimit -and 'pids'   -in $script:Controllers) { $l += @('--pids-limit', "$PidsLimit") }
    if ($Memory    -and 'memory' -in $script:Controllers) { $l += @('--memory', $Memory) }
    if ($Cpus      -and 'cpu'    -in $script:Controllers) { $l += @('--cpus', "$Cpus") }
    return $l
}

function Initialize-Networks {
    if (-not (Test-Podman network exists $script:NetInternal)) {
        Invoke-Podman network create --internal --disable-dns --subnet 10.89.77.0/24 $script:NetInternal | Out-Null
    }
    if (-not (Test-Podman network exists $script:NetEgress)) {
        Invoke-Podman network create --subnet 10.89.78.0/24 $script:NetEgress | Out-Null
    }
}

function Start-Gateway {
    param([switch]$Restart)
    if ($Restart) { Test-Podman rm -f llm-gateway | Out-Null }
    $running = & podman ps --filter 'name=^llm-gateway$' --format '{{.Names}}'
    if ($running) { return }
    Test-Podman rm -f llm-gateway | Out-Null

    if (-not (Test-Podman secret exists cortecs_key)) { throw 'Secret cortecs_key missing. Run scripts/set-key.ps1' }
    $tpl = Resolve-RepoPath 'images/gateway/default.conf.template'

    $limits = Get-LimitArgs -PidsLimit 256 -Memory '256m'
    Invoke-Podman run -d --name llm-gateway `
        --network "$($script:NetInternal):ip=$($script:GatewayIp)" --network $script:NetEgress `
        --read-only --tmpfs /tmp --tmpfs '/etc/nginx/conf.d:rw,mode=1777' `
        --cap-drop=all --security-opt no-new-privileges @limits `
        --secret 'cortecs_key,type=env,target=CORTECS_API_KEY' `
        -e 'NGINX_ENVSUBST_FILTER=^CORTECS_' `
        -v (Get-BindArg $tpl '/etc/nginx/templates/default.conf.template') `
        $script:GatewayImg | Out-Null

    for ($i = 0; $i -lt 20; $i++) {
        if (Test-Podman exec llm-gateway wget -q -O- http://127.0.0.1:8080/healthz) { return }
        Start-Sleep -Milliseconds 500
    }
    Invoke-Podman logs llm-gateway
    throw 'Gateway did not become healthy.'
}

function Start-Squid {
    $running = & podman ps --filter 'name=^egress-squid$' --format '{{.Names}}'
    if ($running) { return }
    Test-Podman rm -f egress-squid | Out-Null
    $conf  = Resolve-RepoPath 'images/squid/squid.conf'
    $allow = Resolve-RepoPath 'images/squid/allowlist.txt'
    $limits = Get-LimitArgs -PidsLimit 256 -Memory '512m'
    Invoke-Podman run -d --name egress-squid `
        --network "$($script:NetInternal):ip=$($script:SquidIp)" --network $script:NetEgress `
        --security-opt no-new-privileges @limits `
        -v (Get-BindArg $conf '/etc/squid/squid.conf') -v (Get-BindArg $allow '/etc/squid/allowlist.txt') `
        $script:SquidImg | Out-Null
}

function Get-AgentRunArgs {
    param(
        [Parameter(Mandatory)][string]$Workspace,
        [switch]$Docs,
        [switch]$Interactive,
        [string]$Name
    )
    $proj = Split-Path -Leaf $Workspace
    $safe = $proj -replace '[^a-zA-Z0-9_.-]', '_'
    if (-not $Name) { $Name = "agent-$safe-$(Get-Random -Maximum 9999)" }

    $a = @('run', '--rm', '--init')
    if ($Interactive) { $a += '-it' }
    $a += @('--name', $Name, '--hostname', 'agent')

    # Identity and hardening
    $a += @('--userns=keep-id:uid=1000,gid=1000', '--user', '1000:1000',
            '--read-only', '--cap-drop=all', '--security-opt', 'no-new-privileges',
            '--tmpfs', '/tmp:rw,exec,size=2g')
    $a += Get-LimitArgs -PidsLimit 4096 -Memory '12g' -Cpus 6

    # Network: internal only, no DNS, gateway by static IP
    $a += @('--network', $script:NetInternal,
            '--add-host', "llm-gateway:$($script:GatewayIp)", '--dns=none')

    # Workspace (read-write) with protected sub-paths (read-only overlays)
    $a += @('-v', (Get-BindArg $Workspace '/workspace' 'rw'), '-w', '/workspace', '-e', "PROJECT_NAME=$safe")
    $git = Join-Path $Workspace '.git'
    if (Test-Path -LiteralPath $git -PathType Container) {
        foreach ($p in 'hooks', 'config') {
            $src = Join-Path $git $p
            if (Test-Path -LiteralPath $src) { $a += @('-v', (Get-BindArg $src "/workspace/.git/$p")) }
        }
    } else {
        Write-Warning '.git is not a directory (worktree or submodule?). Hooks and config are NOT protected.'
    }
    foreach ($d in '.vscode', '.devcontainer', '.husky', '.githooks') {
        $src = Join-Path $Workspace $d
        if (Test-Path -LiteralPath $src -PathType Container) { $a += @('-v', (Get-BindArg $src "/workspace/$d")) }
    }

    # Shared skills (read-only), config (read-only), state and build cache (named volumes)
    $skills = [IO.Path]::GetFullPath((Join-Path $HOME '.agents/skills'))
    if (-not (Test-Path -LiteralPath $skills)) { New-Item -ItemType Directory -Force $skills | Out-Null }
    $cfg    = Resolve-RepoPath 'config/opencode'
    $a += @('-v', (Get-BindArg $skills '/home/agent/.agents/skills'),
            '-v', (Get-BindArg $cfg '/etc/opencode'),
            '-v', 'agent-home:/home/agent',
            '-v', 'agent-cache:/cache')
    $agentsDir = Join-Path $cfg 'agents'
    if (Test-Path -LiteralPath $agentsDir -PathType Container) {
        $a += @('-v', (Get-BindArg $agentsDir '/home/agent/.config/opencode/agents'))
    }

    if ($Docs) {
        $px = "http://$($script:SquidIp):3128"
        $no = "llm-gateway,$($script:GatewayIp)"
        $a += @('-e', "HTTPS_PROXY=$px", '-e', "https_proxy=$px", '-e', "NO_PROXY=$no", '-e', "no_proxy=$no")
    }
    return $a
}