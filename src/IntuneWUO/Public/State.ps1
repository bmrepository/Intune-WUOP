function Get-WUORegistryValue {
    # Returns all values of a registry key as a hashtable, or an empty hashtable if the key is absent.
    param([Parameter(Mandatory)][string]$Path)

    $result = @{}
    if (Test-Path -LiteralPath $Path) {
        $key = Get-Item -LiteralPath $Path
        foreach ($name in $key.GetValueNames()) {
            if ($name) { $result[$name] = $key.GetValue($name) }
        }
    }
    $result
}

function Get-WUOState {
    <#
    .SYNOPSIS
        Collects the device state used by Get-WUOFinding. Read-only; changes nothing.
        Every section is collected independently so one failure does not hide the rest.
    #>
    [CmdletBinding()]
    param()

    $state = [ordered]@{
        CollectedAt      = Get-Date
        CollectionErrors = @{}
    }
    $errors = $state.CollectionErrors

    try {
        $cv = Get-WUORegistryValue 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
        $state.OS = @{
            Build          = [int]$cv['CurrentBuild']
            UBR            = [int]$cv['UBR']
            DisplayVersion = [string]$cv['DisplayVersion']
            Edition        = [string]$cv['EditionID']
            Arch           = $env:PROCESSOR_ARCHITECTURE
        }
    }
    catch { $errors['OS'] = $_.Exception.Message; $state.OS = @{ Build = 0; Arch = '' } }

    $state.PolicyManager = Get-WUORegistryValue 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Update'
    $state.PolicyManagerSystem = Get-WUORegistryValue 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\System'
    $state.Gpo = Get-WUORegistryValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
    $state.GpoAU = Get-WUORegistryValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
    $state.GpoDataCollection = Get-WUORegistryValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection'
    $state.UpdatePolicySettings = Get-WUORegistryValue 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UpdatePolicy\Settings'

    try {
        $state.Services = @(
            foreach ($n in 'wuauserv', 'UsoSvc', 'BITS', 'WaaSMedicSvc', 'wlidsvc', 'DiagTrack') {
                $s = Get-CimInstance -ClassName Win32_Service -Filter "Name='$n'" -ErrorAction Stop
                if ($s) { @{ Name = $n; State = $s.State; StartMode = $s.StartMode } }
                else { @{ Name = $n; State = 'NotInstalled'; StartMode = $null } }
            }
        )
    }
    catch { $errors['Services'] = $_.Exception.Message; $state.Services = @() }

    try {
        $latest = $null
        foreach ($e in Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Enrollments' -ErrorAction SilentlyContinue) {
            $v = Get-WUORegistryValue $e.PSPath
            if ($v['ProviderID'] -ne 'MS DM Server') { continue }
            foreach ($t in Get-ScheduledTask -TaskPath "\Microsoft\Windows\EnterpriseMgmt\$($e.PSChildName)\" -ErrorAction SilentlyContinue) {
                $info = $t | Get-ScheduledTaskInfo
                if ($info.LastRunTime -and $info.LastRunTime.Year -gt 2000 -and (-not $latest -or $info.LastRunTime -gt $latest)) {
                    $latest = $info.LastRunTime
                }
            }
        }
        $state.LastSync = $latest
    }
    catch { $errors['Sync'] = $_.Exception.Message; $state.LastSync = $null }

    $state.Reboot = @{
        CBS = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
        WU  = Test-Path 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\Auto Update\RebootRequired'
    }

    try {
        $d = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='$($env:SystemDrive)'" -ErrorAction Stop
        $state.DiskFreeGB = [math]::Round($d.FreeSpace / 1GB, 1)
    }
    catch { $errors['Disk'] = $_.Exception.Message; $state.DiskFreeGB = $null }

    try {
        $g = Get-CimInstance -Namespace root\Microsoft\Windows\DeviceGuard -ClassName Win32_DeviceGuard -ErrorAction Stop
        $state.DeviceGuard = @{
            VBSStatus                  = [int]$g.VirtualizationBasedSecurityStatus
            CodeIntegrityEnforcement   = [int]$g.CodeIntegrityPolicyEnforcementStatus
            UserModeIntegrityEnforcement = [int]$g.UsermodeCodeIntegrityPolicyEnforcementStatus
        }
    }
    catch { $errors['DeviceGuard'] = $_.Exception.Message; $state.DeviceGuard = $null }

    $state.ConfigMgr = @{
        Present = (Test-Path 'HKLM:\SOFTWARE\Microsoft\CCM') -or (Test-Path (Join-Path $env:windir 'ccmsetup'))
    }

    try {
        $au = New-Object -ComObject Microsoft.Update.AutoUpdate
        $state.Wua = @{
            LastSearchSuccess  = $au.Results.LastSearchSuccessDate
            LastInstallSuccess = $au.Results.LastInstallationSuccessDate
        }
    }
    catch { $errors['Wua'] = $_.Exception.Message; $state.Wua = @{} }

    $state.Capabilities = @{
        LanguageMode = "$($ExecutionContext.SessionState.LanguageMode)"
        Is64Bit      = [Environment]::Is64BitProcess
        IsAdmin      = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        AutopatchDrc = Test-Path (Join-Path $env:ProgramData 'Microsoft\CMDExtension\Plugins\DeviceReadinessPlugin\Logs\DRCResults.json.log')
    }

    try { $state.Autopatch = Get-WUOAutopatchState }
    catch { $errors['Autopatch'] = $_.Exception.Message; $state.Autopatch = $null }

    try { $state.FallbackTask = Get-WUOFallbackTaskStatus }
    catch { $errors['FallbackTask'] = $_.Exception.Message; $state.FallbackTask = $null }

    # $null means "not determined": hotpatch checks are skipped until enrollment evidence is read (see design doc).
    $state.Hotpatch = @{
        Enrolled           = $null
        HotPatchRestrictions = (Get-WUORegistryValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management')['HotPatchRestrictions']
    }

    $state
}
