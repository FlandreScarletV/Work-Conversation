$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = $PSScriptRoot
$dataDir = Join-Path $root '.runtime\data'
$profileDir = Join-Path $root '.runtime\profiles'
$pidFile = Join-Path $dataDir 'work-supervisor.pid'
$stopFile = Join-Path $dataDir 'work.stop'

if (-not (Test-Path -LiteralPath $pidFile -PathType Leaf)) {
    Write-Host 'No background supervisor is registered. Existing manual tunnels were not touched.'
    return
}
$supervisorPid = [int]([IO.File]::ReadAllText($pidFile).Trim())
$supervisor = Get-CimInstance Win32_Process -Filter "ProcessId = $supervisorPid"
if (-not $supervisor -or $supervisor.Name -ne 'powershell.exe' -or
    $supervisor.CommandLine -notlike '*supervise-work.ps1*') {
    throw 'Supervisor PID is stale or does not match; no process was stopped.'
}
[IO.File]::WriteAllText($stopFile, 'stop', [Text.Encoding]::ASCII)
$children = Get-CimInstance Win32_Process | Where-Object {
    $_.Name -eq 'tunnel-client.exe' -and
    $_.CommandLine -match 'run\s+--profile\s+work-conversation(?:\s|$)' -and
    $_.CommandLine -like ('*' + $profileDir + '*')
}
foreach ($child in $children) {
    if ($child.ParentProcessId -eq $supervisorPid) {
        Stop-Process -Id $child.ProcessId -ErrorAction Stop
    }
}
Write-Host 'Stop requested for the background Work Conversation tunnel only.'
