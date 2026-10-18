#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\src\IntuneWUO\IntuneWUO.psd1') -Force

    function New-TestState {
        # A healthy device; individual tests override pieces.
        @{
            OS                   = @{ Build = 26100; UBR = 9711; Arch = 'AMD64' }
            PolicyManager        = @{}
            PolicyManagerSystem  = @{}
            Gpo                  = @{}
            GpoAU                = @{}
            GpoDataCollection    = @{}
            UpdatePolicySettings = @{ PausedQualityStatus = 0; PausedFeatureStatus = 0 }
            Services             = @(
                @{ Name = 'wuauserv'; State = 'Stopped'; StartMode = 'Manual' }
                @{ Name = 'UsoSvc'; State = 'Running'; StartMode = 'Auto' }
                @{ Name = 'wlidsvc'; State = 'Stopped'; StartMode = 'Manual' }
            )
            LastSync             = (Get-Date).AddHours(-1)
            Reboot               = @{ CBS = $false; WU = $false }
            DiskFreeGB           = 100
            DeviceGuard          = @{ VBSStatus = 2 }
            ConfigMgr            = @{ Present = $false }
            Wua                  = @{ LastSearchSuccess = (Get-Date).AddHours(-2) }
            Hotpatch             = @{ Enrolled = $null }
        }
    }
    function Get-Ids($State, $Config) { @(Get-WUOFinding -State $State -Config $Config | ForEach-Object Id) }
}

Describe 'ConvertTo-WUOConfig' {
    It 'defaults to ReportOnly when nothing is set' {
        (ConvertTo-WUOConfig -Raw @{}).Mode | Should -Be 'ReportOnly'
    }
    It 'accepts a valid mode case-insensitively' {
        (ConvertTo-WUOConfig -Raw @{ Mode = 'remediate' }).Mode | Should -Be 'Remediate'
    }
    It 'falls back to ReportOnly and warns on an invalid mode' {
        $c = ConvertTo-WUOConfig -Raw @{ Mode = 'Nuke' }
        $c.Mode | Should -Be 'ReportOnly'
        $c.Warnings.Count | Should -Be 1
    }
    It 'rejects out-of-range numbers and keeps the default' {
        $c = ConvertTo-WUOConfig -Raw @{ FallbackGraceDays = 999; MinFreeDiskGB = 'abc' }
        $c.FallbackGraceDays | Should -Be 3
        $c.MinFreeDiskGB | Should -Be 20
        $c.Warnings.Count | Should -Be 2
    }
    It 'parses fix switches' {
        (ConvertTo-WUOConfig -Raw @{ FixServices = 0 }).FixServices | Should -BeFalse
    }
}

Describe 'Get-WUOFinding' {
    BeforeEach { $cfg = ConvertTo-WUOConfig -Raw @{} }

    It 'finds nothing on a healthy device' {
        Get-Ids (New-TestState) $cfg | Should -BeNullOrEmpty
    }
    It 'does not flag a stopped trigger-start service' {
        $s = New-TestState   # wuauserv and wlidsvc are Stopped/Manual
        Get-Ids $s $cfg | Should -Not -Contain 'SVC_DISABLED_wuauserv'
    }
    It 'flags a disabled service as fixable' {
        $s = New-TestState
        $s.Services = @(@{ Name = 'UsoSvc'; State = 'Stopped'; StartMode = 'Disabled' })
        $f = Get-WUOFinding -State $s -Config $cfg
        $f.Id | Should -Contain 'SVC_DISABLED_UsoSvc'
        ($f | Where-Object Id -eq 'SVC_DISABLED_UsoSvc').AutoFix | Should -Be 'Services'
    }
    It 'flags the three Autopatch conflict values and never auto-fixes them' {
        $s = New-TestState
        $s.Gpo = @{ DoNotConnectToWindowsUpdateInternetLocations = 1; DisableWindowsUpdateAccess = 1 }
        $s.GpoAU = @{ NoAutoUpdate = 1 }
        $f = Get-WUOFinding -State $s -Config $cfg
        ($f | Where-Object Id -like 'POLICY_CONFLICT_*').Count | Should -Be 3
        ($f | Where-Object Id -like 'POLICY_CONFLICT_*' | Where-Object AutoFix -ne 'None') | Should -BeNullOrEmpty
    }
    It 'flags WSUS and the DualScan conflict' {
        $s = New-TestState
        $s.Gpo = @{ UseWUServer = 1; WUServer = 'http://wsus'; DisableDualScan = 1 }
        Get-Ids $s $cfg | Should -Contain 'WSUS_REMNANT'
        Get-Ids $s $cfg | Should -Contain 'DUALSCAN_CONFLICT'
    }
    It 'treats a user pause as fixable' {
        $s = New-TestState
        $s.UpdatePolicySettings = @{ PausedQualityStatus = 1; PausedFeatureStatus = 0 }
        $f = Get-WUOFinding -State $s -Config $cfg | Where-Object Id -eq 'PAUSE_QUALITY_USER'
        $f.AutoFix | Should -Be 'Pauses'
    }
    It 'never treats a pause set by Intune policy as a fault' {
        $s = New-TestState
        $s.UpdatePolicySettings = @{ PausedQualityStatus = 1; PausedFeatureStatus = 0 }
        $s.PolicyManager = @{ PauseQualityUpdatesStartTime = '2026-10-01' }
        $ids = Get-Ids $s $cfg
        $ids | Should -Not -Contain 'PAUSE_QUALITY_USER'
        $ids | Should -Contain 'PAUSE_POLICY'
    }
    It 'flags diagnostic data below Required' {
        $s = New-TestState
        $s.PolicyManagerSystem = @{ AllowTelemetry = 0 }
        Get-Ids $s $cfg | Should -Contain 'DIAGDATA_LOW'
    }
    It 'flags a stale sync, a stale scan and low disk' {
        $s = New-TestState
        $s.LastSync = (Get-Date).AddDays(-3)
        $s.Wua = @{ LastSearchSuccess = (Get-Date).AddDays(-30) }
        $s.DiskFreeGB = 5
        $ids = Get-Ids $s $cfg
        $ids | Should -Contain 'SYNC_STALE'
        $ids | Should -Contain 'SCAN_STALE'
        $ids | Should -Contain 'DISK_LOW'
    }
    It 'reports a pending restart as informational only' {
        $s = New-TestState
        $s.Reboot = @{ CBS = $true; WU = $false }
        $f = Get-WUOFinding -State $s -Config $cfg | Where-Object Id -eq 'RESTART_PENDING'
        $f.Severity | Should -Be 'Info'
    }
    It 'skips hotpatch checks when enrollment is unknown' {
        $s = New-TestState
        $s.DeviceGuard = @{ VBSStatus = 0 }
        Get-Ids $s $cfg | Should -Not -Contain 'HOTPATCH_VBS_NOT_RUNNING'
    }
    It 'reports hotpatch blockers for an enrolled device' {
        $s = New-TestState
        $s.Hotpatch = @{ Enrolled = $true }
        $s.DeviceGuard = @{ VBSStatus = 0 }
        Get-Ids $s $cfg | Should -Contain 'HOTPATCH_VBS_NOT_RUNNING'
    }
}

Describe 'Format-WUOStatus' {
    BeforeAll { $cfg = ConvertTo-WUOConfig -Raw @{ Mode = 'Remediate' } }

    It 'reports Compliant with no findings' {
        Format-WUOStatus -Config $cfg -Build 26100 | Should -Be 'WUO|v1|Compliant|Mode=Remediate|Build=26100'
    }
    It 'stays Compliant when there are only Info findings' {
        $f = [pscustomobject]@{ Id = 'RESTART_PENDING'; Severity = 'Info' }
        Format-WUOStatus -Config $cfg -Findings @($f) | Should -BeLike 'WUO|v1|Compliant|*'
    }
    It 'reports NonCompliant and lists the most severe findings first' {
        $a = [pscustomobject]@{ Id = 'DISK_LOW'; Severity = 'Warning' }
        $b = [pscustomobject]@{ Id = 'SVC_DISABLED_UsoSvc'; Severity = 'Critical' }
        Format-WUOStatus -Config $cfg -Findings @($a, $b) | Should -BeLike '*|NonCompliant|*|F=SVC_DISABLED_UsoSvc,DISK_LOW'
    }
    It 'reports Disabled' {
        Format-WUOStatus -Config $cfg -Disabled | Should -BeLike 'WUO|v1|Disabled|*'
    }
    It 'never exceeds the length limit and marks overflow' {
        $many = 1..400 | ForEach-Object { [pscustomobject]@{ Id = "FINDING_NUMBER_$_"; Severity = 'Warning' } }
        $s = Format-WUOStatus -Config $cfg -Findings $many
        $s.Length | Should -BeLessOrEqual 2048
        $s | Should -Match '\+\d+$'
    }
}
