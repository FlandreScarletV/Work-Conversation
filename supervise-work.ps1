$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = $PSScriptRoot
$dataDir = Join-Path $root '.runtime\data'
$stopFile = Join-Path $dataDir 'work.stop'
$pidFile = Join-Path $dataDir 'work-supervisor.pid'
$logFile = Join-Path $dataDir 'work-supervisor.log'
$connect = Join-Path $root 'connect-tunnel.ps1'
$env:TEMP = $dataDir
$env:TMP = $dataDir

$mutex = New-Object System.Threading.Mutex($false, 'Local\WorkConversationTunnelSupervisor')
$owned = $false
try {
    try { $owned = $mutex.WaitOne(0) }
    catch [System.Threading.AbandonedMutexException] { $owned = $true }
    if (-not $owned) { return }

    [IO.File]::WriteAllText($pidFile, [string]$PID, [Text.Encoding]::ASCII)
    $recentFailures = 0
    while (-not (Test-Path -LiteralPath $stopFile)) {
        $started = [DateTimeOffset]::Now
        try {
            & $connect
            $outcome = 'Tunnel process exited.'
        }
        catch {
            $outcome = 'Tunnel launch or process failed.'
        }
        if (Test-Path -LiteralPath $stopFile) { break }
        if (([DateTimeOffset]::Now - $started).TotalSeconds -ge 120) {
            $recentFailures = 0
        }
        $recentFailures++
        if ($recentFailures -ge 5) {
            Add-Content -LiteralPath $logFile -Value ("{0:o} {1} Stopped after five rapid failures; inspect profile and saved key." -f [DateTimeOffset]::Now, $outcome)
            break
        }
        $delay = [Math]::Min(60, 5 * [Math]::Pow(2, [Math]::Min($recentFailures - 1, 4)))
        Add-Content -LiteralPath $logFile -Value ("{0:o} {1} Restarting in {2}s." -f [DateTimeOffset]::Now, $outcome, $delay)
        for ($remaining = [int]$delay; $remaining -gt 0 -and -not (Test-Path -LiteralPath $stopFile); $remaining--) {
            Start-Sleep -Seconds 1
        }
    }
}
finally {
    if ($owned) {
        if (Test-Path -LiteralPath $pidFile) { Remove-Item -LiteralPath $pidFile -Force }
        $mutex.ReleaseMutex()
    }
    $mutex.Dispose()
}
