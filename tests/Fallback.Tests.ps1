#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\src\IntuneWUO\IntuneWUO.psd1') -Force

    $script:StatePath = 'HKCU:\Software\IntuneWUOTest\FallbackState'
    function New-Update($Id, $Cats = @('Security Updates'), $AgeDays = 10, $Type = 1, $BrowseOnly = $false) {
        [pscustomobject]@{
            UpdateId = $Id; Title = "Update $Id"; KB = '1'; Categories = $Cats; Type = $Type
            BrowseOnly = $BrowseOnly; LastDeploymentChange = (Get-Date).AddDays(-$AgeDays)
        }
    }
    function New-HealthyState {
        @{ PolicyManager = @{ ConfigureDeadlineForQualityUpdates = 1 }; DiskFreeGB = 100; Reboot = @{ CBS = $false; WU = $false } }
    }
    function New-FakeBackend($Offered, $InstallResult) {
        $log = New-Object System.Collections.Generic.List[string]
        @{
            Name          = 'fake'
            GetOffered    = { $Offered }.GetNewClosure()
            InstallerBusy = { $false }
            OnBattery     = { $false }
            Install       = { param($Ids) $log.Add(($Ids -join ',')); & $InstallResult $Ids }.GetNewClosure()
            Log           = $log
        }
    }
}

AfterAll { Remove-Item 'HKCU:\Software\IntuneWUOTest' -Recurse -Force -ErrorAction SilentlyContinue }

Describe 'Select-WUOFallbackCandidate' {
    BeforeAll { $cfg = ConvertTo-WUOConfig -Raw @{ FallbackGraceDays = 3 } }   # deadline 1 + grace 3 = 4 days

    It 'accepts an overdue security update' {
        $d = Select-WUOFallbackCandidate -Updates @(New-Update 'a' -AgeDays 10) -Config $cfg -DeadlineDays 1
        $d[0].Eligible | Should -BeTrue
    }
    It 'waits until deadline plus grace has passed' {
        $d = Select-WUOFallbackCandidate -Updates @(New-Update 'a' -AgeDays 3) -Config $cfg -DeadlineDays 1
        $d[0].Eligible | Should -BeFalse
        $d[0].Reason | Should -Be 'NotYetOverdue'
    }
    It 'never selects drivers, upgrades, feature packs, definitions or optional updates' {
        $ups = @(
            (New-Update 'drv' -Type 2)
            (New-Update 'upg' -Cats @('Upgrades'))
            (New-Update 'fp' -Cats @('Feature Packs'))
            (New-Update 'def' -Cats @('Definition Updates', 'Microsoft Defender Antivirus'))
            (New-Update 'opt' -BrowseOnly $true)
        )
        $d = Select-WUOFallbackCandidate -Updates $ups -Config $cfg -DeadlineDays 1
        @($d | Where-Object Eligible).Count | Should -Be 0
    }
    It 'stops after the maximum number of failed attempts' {
        $d = Select-WUOFallbackCandidate -Updates @(New-Update 'a') -Config $cfg -DeadlineDays 1 -AttemptCounts @{ a = 3 }
        $d[0].Reason | Should -Be 'MaxAttempts'
    }
    It 'uses first-seen when the update has no deployment date' {
        $u = New-Update 'a'; $u.LastDeploymentChange = $null
        $d = Select-WUOFallbackCandidate -Updates @($u) -Config $cfg -DeadlineDays 1 -FirstSeen @{ a = (Get-Date).AddDays(-9) }
        $d[0].Eligible | Should -BeTrue
    }
}

Describe 'Test-WUOFallbackGuardrail' {
    BeforeAll { $cfg = ConvertTo-WUOConfig -Raw @{} }

    It 'is clear on a healthy device' {
        @(Test-WUOFallbackGuardrail -State (New-HealthyState) -Config $cfg).Count | Should -Be 0
    }
    It 'blocks on low disk, pending restart, busy installer and battery' {
        $s = New-HealthyState; $s.DiskFreeGB = 2; $s.Reboot = @{ CBS = $true; WU = $false }
        $g = Test-WUOFallbackGuardrail -State $s -Config $cfg -OnBattery $true -InstallerBusy $true
        $g | Should -Contain 'DISK_LOW'
        $g | Should -Contain 'RESTART_PENDING'
        $g | Should -Contain 'INSTALL_BUSY'
        $g | Should -Contain 'ON_BATTERY'
    }
    It 'stays out of the way when a native maintenance window is enabled' {
        $s = New-HealthyState; $s.PolicyManager['MaintenanceWindowEnabled'] = 1
        Test-WUOFallbackGuardrail -State $s -Config $cfg | Should -Contain 'MAINTENANCE_WINDOW_NATIVE'
    }
}

Describe 'Invoke-WUOFallbackRun' {
    BeforeEach { Remove-Item 'HKCU:\Software\IntuneWUOTest' -Recurse -Force -ErrorAction SilentlyContinue }

    It 'skips unless the mode is RemediateAndFallback' {
        $b = New-FakeBackend @() { }
        foreach ($m in 'Off', 'ReportOnly', 'Remediate') {
            $cfg = ConvertTo-WUOConfig -Raw @{ Mode = $m }
            (Invoke-WUOFallbackRun -Config $cfg -State (New-HealthyState) -Backend $b -StatePath $script:StatePath).Outcome | Should -Be 'Skipped'
        }
        $b.Log.Count | Should -Be 0
    }
    It 'does not install when a guardrail is active' {
        $b = New-FakeBackend @(New-Update 'a') { }
        $s = New-HealthyState; $s.Reboot = @{ CBS = $true; WU = $false }
        $cfg = ConvertTo-WUOConfig -Raw @{ Mode = 'RemediateAndFallback' }
        $r = Invoke-WUOFallbackRun -Config $cfg -State $s -Backend $b -StatePath $script:StatePath
        $r.Outcome | Should -Be 'Blocked'
        $b.Log.Count | Should -Be 0
    }
    It 'reports nothing eligible when updates are not yet overdue' {
        $b = New-FakeBackend @(New-Update 'a' -AgeDays 1) { }
        $cfg = ConvertTo-WUOConfig -Raw @{ Mode = 'RemediateAndFallback' }
        (Invoke-WUOFallbackRun -Config $cfg -State (New-HealthyState) -Backend $b -StatePath $script:StatePath).Outcome | Should -Be 'NothingEligible'
        $b.Log.Count | Should -Be 0
    }
    It 'installs exactly the overdue eligible updates and nothing else' {
        $offered = @((New-Update 'late' -AgeDays 10), (New-Update 'fresh' -AgeDays 1), (New-Update 'drv' -Type 2 -AgeDays 30))
        $b = New-FakeBackend $offered { param($ids) $ids | ForEach-Object { [pscustomobject]@{ UpdateId = $_; Success = $true } } }
        $cfg = ConvertTo-WUOConfig -Raw @{ Mode = 'RemediateAndFallback' }
        $r = Invoke-WUOFallbackRun -Config $cfg -State (New-HealthyState) -Backend $b -StatePath $script:StatePath
        $r.Outcome | Should -Be 'Installed'
        $b.Log[0] | Should -Be 'late'
    }
    It 'counts failed attempts and gives up after the maximum' {
        $b = New-FakeBackend @(New-Update 'bad' -AgeDays 10) { param($ids) $ids | ForEach-Object { [pscustomobject]@{ UpdateId = $_; Success = $false } } }
        $cfg = ConvertTo-WUOConfig -Raw @{ Mode = 'RemediateAndFallback'; FallbackMaxAttempts = 2 }
        (Invoke-WUOFallbackRun -Config $cfg -State (New-HealthyState) -Backend $b -StatePath $script:StatePath).Outcome | Should -Be 'PartiallyFailed'
        (Invoke-WUOFallbackRun -Config $cfg -State (New-HealthyState) -Backend $b -StatePath $script:StatePath).Outcome | Should -Be 'PartiallyFailed'
        (Invoke-WUOFallbackRun -Config $cfg -State (New-HealthyState) -Backend $b -StatePath $script:StatePath).Outcome | Should -Be 'NothingEligible'
        $b.Log.Count | Should -Be 2
    }
}
