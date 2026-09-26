param(
    [string]$TunnelClient,
    [string]$CodexDataRoot,
    [string]$TunnelId,
    [switch]$CheckOnly,
    [switch]$ReplaceSavedKey,
    [switch]$DoctorOnly
)

$ErrorActionPreference = 'Stop'
$pluginRoot = $PSScriptRoot
$entry = Join-Path $pluginRoot 'plugins\work-conversation\server.mjs'
$runtimeRoot = Join-Path $pluginRoot '.runtime'
$profileDir = Join-Path $runtimeRoot 'profiles'
$dataDir = Join-Path $runtimeRoot 'data'
$profileName = 'work-conversation'
$savedKeyFile = Join-Path $dataDir 'control-plane-api-key.dpapi'
$settingsFile = Join-Path $dataDir 'local-settings.json'

if ($CheckOnly -and ($ReplaceSavedKey -or $DoctorOnly)) {
    throw 'CheckOnly cannot be combined with ReplaceSavedKey or DoctorOnly.'
}

if (Test-Path -LiteralPath $settingsFile -PathType Leaf) {
    $settings = Get-Content -LiteralPath $settingsFile -Raw | ConvertFrom-Json
    if (-not $TunnelClient) { $TunnelClient = $settings.tunnelClient }
    if (-not $CodexDataRoot) { $CodexDataRoot = $settings.codexDataRoot }
}
if (-not $TunnelClient) {
    $candidate = Get-Command tunnel-client -ErrorAction SilentlyContinue
    if ($candidate) { $TunnelClient = $candidate.Source }
}
if (-not $TunnelClient -or -not (Test-Path -LiteralPath $TunnelClient -PathType Leaf)) {
    throw 'tunnel-client.exe was not found. Pass its full path with -TunnelClient, or add tunnel-client to PATH.'
}
$node = Get-Command node -ErrorAction Stop
if (-not (Test-Path -LiteralPath $entry -PathType Leaf)) { throw "Missing MCP server: $entry" }
if (-not $CodexDataRoot) { $CodexDataRoot = $env:CODEX_CONVERSATION_ROOT }
if (-not $CodexDataRoot) { $CodexDataRoot = $env:CODEX_HOME }
if (-not $CodexDataRoot -or -not (Test-Path -LiteralPath (Join-Path $CodexDataRoot 'sessions') -PathType Container)) {
    throw 'Pass -CodexDataRoot pointing to the Codex data directory that contains sessions.'
}

& $node.Source --check $entry
if ($LASTEXITCODE -ne 0) { throw 'MCP server syntax check failed.' }
& $TunnelClient --version
if ($LASTEXITCODE -ne 0) { throw 'tunnel-client is unavailable.' }
Write-Host "Tunnel client: $TunnelClient"
Write-Host "Codex data: $CodexDataRoot"
if ($CheckOnly) {
    Write-Host 'Local prerequisites passed. No profile, credential, or tunnel was changed.'
    exit 0
}

New-Item -ItemType Directory -Path $profileDir, $dataDir -Force | Out-Null
$profile = Join-Path $profileDir "$profileName.yaml"
if (-not (Test-Path -LiteralPath $profile)) {
    if (-not $TunnelId) { $TunnelId = Read-Host 'Enter the NEW Work Conversation Tunnel ID (not an API key)' }
    if ($TunnelId -notmatch '^tunnel_[A-Za-z0-9_-]{10,}$') { throw 'Invalid Tunnel ID.' }
    $nodePath = $node.Source.Replace('\', '/')
    $entryPath = $entry.Replace('\', '/')
    $command = '"' + $nodePath + '" "' + $entryPath + '"'
    & $TunnelClient init --sample sample_mcp_stdio_local --profile $profileName --profile-dir $profileDir --tunnel-id $TunnelId --mcp-command $command --health-listen-addr '127.0.0.1:0'
    if ($LASTEXITCODE -ne 0) { throw 'Tunnel profile initialization failed.' }
}

$previousRoot = $env:CODEX_CONVERSATION_ROOT
$previousTemp = $env:TEMP
$previousTmp = $env:TMP
$hadKey = Test-Path Env:CONTROL_PLANE_API_KEY
$originalKey = if ($hadKey) { $env:CONTROL_PLANE_API_KEY } else { $null }
$secureKey = $null
$saveAfterDoctor = $false
$secretPointer = [IntPtr]::Zero
try {
    $env:CODEX_CONVERSATION_ROOT = (Resolve-Path -LiteralPath $CodexDataRoot).Path
    $env:TEMP = $dataDir
    $env:TMP = $dataDir

    Add-Type -AssemblyName System.Security -ErrorAction Stop
    if ($ReplaceSavedKey) {
        $secureKey = Read-Host 'Enter replacement Platform runtime API key (hidden)' -AsSecureString
        $saveAfterDoctor = $true
    }
    elseif ($hadKey) {
        if (-not (Test-Path -LiteralPath $savedKeyFile -PathType Leaf)) {
            $saveAfterDoctor = $true
        }
    }
    elseif (Test-Path -LiteralPath $savedKeyFile -PathType Leaf) {
        $cipherBytes = $null
        $plainBytes = $null
        try {
            $sealed = [IO.File]::ReadAllText($savedKeyFile, [Text.Encoding]::ASCII).Trim()
            $cipherBytes = [Convert]::FromBase64String($sealed)
            $plainBytes = [Security.Cryptography.ProtectedData]::Unprotect(
                $cipherBytes, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser
            )
            $env:CONTROL_PLANE_API_KEY = [Text.Encoding]::UTF8.GetString($plainBytes)
        }
        catch { throw 'Saved key cannot be decrypted by this Windows user. Use -ReplaceSavedKey to replace it.' }
        finally {
            if ($plainBytes) { [Array]::Clear($plainBytes, 0, $plainBytes.Length) }
            if ($cipherBytes) { [Array]::Clear($cipherBytes, 0, $cipherBytes.Length) }
        }
        Write-Host 'Using the Windows-user-protected key stored in the local runtime directory.'
    }
    else {
        $secureKey = Read-Host 'Enter Platform runtime API key (hidden; saved encrypted after doctor passes)' -AsSecureString
        $saveAfterDoctor = $true
    }

    if ($secureKey) {
        if ($secureKey.Length -eq 0) { throw 'No API key entered.' }
        $secretPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureKey)
        $env:CONTROL_PLANE_API_KEY = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($secretPointer)
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($secretPointer)
        $secretPointer = [IntPtr]::Zero
    }

    & $TunnelClient doctor --profile $profileName --profile-dir $profileDir --explain
    if ($LASTEXITCODE -ne 0) { throw 'Tunnel doctor failed; tunnel was not started. If the saved key is expired, rerun with -ReplaceSavedKey.' }
    $localSettings = @{ tunnelClient = (Resolve-Path -LiteralPath $TunnelClient).Path; codexDataRoot = (Resolve-Path -LiteralPath $CodexDataRoot).Path }
    $localSettings | ConvertTo-Json | Set-Content -LiteralPath $settingsFile -Encoding UTF8
    if ($saveAfterDoctor) {
        $temporaryKeyFile = Join-Path $dataDir ([IO.Path]::GetRandomFileName() + '.dpapi')
        try {
            $plainBytes = [Text.Encoding]::UTF8.GetBytes($env:CONTROL_PLANE_API_KEY)
            $cipherBytes = $null
            try {
                $cipherBytes = [Security.Cryptography.ProtectedData]::Protect(
                    $plainBytes, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser
                )
                $sealed = [Convert]::ToBase64String($cipherBytes)
            }
            finally {
                [Array]::Clear($plainBytes, 0, $plainBytes.Length)
                if ($cipherBytes) { [Array]::Clear($cipherBytes, 0, $cipherBytes.Length) }
            }
            [IO.File]::WriteAllText($temporaryKeyFile, $sealed, [Text.Encoding]::ASCII)
            if (Test-Path -LiteralPath $savedKeyFile -PathType Leaf) {
                [IO.File]::Replace($temporaryKeyFile, $savedKeyFile, $null)
            }
            else {
                [IO.File]::Move($temporaryKeyFile, $savedKeyFile)
            }
            Write-Host 'Runtime key saved as a Windows-user-protected encrypted file in the local runtime directory.'
        }
        finally {
            if (Test-Path -LiteralPath $temporaryKeyFile -PathType Leaf) {
                Remove-Item -LiteralPath $temporaryKeyFile -Force
            }
        }
    }
    if ($secureKey) { $secureKey.Dispose(); $secureKey = $null }
    if ($DoctorOnly) {
        Write-Host 'Doctor passed using the local key; no second tunnel was started.'
        return
    }
    Write-Host 'Work Conversation tunnel ready. Keep this terminal open while using the ChatGPT connection.'
    & $TunnelClient run --profile $profileName --profile-dir $profileDir --health.url-file (Join-Path $dataDir 'health.url')
    if ($LASTEXITCODE -ne 0) { throw "Tunnel exited with code $LASTEXITCODE" }
}
finally {
    $env:CODEX_CONVERSATION_ROOT = $previousRoot
    $env:TEMP = $previousTemp
    $env:TMP = $previousTmp
    if ($secureKey) { $secureKey.Dispose() }
    if ($hadKey) { $env:CONTROL_PLANE_API_KEY = $originalKey }
    else { Remove-Item Env:CONTROL_PLANE_API_KEY -ErrorAction SilentlyContinue }
    if ($secretPointer -ne [IntPtr]::Zero) {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($secretPointer)
    }
}
