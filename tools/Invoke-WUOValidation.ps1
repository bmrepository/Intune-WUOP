<#
.SYNOPSIS
    End-to-end validation of Intune-WUO on THIS device. Self-elevating (one UAC prompt).
.DESCRIPTION
    Builds the package, installs it for real, and exercises every mode, fix and the fallback, running the
    Remediation scripts and the fallback as SYSTEM (the same account Intune and the scheduled task use).
    It then uninstalls and verifies that the device is back to its starting state.

    What it changes temporarily (all restored in a finally block and verified at the end):
      - the BITS service start type (set to Disabled, then repaired by the tool)
      - a synthetic user-pause value under WindowsUpdate\UX\Settings (then removed by the tool)
      - HKLM:\SOFTWARE\IntuneWUO (config), %ProgramFiles%\IntuneWUO, the IntuneWUO event log, a scheduled task
      - it starts the device's own MDM sync task once (a normal Intune sync)
    It never installs a Windows update. The disruptive actions (DISM component cleanup, update-stack reset)
    only run with -IncludeDisruptive.

    Results: docs\validation\<host>-<date>.json and .md (no secrets are collected).
.EXAMPLE
    .\tools\Invoke-WUOValidation.ps1
#>
[CmdletBinding()]
param(
    [switch]$IncludeDisruptive,
    [string]$ResultDir
)

$ErrorActionPreference = 'Stop'
# $PSScriptRoot is empty inside param-block defaults under 'powershell -File' on 5.1, so resolve it here.
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$repo = (Resolve-Path (Join-Path $here '..')).Path
if (-not $ResultDir) { $ResultDir = Join-Path $repo 'docs\validation' }

# --- Self-elevate ---------------------------------------------------------------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host 'Elevating (approve the UAC prompt)...'
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    if ($IncludeDisruptive) { $argList += '-IncludeDisruptive' }
    $p = Start-Process powershell.exe -Verb RunAs -ArgumentList $argList -PassThru -Wait
    exit $p.ExitCode
}

# --- Harness plumbing ----------------------------------------------------------------------------------
$work = Join-Path $env:ProgramData 'IntuneWUO-Validation'
if (Test-Path $work) { Remove-Item $work -Recurse -Force }
New-Item -ItemType Directory -Path $work -Force | Out-Null
$out = Join-Path $work 'out'
$installDir = Join-Path $env:ProgramFiles 'IntuneWUO'
$cfgKey = 'HKLM:\SOFTWARE\IntuneWUO'
$uxKey = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'
$ps = Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe'
$results = New-Object System.Collections.Generic.List[object]
$host.UI.RawUI.WindowTitle = 'Intune-WUO validation'

function Step {
    param([string]$Name, [scriptblock]$Body)
    $r = [ordered]@{ step = $Name; pass = $false; detail = '' }
    try {
        $detail = & $Body
        $r.pass = $true
        $r.detail = ($detail | Out-String).Trim()
    }
    catch { $r.detail = $_.Exception.Message }
    $results.Add([pscustomobject]$r)
    Write-Host ('[{0}] {1}{2}' -f $(if ($r.pass) { 'PASS' } else { 'FAIL' }), $Name, $(if (-not $r.pass) { " -> $($r.detail)" } else { '' })) `
        -ForegroundColor $(if ($r.pass) { 'Green' } else { 'Red' })
}
function Assert([bool]$Condition, [string]$Message) { if (-not $Condition) { throw "Assertion failed: $Message" } }

function Invoke-Local([string]$Script, [string[]]$Arguments = @()) {
    # Windows PowerShell 5.1 turns native stderr into terminating errors under 'Stop'; relax it for this call.
    $ErrorActionPreference = 'Continue'
    $o = & $ps -NoProfile -ExecutionPolicy Bypass -File $Script @Arguments 2>&1
    [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = (($o | ForEach-Object { "$_" }) -join "`n").Trim() }
}

function Invoke-AsSystem {
    <# Runs a script as NT AUTHORITY\SYSTEM through a one-off scheduled task; returns exit code and output. #>
    param([string]$Script, [string[]]$Arguments = @(), [int]$TimeoutSeconds = 240)
    $id = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $outFile = Join-Path $work "sys-$id.out"; $codeFile = Join-Path $work "sys-$id.code"; $wrapper = Join-Path $work "sys-$id.ps1"
    # Parameter names (-Foo) go through bare; values are single-quoted.
    $argText = ($Arguments | ForEach-Object { if ($_ -like '-*') { $_ } else { "'$_'" } }) -join ' '
    Set-Content -LiteralPath $wrapper -Value @"
`$o = & '$Script' $argText *>&1 | Out-String
`$c = `$LASTEXITCODE
Set-Content -LiteralPath '$outFile' -Value `$o -Encoding UTF8
Set-Content -LiteralPath '$codeFile' -Value `$c
"@
    $name = "IntuneWUO-Validate-$id"
    $action = New-ScheduledTaskAction -Execute $ps -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$wrapper`""
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    Register-ScheduledTask -TaskName $name -TaskPath '\IntuneWUO-Validation\' -Action $action -Principal $principal -Force | Out-Null
    try {
        Start-ScheduledTask -TaskPath '\IntuneWUO-Validation\' -TaskName $name
        $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
        while ((Get-Date) -lt $deadline -and -not (Test-Path $codeFile)) { Start-Sleep -Milliseconds 500 }
        if (-not (Test-Path $codeFile)) { throw "SYSTEM run of $(Split-Path $Script -Leaf) timed out." }
        [pscustomobject]@{ ExitCode = [int](Get-Content $codeFile); Output = (Get-Content $outFile -Raw).Trim() }
    }
    finally { Unregister-ScheduledTask -TaskPath '\IntuneWUO-Validation\' -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue }
}

function Set-WUOReg([hashtable]$Values) {
    if (Test-Path $cfgKey) { Remove-Item $cfgKey -Recurse -Force }
    New-Item $cfgKey -Force | Out-Null
    foreach ($k in $Values.Keys) {
        if ($Values[$k] -is [int]) { Set-ItemProperty $cfgKey -Name $k -Value $Values[$k] -Type DWord }
        else { Set-ItemProperty $cfgKey -Name $k -Value ([string]$Values[$k]) -Type String }
    }
}
function Get-ServiceSnapshot {
    foreach ($n in 'wuauserv', 'UsoSvc', 'BITS', 'WaaSMedicSvc', 'wlidsvc', 'DiagTrack') {
        $s = Get-CimInstance Win32_Service -Filter "Name='$n'"
        [pscustomobject]@{ Name = $n; StartMode = $s.StartMode; State = $s.State }
    }
}

# --- Baseline -------------------------------------------------------------------------------------------
$baseline = [ordered]@{
    Services          = @(Get-ServiceSnapshot)
    ConfigKeyExisted  = Test-Path $cfgKey
    InstallDirExisted = Test-Path $installDir
    TaskExisted       = [bool](Get-ScheduledTask -TaskPath '\IntuneWUO\' -TaskName 'IntuneWUO-Fallback' -ErrorAction SilentlyContinue)
    UxPauseValues     = @{}
}
if (Test-Path $uxKey) {
    foreach ($n in 'PauseQualityUpdatesStartTime', 'PauseQualityUpdatesEndTime', 'PauseFeatureUpdatesStartTime', 'PauseFeatureUpdatesEndTime', 'PauseUpdatesStartTime', 'PauseUpdatesExpiryTime') {
        $v = (Get-Item $uxKey).GetValue($n); if ($null -ne $v) { $baseline.UxPauseValues[$n] = $v }
    }
}
$onBattery = [bool](Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue | Where-Object BatteryStatus -eq 1)
$historyBefore = 0
try { $historyBefore = (New-Object -ComObject Microsoft.Update.Session).CreateUpdateSearcher().GetTotalHistoryCount() } catch { }
$mdmBefore = $null

try {
    # ---------------------------------------------------------------- build + install
    Step 'Build package' {
        & (Join-Path $repo 'build\Build-IntuneWUO.ps1') -Version 0.2.99 -OutDir $out -WarningAction SilentlyContinue | Out-Null
        Assert (Test-Path (Join-Path $out 'Win32\Install-IntuneWUO.ps1')) 'install script staged'
        Assert (Test-Path (Join-Path $out 'Config\Remediate\Remediate.ps1')) 'config packages built'
        'built 0.2.99'
    }
    Step 'Install (real, to Program Files)' {
        $r = Invoke-Local (Join-Path $out 'Win32\Install-IntuneWUO.ps1')
        Assert ($r.ExitCode -eq 0) "install exit $($r.ExitCode): $($r.Output)"
        Assert (Test-Path (Join-Path $installDir 'Module\IntuneWUO.psd1')) 'module present'
        Assert ((Get-Content (Join-Path $installDir 'version.txt') -Raw).Trim() -eq '0.2.99') 'version file'
        'installed'
    }
    Step 'Install folder is locked down (Users cannot write)' {
        $acl = Get-Acl $installDir
        $users = @($acl.Access | Where-Object { $_.IdentityReference -match 'Users$' })
        Assert ($users.Count -gt 0) 'Users ACE exists'
        foreach ($u in $users) { Assert (-not ($u.FileSystemRights -band [System.Security.AccessControl.FileSystemRights]::Write)) "Users has write: $($u.FileSystemRights)" }
        Assert ($acl.AreAccessRulesProtected) 'inheritance removed'
        ($acl.Access | ForEach-Object { "{0}: {1}" -f $_.IdentityReference, $_.FileSystemRights }) -join '; '
    }
    Step 'Event log created' { Assert ([System.Diagnostics.EventLog]::SourceExists('IntuneWUO')) 'source exists'; 'source IntuneWUO' }
    Step 'Scheduled task registered as designed' {
        $t = Get-ScheduledTask -TaskPath '\IntuneWUO\' -TaskName 'IntuneWUO-Fallback'
        Assert ($t.Principal.UserId -in 'SYSTEM', 'NT AUTHORITY\SYSTEM') 'runs as SYSTEM'
        Assert ($t.Principal.RunLevel -eq 'Highest') 'highest'
        Assert (@($t.Triggers).Count -eq 2) 'two triggers'
        Assert ($t.Settings.StartWhenAvailable) 'catch-up'
        Assert ($t.Settings.DisallowStartIfOnBatteries) 'AC only'
        Assert ($t.Settings.MultipleInstances -eq 'IgnoreNew') 'single instance'
        Assert ($t.Actions[0].Arguments -like '*Invoke-WUOFallback.ps1*') 'action'
        "State=$($t.State); triggers=$(@($t.Triggers).Count)"
    }
    Step 'Win32 app detection rule passes' {
        $r = Invoke-Local (Join-Path $out 'Win32-Detect\Detect-IntuneWUOApp.ps1')
        Assert ($r.ExitCode -eq 0) "exit $($r.ExitCode) $($r.Output)"
        $r.Output
    }

    $detect = Join-Path $out 'Remediation\Detect-WUO.ps1'
    $remed = Join-Path $out 'Remediation\Remediate-WUO.ps1'
    $fallback = Join-Path $installDir 'Invoke-WUOFallback.ps1'

    # ---------------------------------------------------------------- modes (as SYSTEM, like Intune)
    Step 'No config -> defaults to ReportOnly' {
        if (Test-Path $cfgKey) { Remove-Item $cfgKey -Recurse -Force }
        $r = Invoke-AsSystem $detect
        Assert ($r.ExitCode -eq 0) "exit $($r.ExitCode)"
        Assert ($r.Output -match 'Mode=ReportOnly') $r.Output
        $r.Output
    }
    Step 'Config packages: write, detect drift, idempotent' {
        foreach ($m in 'ReportOnly', 'Remediate', 'RemediateAndFallback', 'Off') {
            $rem = Invoke-AsSystem (Join-Path $out "Config\$m\Remediate.ps1")
            Assert ($rem.ExitCode -eq 0) "$m remediate exit $($rem.ExitCode) $($rem.Output)"
            $det = Invoke-AsSystem (Join-Path $out "Config\$m\Detect.ps1")
            Assert ($det.ExitCode -eq 0) "$m detect after write exit $($det.ExitCode) $($det.Output)"
            Assert ((Get-ItemProperty $cfgKey).Mode -eq $m) "$m written"
        }
        $other = Invoke-AsSystem (Join-Path $out 'Config\Remediate\Detect.ps1')
        Assert ($other.ExitCode -eq 1) 'a different package reports drift'
        'all four modes write, verify, and report drift'
    }
    Step 'Mode Off -> Disabled, exit 0' {
        Set-WUOReg @{ Mode = 'Off' }
        $r = Invoke-AsSystem $detect
        Assert ($r.ExitCode -eq 0 -and $r.Output -match 'Disabled') $r.Output
        $r.Output
    }
    Step 'Invalid mode falls back to ReportOnly' {
        Set-WUOReg @{ Mode = 'Nuke' }
        $r = Invoke-AsSystem $detect
        Assert ($r.Output -match 'Mode=ReportOnly') $r.Output
        $r.Output
    }
    Step 'Healthy device reports Compliant and the Autopatch ring' {
        Set-WUOReg @{ Mode = 'Remediate' }
        $r = Invoke-AsSystem $detect
        Assert ($r.ExitCode -eq 0) "exit $($r.ExitCode)"
        $r.Output
    }
    Step 'Logs land in the IME logs folder; event log written' {
        $log = Join-Path $env:ProgramData 'Microsoft\IntuneManagementExtension\Logs\IntuneWUO\IntuneWUO.jsonl'
        Assert (Test-Path $log) 'jsonl in IME logs folder'
        Assert (Test-Path ([IO.Path]::ChangeExtension($log, '.log'))) 'CMTrace log'
        $e = @(Get-WinEvent -FilterHashtable @{ LogName = 'IntuneWUO' } -MaxEvents 5 -ErrorAction SilentlyContinue)
        Assert ($e.Count -gt 0) 'events in IntuneWUO log'
        "last event id $($e[0].Id)"
    }

    # ---------------------------------------------------------------- service fix
    $bitsOriginal = ($baseline.Services | Where-Object Name -eq 'BITS').StartMode
    Step 'ReportOnly: a disabled service is reported, NOT fixed' {
        Set-WUOReg @{ Mode = 'ReportOnly' }
        Set-Service BITS -StartupType Disabled
        $d = Invoke-AsSystem $detect
        Assert ($d.ExitCode -eq 0) "detect exit $($d.ExitCode) (must not trigger remediation)"
        Assert ($d.Output -match 'NonCompliant' -and $d.Output -match 'SVC_DISABLED_BITS') $d.Output
        $r = Invoke-AsSystem $remed
        Assert ($r.Output -match 'NoAction') $r.Output
        Assert ((Get-CimInstance Win32_Service -Filter "Name='BITS'").StartMode -eq 'Disabled') 'BITS must still be Disabled'
        $d.Output
    }
    Step 'Remediate + FixServices=0: reported, not fixed' {
        Set-WUOReg @{ Mode = 'Remediate'; FixServices = 0 }
        $d = Invoke-AsSystem $detect
        Assert ($d.ExitCode -eq 0) "detect exit $($d.ExitCode)"
        Assert ((Get-CimInstance Win32_Service -Filter "Name='BITS'").StartMode -eq 'Disabled') 'BITS must still be Disabled'
        $d.Output
    }
    Step 'Remediate: detect exits 1, remediation repairs the service, next detect is clean' {
        Set-WUOReg @{ Mode = 'Remediate' }
        $d = Invoke-AsSystem $detect
        Assert ($d.ExitCode -eq 1) "detect exit $($d.ExitCode): $($d.Output)"
        $r = Invoke-AsSystem $remed
        Assert ($r.ExitCode -eq 0) "remediate exit $($r.ExitCode): $($r.Output)"
        Assert ($r.Output -match 'Fixed=SVC_DISABLED_BITS') $r.Output
        $mode = (Get-CimInstance Win32_Service -Filter "Name='BITS'").StartMode
        Assert ($mode -eq 'Manual') "BITS start mode is $mode"
        $d2 = Invoke-AsSystem $detect
        Assert ($d2.ExitCode -eq 0 -and $d2.Output -match 'Compliant') $d2.Output
        $r.Output
    }
    Step 'Repeat suppression: a fix that keeps being undone is suppressed' {
        Set-WUOReg @{ Mode = 'Remediate'; FixMaxRepeats = 2 }
        if (Test-Path "$cfgKey\State") { Remove-Item "$cfgKey\State" -Recurse -Force }
        $outputs = @()
        for ($i = 1; $i -le 3; $i++) {
            Set-Service BITS -StartupType Disabled
            $outputs += (Invoke-AsSystem $remed).Output
        }
        Assert ($outputs[0] -match 'Fixed=SVC_DISABLED_BITS') "1st: $($outputs[0])"
        Assert ($outputs[1] -match 'Fixed=SVC_DISABLED_BITS') "2nd: $($outputs[1])"
        Assert ($outputs[2] -match 'Suppressed=SVC_DISABLED_BITS') "3rd: $($outputs[2])"
        Assert ((Get-CimInstance Win32_Service -Filter "Name='BITS'").StartMode -eq 'Disabled') 'suppressed fix must leave it Disabled'
        $outputs -join ' || '
    }
    Step 'Restore BITS' {
        Set-Service BITS -StartupType $(if ($bitsOriginal -eq 'Auto') { 'Automatic' } else { $bitsOriginal })
        Assert ((Get-CimInstance Win32_Service -Filter "Name='BITS'").StartMode -eq $bitsOriginal) 'restored'
        "BITS = $bitsOriginal"
    }

    # ---------------------------------------------------------------- pause fix (action level)
    Step 'ClearPause removes a user pause and nothing else' {
        Import-Module (Join-Path $installDir 'Module\IntuneWUO.psd1') -Force
        if (-not (Test-Path $uxKey)) { New-Item $uxKey -Force | Out-Null }
        $keep = 'ValidationSentinel'
        Set-ItemProperty $uxKey -Name $keep -Value 1 -Type DWord
        Set-ItemProperty $uxKey -Name PauseQualityUpdatesStartTime -Value ((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')) -Type String
        Set-ItemProperty $uxKey -Name PauseQualityUpdatesEndTime -Value ((Get-Date).AddDays(7).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')) -Type String
        try {
            $action = (Get-WUODefaultActions).ClearPause
            $msg = & $action ([pscustomobject]@{ Id = 'PAUSE_QUALITY_USER' })
            $k = Get-Item $uxKey
            Assert ($null -eq $k.GetValue('PauseQualityUpdatesStartTime')) 'start removed'
            Assert ($null -eq $k.GetValue('PauseQualityUpdatesEndTime')) 'end removed'
            Assert ($k.GetValue($keep) -eq 1) 'unrelated value untouched'
            $skip = & $action ([pscustomobject]@{ Id = 'PAUSE_QUALITY_USER' })
            Assert ("$skip" -like 'SKIP:*') 'second call is a precondition skip'
            $msg
        }
        finally { Remove-ItemProperty $uxKey -Name $keep -ErrorAction SilentlyContinue }
    }

    # ---------------------------------------------------------------- sync
    Step 'TriggerSync starts the real MDM sync task' {
        Import-Module (Join-Path $installDir 'Module\IntuneWUO.psd1') -Force
        $ids = @(Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Enrollments' | Where-Object { (Get-Item $_.PSPath).GetValue('ProviderID') -eq 'MS DM Server' })
        Assert ($ids.Count -gt 0) 'MDM enrollment found'
        $task = Get-ScheduledTask -TaskPath "\Microsoft\Windows\EnterpriseMgmt\$($ids[0].PSChildName)\" -TaskName 'PushLaunch'
        $before = ($task | Get-ScheduledTaskInfo).LastRunTime
        $msg = & (Get-WUODefaultActions).TriggerSync ([pscustomobject]@{ Id = 'SYNC_STALE' })
        Start-Sleep -Seconds 15
        $after = ($task | Get-ScheduledTaskInfo).LastRunTime
        Assert ($after -gt $before) "PushLaunch LastRunTime did not advance ($before -> $after)"
        "$msg; LastRun $before -> $after"
    }

    # ---------------------------------------------------------------- fallback
    Step 'Fallback is skipped unless mode is RemediateAndFallback' {
        Set-WUOReg @{ Mode = 'Remediate' }
        $r = Invoke-AsSystem $fallback   # no arguments: exactly how the scheduled task launches it
        Assert ($r.ExitCode -eq 0) "exit $($r.ExitCode): $($r.Output)"
        $log = Get-Content (Join-Path $env:ProgramData 'Microsoft\IntuneManagementExtension\Logs\IntuneWUO\IntuneWUO.jsonl') -Tail 3 | Out-String
        Assert ($log -match 'fallback skipped') $log
        'skipped'
    }
    Step 'Fallback: real scan, nothing overdue -> installs nothing' {
        Set-WUOReg @{ Mode = 'RemediateAndFallback' }
        $r = Invoke-AsSystem $fallback   # no arguments: exactly how the scheduled task launches it
        Assert ($r.ExitCode -eq 0) "exit $($r.ExitCode): $($r.Output)"
        $log = Get-Content (Join-Path $env:ProgramData 'Microsoft\IntuneManagementExtension\Logs\IntuneWUO\IntuneWUO.jsonl') -Tail 12 | Out-String
        Assert ($log -match 'Backend:') 'backend logged'
        Assert ($log -match 'Nothing overdue|Blocked by guardrail|Installed:') "no recognisable fallback outcome:`n$log"
        Assert ($log -notmatch 'Installed:') 'must not install anything on a healthy, current device'
        ($log -split "`n" | Where-Object { $_ -match 'Fallback' } | Select-Object -Last 4) -join "`n"
    }
    Step 'Fallback guardrail: low disk blocks it' {
        Set-WUOReg @{ Mode = 'RemediateAndFallback'; MinFreeDiskGB = 500 }
        $r = Invoke-AsSystem $fallback   # no arguments: exactly how the scheduled task launches it
        Assert ($r.ExitCode -eq 0) "exit $($r.ExitCode)"
        $log = Get-Content (Join-Path $env:ProgramData 'Microsoft\IntuneManagementExtension\Logs\IntuneWUO\IntuneWUO.jsonl') -Tail 6 | Out-String
        Assert ($log -match 'Blocked by guardrail\(s\): .*DISK_LOW') $log
        'blocked by DISK_LOW'
    }
    Step 'Fallback scheduled task runs under the Task Scheduler (AC power required)' {
        Set-WUOReg @{ Mode = 'RemediateAndFallback' }
        if ($onBattery) { return 'SKIPPED: device is on battery; the task is configured not to start on battery (correct behaviour)' }
        Start-ScheduledTask -TaskPath '\IntuneWUO\' -TaskName 'IntuneWUO-Fallback'
        $deadline = (Get-Date).AddSeconds(120)
        do { Start-Sleep -Seconds 2; $t = Get-ScheduledTask -TaskPath '\IntuneWUO\' -TaskName 'IntuneWUO-Fallback' } while ($t.State -eq 'Running' -and (Get-Date) -lt $deadline)
        $info = $t | Get-ScheduledTaskInfo
        $logFile = Join-Path $env:ProgramData 'Microsoft\IntuneManagementExtension\Logs\IntuneWUO\IntuneWUO.jsonl'
        $recent = if (Test-Path $logFile) { (Get-Content $logFile -Tail 8) -join "`n" } else { '(no log file)' }
        Assert ($info.LastTaskResult -eq 0) ("LastTaskResult 0x{0:X}. Recent log: {1}" -f $info.LastTaskResult, $recent)
        Assert ($recent -match 'Fallback') 'the task ran but never reached the fallback script (nothing logged by component Fallback)'
        "LastTaskResult 0, last run $($info.LastRunTime)"
    }
    Step 'Fallback installed no Windows updates' {
        $after = (New-Object -ComObject Microsoft.Update.Session).CreateUpdateSearcher().GetTotalHistoryCount()
        $new = if ($after -gt $historyBefore) { @((New-Object -ComObject Microsoft.Update.Session).CreateUpdateSearcher().QueryHistory(0, $after - $historyBefore) | ForEach-Object Title) } else { @() }
        $badNew = @($new | Where-Object { $_ -notmatch 'Defender|Security Intelligence|Malicious Software' })
        Assert ($badNew.Count -eq 0) ("unexpected new history: " + ($badNew -join '; '))
        "history entries before=$historyBefore after=$after; new: $($new -join '; ')"
    }

    # ---------------------------------------------------------------- task self-heal
    Step 'Missing fallback task is detected and re-registered' {
        Set-WUOReg @{ Mode = 'RemediateAndFallback' }
        Unregister-ScheduledTask -TaskPath '\IntuneWUO\' -TaskName 'IntuneWUO-Fallback' -Confirm:$false
        $d = Invoke-AsSystem $detect
        Assert ($d.ExitCode -eq 1 -and $d.Output -match 'FALLBACK_TASK_MISSING') "detect: $($d.ExitCode) $($d.Output)"
        $r = Invoke-AsSystem $remed
        Assert ($r.Output -match 'Fixed=FALLBACK_TASK_MISSING') $r.Output
        Assert ([bool](Get-ScheduledTask -TaskPath '\IntuneWUO\' -TaskName 'IntuneWUO-Fallback' -ErrorAction SilentlyContinue)) 'task is back'
        $r.Output
    }

    # ---------------------------------------------------------------- disruptive (opt-in)
    if ($IncludeDisruptive) {
        Step 'CleanupDisk (DISM component cleanup)' {
            Import-Module (Join-Path $installDir 'Module\IntuneWUO.psd1') -Force
            & (Get-WUODefaultActions).CleanupDisk ([pscustomobject]@{ Id = 'DISK_LOW' })
        }
        Step 'ResetStack renames SoftwareDistribution/catroot2 and restarts services' {
            Import-Module (Join-Path $installDir 'Module\IntuneWUO.psd1') -Force
            $msg = & (Get-WUODefaultActions).ResetStack ([pscustomobject]@{ Id = 'SCAN_STALE' })
            if ("$msg" -like 'SKIP:*') { return "skipped by precondition: $msg" }
            foreach ($s in 'wuauserv', 'bits', 'cryptsvc') { Assert ((Get-Service $s).Status -in 'Running', 'Stopped') "$s sane" }
            Assert (Test-Path (Join-Path $env:windir 'SoftwareDistribution')) 'SoftwareDistribution recreated or present'
            # The reset leaves renamed backups behind (hundreds of MB). Remove the ones THIS run made so the device is really restored.
            if ("$msg" -match 'bak-(\d{14})') {
                foreach ($d in @((Join-Path $env:windir "SoftwareDistribution.bak-$($Matches[1])"), (Join-Path $env:windir "System32\catroot2.bak-$($Matches[1])"))) {
                    if (Test-Path -LiteralPath $d) { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
                }
            }
            $msg
        }
    }
}
finally {
    # ---------------------------------------------------------------- uninstall + restore
    Step 'Uninstall removes task, files and event log' {
        $r = Invoke-Local (Join-Path $out 'Win32\Uninstall-IntuneWUO.ps1')
        Assert ($r.ExitCode -eq 0) "exit $($r.ExitCode)"
        if (-not $baseline.InstallDirExisted) { Assert (-not (Test-Path $installDir)) 'install dir removed' }
        if (-not $baseline.TaskExisted) { Assert (-not (Get-ScheduledTask -TaskPath '\IntuneWUO\' -TaskName 'IntuneWUO-Fallback' -ErrorAction SilentlyContinue)) 'task removed' }
        Assert (-not [System.Diagnostics.EventLog]::SourceExists('IntuneWUO')) 'event log removed'
        'uninstalled'
    }
    Step 'Device returned to its starting state' {
        if (-not $baseline.ConfigKeyExisted -and (Test-Path $cfgKey)) { Remove-Item $cfgKey -Recurse -Force }
        # Restore any service that drifted
        foreach ($b in $baseline.Services) {
            $now = Get-CimInstance Win32_Service -Filter "Name='$($b.Name)'"
            if ($now.StartMode -ne $b.StartMode) {
                Set-Service $b.Name -StartupType $(if ($b.StartMode -eq 'Auto') { 'Automatic' } else { $b.StartMode })
            }
        }
        $diff = foreach ($b in $baseline.Services) {
            $now = Get-CimInstance Win32_Service -Filter "Name='$($b.Name)'"
            if ($now.StartMode -ne $b.StartMode) { "$($b.Name): $($b.StartMode) -> $($now.StartMode)" }
        }
        Assert (-not $diff) ("service start modes differ: " + ($diff -join '; '))
        Assert (-not (Test-Path (Join-Path $uxKey 'ValidationSentinel'))) 'sentinel gone'
        foreach ($n in 'PauseQualityUpdatesStartTime', 'PauseQualityUpdatesEndTime') {
            if (-not $baseline.UxPauseValues.ContainsKey($n) -and (Test-Path $uxKey)) { Assert ($null -eq (Get-Item $uxKey).GetValue($n)) "$n left behind" }
        }
        Assert (([bool]$baseline.ConfigKeyExisted) -eq (Test-Path $cfgKey)) 'config key as before'
        Get-ScheduledTask -TaskPath '\IntuneWUO-Validation\' -ErrorAction SilentlyContinue | Unregister-ScheduledTask -Confirm:$false -ErrorAction SilentlyContinue
        'services, registry, tasks restored'
    }

    # ---------------------------------------------------------------- results
    if (-not (Test-Path $ResultDir)) { New-Item -ItemType Directory -Path $ResultDir -Force | Out-Null }
    $stamp = Get-Date -Format 'yyyy-MM-dd-HHmm'
    $base = Join-Path $ResultDir "$($env:COMPUTERNAME)-$stamp"
    $pass = @($results | Where-Object pass).Count
    $summary = [ordered]@{
        host = $env:COMPUTERNAME; when = (Get-Date).ToString('o'); build = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').CurrentBuild
        onBattery = $onBattery; includeDisruptive = [bool]$IncludeDisruptive
        passed = $pass; failed = $results.Count - $pass; steps = $results
    }
    $summary | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath "$base.json" -Encoding UTF8
    $md = @("# Intune-WUO validation: $($env:COMPUTERNAME) ($stamp)", '', "Passed **$pass** of $($results.Count). On battery: $onBattery. Disruptive actions: $([bool]$IncludeDisruptive).", '', '| Result | Step | Detail |', '|---|---|---|')
    foreach ($r in $results) { $md += ('| {0} | {1} | {2} |' -f $(if ($r.pass) { 'PASS' } else { '**FAIL**' }), $r.step, (($r.detail -replace '\|', '/' -replace '\r?\n', ' ') -replace '\s+', ' ').Trim()) }
    $md | Set-Content -LiteralPath "$base.md" -Encoding UTF8
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "`nPassed $pass of $($results.Count). Results: $base.md" -ForegroundColor Cyan
    Start-Sleep -Seconds 20   # leave the elevated window readable for a moment
}
