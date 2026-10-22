#requires -Version 7
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)][string]$Workspace,
    [switch]$Docs,              # tier 1: also start squid with the docs allowlist
    [switch]$RestartGateway,    # re-resolve api.cortecs.ai / reload template
    [switch]$Shell,             # open bash instead of opencode
    [Parameter(ValueFromRemainingArguments)][string[]]$AgentArgs
)
. (Join-Path $PSScriptRoot 'lib.ps1')

$ws = (Resolve-Path -LiteralPath $Workspace).Path
Assert-Machine
Initialize-Networks
Start-Gateway -Restart:$RestartGateway
if ($Docs) { Start-Squid }

$run = Get-AgentRunArgs -Workspace $ws -Docs:$Docs -Interactive
$cmd = if ($Shell) { @('bash') } else { @('opencode') + $AgentArgs }
& podman @run $script:AgentImage @cmd