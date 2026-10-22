#requires -Version 7
[CmdletBinding()]
param([switch]$Prompt)   # always ask for the key instead of reading it from SecretStore
$ErrorActionPreference = 'Stop'

# Key source: SecretStore (secret name CortecsKey) when available, otherwise a hidden prompt.
$secure = $null
if (-not $Prompt -and (Get-Command Get-Secret -ErrorAction SilentlyContinue)) {
    try { $secure = Get-Secret -Name CortecsKey -ErrorAction Stop }
    catch { Write-Warning "No SecretStore entry 'CortecsKey' ($($_.Exception.Message)). Asking instead." }
}
if ($null -eq $secure) { $secure = Read-Host 'Cortecs API key for OpenCode' -AsSecureString }

$plain = if ($secure -is [securestring]) { (ConvertFrom-SecureString $secure -AsPlainText).Trim() } else { "$secure".Trim() }

$tmp = Join-Path ([IO.Path]::GetTempPath()) ('ck-' + [guid]::NewGuid().ToString('N'))
try {
    # Create the file first and restrict it (Linux/macOS) before the key is written.
    New-Item -ItemType File -Path $tmp | Out-Null
    if (-not $IsWindows) { [IO.File]::SetUnixFileMode($tmp, [IO.UnixFileMode]'UserRead, UserWrite') }
    # No trailing newline: it would end up inside the Authorization header.
    [IO.File]::WriteAllText($tmp, $plain)
    podman secret create --replace cortecs_key $tmp
    if ($LASTEXITCODE -ne 0) { throw 'podman secret create failed' }
} finally {
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force }
    Remove-Variable plain, secure -ErrorAction SilentlyContinue
}
Write-Host 'Secret cortecs_key stored in Podman.'
