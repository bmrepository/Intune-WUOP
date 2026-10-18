$script:WUOTaskPath = '\IntuneWUO\'
$script:WUOTaskName = 'IntuneWUO-Fallback'

function New-WUOFallbackTaskDefinition {
    <#
    .SYNOPSIS
        Builds (does not register) the fallback scheduled task parts: daily at 10:00 + up to 6 h random delay,
        at startup + 15 min, catch-up after a missed run, SYSTEM, AC power and network required, 4 h limit,
        one instance at a time.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$InstallDir,
        [ValidateSet('Bypass', 'AllSigned')][string]$ExecutionPolicy = 'Bypass'
    )

    $script = Join-Path $InstallDir 'Invoke-WUOFallback.ps1'
    $ps = Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $action = New-ScheduledTaskAction -Execute $ps -WorkingDirectory $InstallDir -Argument (
        '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy {0} -File "{1}"' -f $ExecutionPolicy, $script)

    $daily = New-ScheduledTaskTrigger -Daily -At '10:00' -RandomDelay (New-TimeSpan -Hours 6)
    $startup = New-ScheduledTaskTrigger -AtStartup
    $startup.Delay = 'PT15M'

    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -RunOnlyIfNetworkAvailable `
        -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 4)
    $settings.DisallowStartIfOnBatteries = $true
    $settings.StopIfGoingOnBatteries = $true
    $settings.WakeToRun = $false

    $principal = New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\SYSTEM' -LogonType ServiceAccount -RunLevel Highest

    [pscustomobject]@{
        TaskPath  = $script:WUOTaskPath
        TaskName  = $script:WUOTaskName
        Action    = $action
        Triggers  = @($daily, $startup)
        Settings  = $settings
        Principal = $principal
    }
}

function Register-WUOFallbackTask {
    <# Registers (or replaces) the fallback task. Needs admin. #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$InstallDir,
        [ValidateSet('Bypass', 'AllSigned')][string]$ExecutionPolicy = 'Bypass'
    )
    $d = New-WUOFallbackTaskDefinition -InstallDir $InstallDir -ExecutionPolicy $ExecutionPolicy
    if ($PSCmdlet.ShouldProcess("$($d.TaskPath)$($d.TaskName)", 'Register scheduled task')) {
        Register-ScheduledTask -TaskPath $d.TaskPath -TaskName $d.TaskName -Action $d.Action -Trigger $d.Triggers `
            -Settings $d.Settings -Principal $d.Principal -Force | Out-Null
    }
}

function Unregister-WUOFallbackTask {
    [CmdletBinding()]
    param()
    $t = Get-ScheduledTask -TaskPath $script:WUOTaskPath -TaskName $script:WUOTaskName -ErrorAction SilentlyContinue
    if ($t) { Unregister-ScheduledTask -InputObject $t -Confirm:$false }
}

function Get-WUOFallbackTaskStatus {
    <# Returns Present/Enabled for the fallback task. Read-only. #>
    [CmdletBinding()]
    param()
    $t = Get-ScheduledTask -TaskPath $script:WUOTaskPath -TaskName $script:WUOTaskName -ErrorAction SilentlyContinue
    [pscustomobject]@{ Present = [bool]$t; Enabled = [bool]($t -and $t.State -ne 'Disabled') }
}
