#requires -Version 7
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)][string]$Workspace,
    [switch]$Docs   # also test the Squid docs proxy (starts it)
)
. (Join-Path $PSScriptRoot 'lib.ps1')

$ws = (Resolve-Path -LiteralPath $Workspace).Path
Assert-Machine
Initialize-Networks
Start-Gateway
if ($Docs) { Start-Squid }

$run    = Get-AgentRunArgs -Workspace $ws -Docs:$Docs
$inside = Join-Path $PSScriptRoot 'verify-inside.sh'
& podman @run -v (Get-BindArg $inside '/verify.sh') $script:AgentImage bash /verify.sh
exit $LASTEXITCODE