param([string[]]$AdditionalAppPaths = @())

# Optional Windows integration. Run in elevated PowerShell after configuring the tunnel.
# Re-run after a Codex App update changes ChatGPT.exe's installation path.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this installer in an elevated PowerShell window. No task was changed.'
}

$root = Split-Path $PSScriptRoot -Parent
$dataDir = Join-Path $root '.runtime\data'
$reconcile = Join-Path $PSScriptRoot 'reconcile.ps1'
$taskName = 'WorkConversationTunnelEvent'
$paths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

$package = Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction SilentlyContinue | Select-Object -First 1
if ($package -and $package.InstallLocation) {
    $candidate = Join-Path $package.InstallLocation 'app\ChatGPT.exe'
    if (Test-Path -LiteralPath $candidate -PathType Leaf) { [void]$paths.Add($candidate) }
}
foreach ($candidate in $AdditionalAppPaths) {
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf) -or
        (Split-Path $candidate -Leaf) -ine 'ChatGPT.exe') {
        throw "Additional App path is not a ChatGPT.exe file: $candidate"
    }
    [void]$paths.Add((Resolve-Path -LiteralPath $candidate).Path)
}
if ($paths.Count -eq 0) { throw 'No Codex App executable was found. No task was changed.' }

if (-not (Test-Path -LiteralPath (Join-Path $dataDir 'control-plane-api-key.dpapi') -PathType Leaf) -or
    -not (Test-Path -LiteralPath (Join-Path $root '.runtime\profiles\work-conversation.yaml') -PathType Leaf)) {
    throw 'Configure Work Conversation tunnel first. No task was changed.'
}

# Task Scheduler receives Security 4688/4689 events only when process auditing is enabled.
$createGuid = '{0CCE922B-69AE-11D9-BED3-505054503030}'
$exitGuid = '{0CCE922C-69AE-11D9-BED3-505054503030}'
New-Item -ItemType Directory -Path $dataDir -Force | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$auditBackup = Join-Path $dataDir "audit-policy-before-$stamp.csv"
& auditpol.exe /backup "/file:$auditBackup" | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Audit policy backup failed. No task was changed.' }
$existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($existing) {
    Export-ScheduledTask -TaskName $taskName |
        Set-Content -LiteralPath (Join-Path $dataDir "task-before-$stamp.xml") -Encoding Unicode
}

& auditpol.exe /set "/subcategory:$createGuid" /success:enable /failure:disable | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Could not enable process creation audit. No task was changed.' }
& auditpol.exe /set "/subcategory:$exitGuid" /success:enable /failure:disable | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Could not enable process termination audit. No task was changed.' }

$clauses = foreach ($path in @($paths | Sort-Object)) {
    $escaped = $path.Replace('&', '&amp;').Replace("'", '&apos;').Replace('<', '&lt;').Replace('>', '&gt;')
    "Data[@Name='NewProcessName']='$escaped'"
    "Data[@Name='ProcessName']='$escaped'"
}
$xpath = "*[System[(EventID=4688 or EventID=4689)] and EventData[($($clauses -join ' or '))]]"
$subscription = "<QueryList><Query Id='0' Path='Security'><Select Path='Security'>$xpath</Select></Query></QueryList>"
$xmlSubscription = [Security.SecurityElement]::Escape($subscription)
$sid = [Security.SecurityElement]::Escape($identity.User.Value)
$shell = [Security.SecurityElement]::Escape((Get-Command powershell.exe -CommandType Application).Source)
$arguments = [Security.SecurityElement]::Escape(('-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f $reconcile))
$taskXml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo><Description>Start or stop the Work Conversation tunnel on Codex App process events.</Description></RegistrationInfo>
  <Triggers><EventTrigger><Enabled>true</Enabled><Subscription>$xmlSubscription</Subscription></EventTrigger></Triggers>
  <Principals><Principal id="Author"><UserId>$sid</UserId><LogonType>InteractiveToken</LogonType><RunLevel>LeastPrivilege</RunLevel></Principal></Principals>
  <Settings><MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy><DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries><StopIfGoingOnBatteries>false</StopIfGoingOnBatteries><ExecutionTimeLimit>PT1M</ExecutionTimeLimit><Enabled>true</Enabled><Hidden>true</Hidden></Settings>
  <Actions Context="Author"><Exec><Command>$shell</Command><Arguments>$arguments</Arguments></Exec></Actions>
</Task>
"@
$pathsFile = Join-Path $dataDir 'app-paths.json'
@($paths | Sort-Object) | ConvertTo-Json | Set-Content -LiteralPath $pathsFile -Encoding UTF8
Register-ScheduledTask -TaskName $taskName -Xml $taskXml -Force -ErrorAction Stop | Out-Null
Start-ScheduledTask -TaskName $taskName
Write-Host "Installed $taskName for $($paths.Count) App path(s)."
Write-Host 'Re-run after an App update. Existing tunnel processes were not stopped.'
