param([switch]$CheckOnly, [switch]$FromHook)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = $PSScriptRoot
$dataDir = Join-Path $root '.runtime\data'
$supervisor = Join-Path $root 'supervise-work.ps1'
$connect = Join-Path $root 'connect-tunnel.ps1'
$profileDir = Join-Path $root '.runtime\profiles'

if (-not (Test-Path -LiteralPath $supervisor -PathType Leaf)) { throw 'Supervisor script is missing.' }
if (-not (Test-Path -LiteralPath $connect -PathType Leaf)) { throw 'Tunnel script is missing.' }
if (-not (Test-Path -LiteralPath (Join-Path $dataDir 'control-plane-api-key.dpapi') -PathType Leaf)) {
    throw 'Saved runtime key is missing. Run connect-tunnel.ps1 interactively first.'
}
if (-not (Test-Path -LiteralPath (Join-Path $profileDir 'work-conversation.yaml') -PathType Leaf)) {
    throw 'Tunnel profile is missing. Run connect-tunnel.ps1 interactively first.'
}

if (-not $FromHook) {
    $existing = Get-CimInstance Win32_Process | Where-Object {
        $_.Name -eq 'tunnel-client.exe' -and
        $_.CommandLine -match 'run\s+--profile\s+work-conversation(?:\s|$)' -and
        $_.CommandLine -like ('*' + $profileDir + '*')
    }
    if ($existing) {
        Write-Host 'Work Conversation tunnel is already running; no second copy was started.'
        if (-not $CheckOnly) { Write-Host 'Close the manual tunnel before switching to background supervision.' }
        return
    }
}

if ($CheckOnly) {
    Write-Host 'Background launcher prerequisites passed; no process was started.'
    return
}

New-Item -ItemType Directory -Path $dataDir -Force | Out-Null
$stopFile = Join-Path $dataDir 'work.stop'
if (Test-Path -LiteralPath $stopFile) { Remove-Item -LiteralPath $stopFile -Force }
$powershell = (Get-Command powershell.exe -CommandType Application -ErrorAction Stop).Source
$proc = Start-Process -FilePath $powershell -ArgumentList @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $supervisor + '"')
) -WindowStyle Hidden -PassThru
Write-Host "Work Conversation supervisor started in background (PID $($proc.Id))."
Write-Host 'Use stop-work-background.ps1 to stop it.'
