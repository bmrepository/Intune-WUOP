#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\src\IntuneWUO\IntuneWUO.psd1') -Force

    $script:StatePath = 'HKCU:\Software\IntuneWUOTest\State'
    function New-Finding($Id, $AutoFix = 'Services') {
        [pscustomobject]@{ Id = $Id; Severity = 'Warning'; Message = $Id; AutoFix = $AutoFix; Source = '' }
    }
    function New-Actions {
        # Records every call so tests can prove what did (and did not) run.
        $calls = New-Object System.Collections.Generic.List[string]
        $a = @{
            RepairService = { param($f) $calls.Add($f.Id); 'ok' }.GetNewClosure()
            ClearPause    = { param($f) $calls.Add($f.Id); 'ok' }.GetNewClosure()
            TriggerSync   = { param($f) $calls.Add($f.Id); 'ok' }.GetNewClosure()
            CleanupDisk   = { param($f) $calls.Add($f.Id); 'ok' }.GetNewClosure()
            ResetStack    = { param($f) $calls.Add($f.Id); 'ok' }.GetNewClosure()
        }
        [pscustomobject]@{ Actions = $a; Calls = $calls }
    }
}

AfterAll { Remove-Item 'HKCU:\Software\IntuneWUOTest' -Recurse -Force -ErrorAction SilentlyContinue }

Describe 'Invoke-WUORemediation' {
    BeforeEach {
        Remove-Item 'HKCU:\Software\IntuneWUOTest' -Recurse -Force -ErrorAction SilentlyContinue
        $t = New-Actions
    }

    It 'does nothing in ReportOnly mode' {
        $cfg = ConvertTo-WUOConfig -Raw @{ Mode = 'ReportOnly' }
        $r = Invoke-WUORemediation -Findings @(New-Finding 'SVC_DISABLED_UsoSvc') -Config $cfg -Actions $t.Actions -StatePath $script:StatePath
        $r[0].Outcome | Should -Be 'Skipped'
        $r[0].Reason | Should -Be 'ModeNotRemediate'
        $t.Calls.Count | Should -Be 0
    }
    It 'does nothing in Off mode' {
        $cfg = ConvertTo-WUOConfig -Raw @{ Mode = 'Off' }
        $null = Invoke-WUORemediation -Findings @(New-Finding 'DISK_LOW' 'SyncAndCleanup') -Config $cfg -Actions $t.Actions -StatePath $script:StatePath
        $t.Calls.Count | Should -Be 0
    }
    It 'fixes a finding in Remediate mode' {
        $cfg = ConvertTo-WUOConfig -Raw @{ Mode = 'Remediate' }
        $r = Invoke-WUORemediation -Findings @(New-Finding 'SVC_DISABLED_UsoSvc') -Config $cfg -Actions $t.Actions -StatePath $script:StatePath
        $r[0].Outcome | Should -Be 'Fixed'
        $t.Calls | Should -Contain 'SVC_DISABLED_UsoSvc'
    }
    It 'never touches report-only findings' {
        $cfg = ConvertTo-WUOConfig -Raw @{ Mode = 'Remediate' }
        $r = @(Invoke-WUORemediation -Findings @(New-Finding 'POLICY_CONFLICT_NOAUTOUPDATE' 'None') -Config $cfg -Actions $t.Actions -StatePath $script:StatePath)
        $r.Count | Should -Be 0
        $t.Calls.Count | Should -Be 0
    }
    It 'respects a switched-off category' {
        $cfg = ConvertTo-WUOConfig -Raw @{ Mode = 'Remediate'; FixServices = 0 }
        $r = Invoke-WUORemediation -Findings @(New-Finding 'SVC_DISABLED_UsoSvc') -Config $cfg -Actions $t.Actions -StatePath $script:StatePath
        $r[0].Reason | Should -Be 'SwitchOff'
        $t.Calls.Count | Should -Be 0
    }
    It 'records a failure without throwing' {
        $cfg = ConvertTo-WUOConfig -Raw @{ Mode = 'Remediate' }
        $t.Actions.RepairService = { param($f) throw 'access denied' }
        $r = Invoke-WUORemediation -Findings @(New-Finding 'SVC_DISABLED_WaaSMedicSvc') -Config $cfg -Actions $t.Actions -StatePath $script:StatePath
        $r[0].Outcome | Should -Be 'Failed'
        $r[0].Detail | Should -Match 'access denied'
    }
    It 'treats SKIP: as a skipped precondition and does not count it as an attempt' {
        $cfg = ConvertTo-WUOConfig -Raw @{ Mode = 'Remediate' }
        $t.Actions.ClearPause = { param($f) 'SKIP: no user pause values found' }
        $r = Invoke-WUORemediation -Findings @(New-Finding 'PAUSE_QUALITY_USER' 'Pauses') -Config $cfg -Actions $t.Actions -StatePath $script:StatePath
        $r[0].Outcome | Should -Be 'Skipped'
        $r[0].Reason | Should -Be 'Precondition'
        Get-WUOStoreValue -Name 'FixCount_PAUSE_QUALITY_USER' -StatePath $script:StatePath | Should -BeNullOrEmpty
    }
    It 'stops re-applying a fix that keeps coming back' {
        $cfg = ConvertTo-WUOConfig -Raw @{ Mode = 'Remediate'; FixMaxRepeats = 2 }
        $now = Get-Date
        $f = @(New-Finding 'SVC_DISABLED_BITS')
        (Invoke-WUORemediation -Findings $f -Config $cfg -Actions $t.Actions -StatePath $script:StatePath -Now $now)[0].Outcome | Should -Be 'Fixed'
        (Invoke-WUORemediation -Findings $f -Config $cfg -Actions $t.Actions -StatePath $script:StatePath -Now $now.AddHours(1))[0].Outcome | Should -Be 'Fixed'
        $third = Invoke-WUORemediation -Findings $f -Config $cfg -Actions $t.Actions -StatePath $script:StatePath -Now $now.AddHours(2)
        $third[0].Outcome | Should -Be 'Suppressed'
        $t.Calls.Count | Should -Be 2
    }
    It 'allows a fix again after the 7-day window' {
        $cfg = ConvertTo-WUOConfig -Raw @{ Mode = 'Remediate'; FixMaxRepeats = 1 }
        $now = Get-Date
        $f = @(New-Finding 'SVC_DISABLED_BITS')
        $null = Invoke-WUORemediation -Findings $f -Config $cfg -Actions $t.Actions -StatePath $script:StatePath -Now $now
        (Invoke-WUORemediation -Findings $f -Config $cfg -Actions $t.Actions -StatePath $script:StatePath -Now $now.AddDays(8))[0].Outcome | Should -Be 'Fixed'
    }
    It 'rate-limits the update-stack reset' {
        $cfg = ConvertTo-WUOConfig -Raw @{ Mode = 'Remediate'; ResetCooldownDays = 7 }
        $now = Get-Date
        $f = @(New-Finding 'SCAN_STALE')
        (Invoke-WUORemediation -Findings $f -Config $cfg -Actions $t.Actions -StatePath $script:StatePath -Now $now)[0].Outcome | Should -Be 'Fixed'
        $again = Invoke-WUORemediation -Findings $f -Config $cfg -Actions $t.Actions -StatePath $script:StatePath -Now $now.AddDays(2)
        $again[0].Reason | Should -Be 'Cooldown'
    }
}

Describe 'Remove-WUOOldStackBackups (the stack reset must not leave hundreds of MB behind on every run)' {
    BeforeEach {
        $script:win = Join-Path $TestDrive 'Windows'
        $script:sys = Join-Path $script:win 'System32'
        New-Item -ItemType Directory -Path $script:sys -Force | Out-Null
        foreach ($d in 'SoftwareDistribution.bak-20260101000000', 'SoftwareDistribution.bak-20260201000000', 'SoftwareDistribution.bak-20260301000000',
                       'SoftwareDistribution', 'SoftwareDistribution.bak-notadate', 'SoftwareDistribution.bak-2026030100000', 'Other.bak-20260101000000', 'xSoftwareDistribution.bak-20260101000000') {
            New-Item -ItemType Directory -Path (Join-Path $script:win $d) -Force | Out-Null
        }
        foreach ($d in 'catroot2.bak-20260101000000', 'catroot2.bak-20260301000000', 'catroot2') { New-Item -ItemType Directory -Path (Join-Path $script:sys $d) -Force | Out-Null }
    }

    It 'keeps only the newest backup of each kind' {
        $removed = Remove-WUOOldStackBackups -Parent @($script:win, $script:sys)
        @($removed).Count | Should -Be 3
        Test-Path (Join-Path $script:win 'SoftwareDistribution.bak-20260301000000') | Should -BeTrue
        Test-Path (Join-Path $script:win 'SoftwareDistribution.bak-20260201000000') | Should -BeFalse
        Test-Path (Join-Path $script:win 'SoftwareDistribution.bak-20260101000000') | Should -BeFalse
        Test-Path (Join-Path $script:sys 'catroot2.bak-20260301000000') | Should -BeTrue
        Test-Path (Join-Path $script:sys 'catroot2.bak-20260101000000') | Should -BeFalse
    }
    It 'never touches the live folders or anything whose name does not match exactly' {
        $null = Remove-WUOOldStackBackups -Parent @($script:win, $script:sys)
        foreach ($keep in 'SoftwareDistribution', 'SoftwareDistribution.bak-notadate', 'SoftwareDistribution.bak-2026030100000', 'Other.bak-20260101000000', 'xSoftwareDistribution.bak-20260101000000') {
            Test-Path (Join-Path $script:win $keep) | Should -BeTrue -Because $keep
        }
        Test-Path (Join-Path $script:sys 'catroot2') | Should -BeTrue
    }
    It 'is a no-op for a missing parent and honours -Keep' {
        @(Remove-WUOOldStackBackups -Parent @((Join-Path $TestDrive 'nope'))).Count | Should -Be 0
        $removed = Remove-WUOOldStackBackups -Parent @($script:win) -Keep 2
        @($removed).Count | Should -Be 1
        Test-Path (Join-Path $script:win 'SoftwareDistribution.bak-20260101000000') | Should -BeFalse
        Test-Path (Join-Path $script:win 'SoftwareDistribution.bak-20260201000000') | Should -BeTrue
    }
}

Describe 'Test-WUOFixEnabled and Get-WUOFixActionName' {
    It 'maps finding ids to actions' {
        Get-WUOFixActionName (New-Finding 'SVC_DISABLED_wuauserv') | Should -Be 'RepairService'
        Get-WUOFixActionName (New-Finding 'PAUSE_FEATURE_USER') | Should -Be 'ClearPause'
        Get-WUOFixActionName (New-Finding 'SYNC_STALE') | Should -Be 'TriggerSync'
        Get-WUOFixActionName (New-Finding 'DISK_LOW') | Should -Be 'CleanupDisk'
        Get-WUOFixActionName (New-Finding 'SCAN_STALE') | Should -Be 'ResetStack'
        Get-WUOFixActionName (New-Finding 'WSUS_REMNANT' 'None') | Should -BeNullOrEmpty
    }
    It 'is false for report-only findings even with all switches on' {
        Test-WUOFixEnabled -Finding (New-Finding 'X' 'None') -Config (ConvertTo-WUOConfig -Raw @{}) | Should -BeFalse
    }
}

Describe 'Event ids' {
    It 'gives findings and their fixes lined-up ids' {
        (Get-WUOEventId -Kind Fix -FindingId 'DISK_LOW') - (Get-WUOEventId -Kind Finding -FindingId 'DISK_LOW') | Should -Be 1000
    }
    It 'uses fixed ids for fallback events' {
        Get-WUOEventId -Kind FallbackInstalled | Should -Be 4001
        Get-WUOEventId -Kind Error | Should -Be 9000
    }
    It 'maps an unknown finding to the catch-all slot' {
        Get-WUOEventId -Kind Finding -FindingId 'NOT_A_REAL_ONE' | Should -Be 2099
    }
}
