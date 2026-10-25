# Run Windows installation checks as a disposable, non-administrator CI user.
# This helper is for an ephemeral GitHub-hosted runner only.
[CmdletBinding()]
param(
    [ValidateSet('transactions','smoke')][string]$Mode = 'smoke',
    [ValidateSet('powershell','pwsh')][string]$Engine = 'pwsh'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted' -or $env:OS -ne 'Windows_NT') {
    throw 'Use this helper only on a disposable GitHub-hosted Windows runner.'
}
$user = 'cfx_' + [guid]::NewGuid().ToString('N').Substring(0, 10)
$entropy = New-Object byte[] 6
$random = [Security.Cryptography.RandomNumberGenerator]::Create()
try { $random.GetBytes($entropy) } finally { $random.Dispose() }
# net.exe prompts for confirmation above 14 characters, even with /add.
$password = 'Cfx!9a' + [Convert]::ToBase64String($entropy)
$root = Join-Path $env:RUNNER_TEMP $user
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'The GitHub runner already uses a non-administrator token.'
    New-Item -ItemType Directory -Path $root | Out-Null
    $env:CODEFX_TEST_ROOT = $root
    $scriptName = if ($Mode -eq 'smoke') { 'smoke_install_windows.ps1' } else { 'test_install_windows.ps1' }
    & (Join-Path $PSScriptRoot "../../scripts/install/$scriptName")
    if ($LASTEXITCODE -ne 0) { throw "Non-administrator $Mode checks exited $LASTEXITCODE" }
    return
}
$created = $false
$taskName = 'CodefxCI-' + $user
$registered = $false
$batchGranted = $false
$sid = $null
$result = 1
try {
    $accountResult = & net.exe user $user $password /add /expires:never 2>&1
    if ($LASTEXITCODE -ne 0) { throw ('Could not create the isolated CI account: ' + (($accountResult | Out-String).Replace($password, '[redacted]'))) }
    $created = $true
    New-Item -ItemType Directory -Path (Join-Path $root 'source'), (Join-Path $root 'temp') | Out-Null
    Copy-Item -Path (Join-Path $PSScriptRoot '../../scripts/install/*') -Destination (Join-Path $root 'source')
    $utf8 = New-Object Text.UTF8Encoding($false)
    $variables = @{}
    foreach ($name in @('Path','RELEASE_TAG','EXPECTED_TARGET','CODEFX_GITHUB_REPO','CODEFX_INSTALL_REF','CODEFX_GITHUB_TOKEN')) {
        $value = [Environment]::GetEnvironmentVariable($name, 'Process')
        if ($null -ne $value) { $variables[$name] = $value }
    }
    [IO.File]::WriteAllText((Join-Path $root 'environment.json'), ($variables | ConvertTo-Json), $utf8)
    $scriptName = if ($Mode -eq 'smoke') { 'smoke_install_windows.ps1' } else { 'test_install_windows.ps1' }
    $launcher = @'
param([string]$Root, [string]$ScriptName)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$result = 1
try {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'CI child still has administrator privileges.' }
    $variables = Get-Content -LiteralPath (Join-Path $Root 'environment.json') -Raw | ConvertFrom-Json
    foreach ($property in $variables.PSObject.Properties) { [Environment]::SetEnvironmentVariable($property.Name, [string]$property.Value, 'Process') }
    $env:TEMP = Join-Path $Root 'temp'; $env:TMP = $env:TEMP
    $env:CODEFX_TEST_ROOT = $Root
    $env:CODEX_NON_INTERACTIVE = '1'
    Set-Location (Join-Path $Root 'source')
    & (Join-Path $Root "source\$ScriptName") *> (Join-Path $Root 'stdout.log')
    if ($LASTEXITCODE -ne 0) { throw "CI script exited $LASTEXITCODE" }
    $result = 0
} catch { ($_ | Out-String) | Set-Content -LiteralPath (Join-Path $Root 'stderr.log') -Encoding UTF8 }
finally { [IO.File]::WriteAllText((Join-Path $Root 'exitcode.txt'), [string]$result) }
exit $result
'@
    [IO.File]::WriteAllText((Join-Path $root 'launch.ps1'), $launcher, $utf8)
    # Limit access to this test account and the runner administrator/SYSTEM.
    $sid = (New-Object Security.Principal.NTAccount($env:COMPUTERNAME, $user)).Translate([Security.Principal.SecurityIdentifier]).Value
    Add-Type -Path (Join-Path $PSScriptRoot 'codefx-ci-account.cs')
    $batchGranted = [CodefxCiAccountV1]::EnsureBatchLogon($user, $env:COMPUTERNAME, $password, $sid)
    Write-Host 'Verified batch logon for the disposable CI account.'
    $runnerSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    # Set file and directory ACLs explicitly: inherited directory-only flags on
    # protected files can otherwise leave a readable root with unreadable files.
    $items = @((Get-Item -LiteralPath $root)) + @(Get-ChildItem -LiteralPath $root -Recurse -Force)
    foreach ($item in $items) {
        $acl = if ($item.PSIsContainer) { New-Object Security.AccessControl.DirectorySecurity } else { New-Object Security.AccessControl.FileSecurity }
        $acl.SetAccessRuleProtection($true, $false)
        $acl.SetOwner((New-Object Security.Principal.SecurityIdentifier($runnerSid)))
        $inherit = if ($item.PSIsContainer) { [Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit' } else { [Security.AccessControl.InheritanceFlags]::None }
        foreach ($identity in @($sid, $runnerSid, 'S-1-5-18')) {
            $rule = New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier($identity)), [Security.AccessControl.FileSystemRights]::FullControl, $inherit, [Security.AccessControl.PropagationFlags]::None, [Security.AccessControl.AccessControlType]::Allow)
            $null = $acl.AddAccessRule($rule)
        }
        Set-Acl -LiteralPath $item.FullName -AclObject $acl
    }
    Write-Host ("Isolated launcher ACL: " + (Get-Acl -LiteralPath (Join-Path $root 'launch.ps1')).Sddl)
    $executable = (Get-Command ($Engine + '.exe') -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    $arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + (Join-Path $root 'launch.ps1') + '" "' + $root + '" "' + $scriptName + '"'
    # Task Scheduler creates the test process independently of the Actions
    # runner's job, while retaining a normal user token and default protections.
    $hostOutput = Join-Path $root 'host-stdout.log'; $hostError = Join-Path $root 'host-stderr.log'
    $hostArguments = '/d /s /c ""' + $executable + '" ' + $arguments + ' >"' + $hostOutput + '" 2>"' + $hostError + '""'
    $action = New-ScheduledTaskAction -Execute (Join-Path $env:SystemRoot 'System32\cmd.exe') -Argument $hostArguments -WorkingDirectory $root
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 12)
    $settings.Enabled = $true; $settings.AllowDemandStart = $true
    $null = Register-ScheduledTask -TaskName $taskName -Action $action -Settings $settings -User "$env:COMPUTERNAME\$user" -Password $password -RunLevel Limited -Force
    $registered = $true
    $scheduler = New-Object -ComObject Schedule.Service
    $scheduler.Connect()
    $scheduled = $scheduler.GetFolder('\').GetTask($taskName)
    $scheduled.Enabled = $true
    Write-Host ("Scheduled task enabled={0}, demand-start={1}" -f $scheduled.Enabled, $scheduled.Definition.Settings.AllowDemandStart)
    if (-not $scheduled.Definition.Settings.AllowDemandStart) { throw 'The isolated task does not allow demand starts.' }
    $launchedAt = [DateTime]::Now.AddSeconds(-2)
    $runningTask = $scheduled.RunEx($null, 2, 0, $null)
    if ($null -eq $runningTask) { throw 'Task Scheduler did not create a running instance.' }
    Write-Host ("Scheduled instance {0}, state={1}" -f $runningTask.InstanceGuid, $runningTask.State)
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $completion = Join-Path $root 'exitcode.txt'
    $reportedLines = 0
    while (-not (Test-Path -LiteralPath $completion)) {
        try { $runningTask.Refresh() } catch { # A completed instance has no live COM state.
            Write-Verbose $_
        }
        $info = Get-ScheduledTaskInfo -TaskName $taskName
        $liveLog = Join-Path $root 'stdout.log'
        if (Test-Path -LiteralPath $liveLog) {
            $lines = @(Get-Content -LiteralPath $liveLog -ErrorAction SilentlyContinue)
            if ($lines.Count -gt $reportedLines) {
                $lines[$reportedLines..($lines.Count - 1)] | ForEach-Object { Write-Host $_ }
                $reportedLines = $lines.Count
            }
        }
        if ($watch.Elapsed.TotalSeconds -ge 600 -or
            ($watch.Elapsed.TotalSeconds -gt 15 -and $info.LastRunTime -ge $launchedAt -and (Get-ScheduledTask -TaskName $taskName).State -eq 'Ready') -or
            ($watch.Elapsed.TotalSeconds -gt 90 -and $info.LastRunTime -lt $launchedAt)) {
            Write-Host (Export-ScheduledTask -TaskName $taskName)
            Write-Host ($info | Format-List LastRunTime,LastTaskResult,NextRunTime | Out-String)
            Get-WinEvent -FilterHashtable @{LogName='Microsoft-Windows-TaskScheduler/Operational';StartTime=$launchedAt.AddSeconds(-10)} -ErrorAction SilentlyContinue |
                Where-Object { $_.Message -like "*$taskName*" } | Select-Object Id,Message | Format-List | Out-String | Write-Host
            throw ("Scheduled CI check has no completion record: " + $info.LastTaskResult)
        }
        Start-Sleep -Milliseconds 500
    }
    $result = [int][IO.File]::ReadAllText($completion)
} finally {
    if ($registered) {
        Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    }
    foreach ($file in @('stdout.log','stderr.log','host-stdout.log','host-stderr.log')) {
        $log = Join-Path $root $file
        if (Test-Path -LiteralPath $log) { Get-Content -LiteralPath $log | ForEach-Object { Write-Host $_ } }
    }
    # Terminate only processes owned by this disposable account before retiring it.
    if ($created) {
        Get-CimInstance Win32_Process | ForEach-Object {
            $owner = Invoke-CimMethod -InputObject $_ -MethodName GetOwner -ErrorAction SilentlyContinue
            if ($null -ne $owner -and $owner.ReturnValue -eq 0 -and $owner.User -ceq $user) {
                Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
            }
        }
        if ($batchGranted) { try { [CodefxCiAccountV1]::RevokeBatchLogon($sid) } catch { Write-Warning $_ } }
        $null = & net.exe user $user /delete 2>&1
    }
    $secret = Join-Path $root 'environment.json'
    if (Test-Path -LiteralPath $secret) { Remove-Item -LiteralPath $secret -Force }
}
if ($result -ne 0) { throw "Non-administrator $Engine $Mode checks failed (exit $result)." }
Write-Host "Non-administrator $Engine $Mode checks passed."
