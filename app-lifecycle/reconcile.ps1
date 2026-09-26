$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Split-Path $PSScriptRoot -Parent
$dataDir = Join-Path $root '.runtime\data'
$pathsFile = Join-Path $dataDir 'app-paths.json'
$logFile = Join-Path $dataDir 'app-lifecycle.log'
if (-not (Test-Path -LiteralPath $pathsFile -PathType Leaf)) { return }

$paths = @(Get-Content -LiteralPath $pathsFile -Raw -Encoding UTF8 | ConvertFrom-Json)
if ($paths.Count -eq 0) { return }

function Write-Event([string]$message) {
    Add-Content -LiteralPath $logFile -Encoding UTF8 -Value ('{0:o} {1}' -f [DateTimeOffset]::Now, $message)
}

function Test-AppPresent {
    foreach ($process in @(Get-CimInstance Win32_Process -Filter "Name = 'ChatGPT.exe'")) {
        foreach ($path in $paths) {
            if ([string]$process.ExecutablePath -ieq [string]$path) { return $true }
        }
    }
    return $false
}

try {
    if (Test-AppPresent) {
        & (Join-Path $root 'start-work-background.ps1') | Out-Null
        Write-Event 'Work Conversation start requested.'
    }
    else {
        Start-Sleep -Seconds 12
        if (-not (Test-AppPresent)) {
            & (Join-Path $root 'stop-work-background.ps1') | Out-Null
            Write-Event 'Work Conversation stop requested.'
        }
    }
}
catch {
    Write-Event ('Reconciliation failed: ' + $_.Exception.Message)
    throw
}
