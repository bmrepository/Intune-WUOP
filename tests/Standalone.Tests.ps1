#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\src\IntuneWUO\IntuneWUO.psd1') -Force
    $script:repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:shipped = Join-Path $script:repo 'remediation'

    function New-Update($Id, $AgeDays, $Cats = @('Security Updates'), $Type = 1) {
        [pscustomobject]@{
            UpdateId = $Id; Title = "Update $Id"; KB = '5000001'; Categories = $Cats; Type = $Type; BrowseOnly = $false
            LastDeploymentChange = (Get-Date).AddDays(-$AgeDays)
        }
    }
}

Describe 'Standalone Remediations scripts (remediation\)' {
    It 'are up to date with src (run build\Build-RemediationScripts.ps1 after changing src)' {
        $tmp = Join-Path $TestDrive 'gen'
        & (Join-Path $script:repo 'build\Build-RemediationScripts.ps1') -OutDir $tmp 6>$null
        foreach ($n in 'Detect-IntuneWUO.ps1', 'Remediate-IntuneWUO.ps1') {
            $shippedText = [IO.File]::ReadAllText((Join-Path $script:shipped $n)).Replace("`r`n", "`n")
            [IO.File]::ReadAllText((Join-Path $tmp $n)) | Should -BeExactly $shippedText -Because "$n must be regenerated"
        }
    }
    It 'are ASCII-only, without a BOM, and parse' {
        foreach ($n in 'Detect-IntuneWUO.ps1', 'Remediate-IntuneWUO.ps1') {
            $bytes = [IO.File]::ReadAllBytes((Join-Path $script:shipped $n))
            ($bytes[0] -eq 0xEF) | Should -BeFalse
            @($bytes | Where-Object { $_ -gt 0x7E }).Count | Should -Be 0
            $errs = $null
            [void][System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:shipped $n), [ref]$null, [ref]$errs)
            $errs | Should -BeNullOrEmpty
        }
    }
    It 'need nothing installed: no Import-Module of a file, no Program Files path, no registry Mode' {
        foreach ($n in 'Detect-IntuneWUO.ps1', 'Remediate-IntuneWUO.ps1') {
            $t = Get-Content -LiteralPath (Join-Path $script:shipped $n) -Raw
            $t | Should -Not -Match 'Import-Module\s+\$ModulePath'
            $t | Should -Not -Match "ProgramFiles 'IntuneWUO"
            $t | Should -Match '\$WUOSettings = @\{'
            $t | Should -Match "\`$raw = @\{ Mode = 'Remediate' \}"
        }
    }
    It 'keep the stack reset off and update installs on by default' {
        $t = Get-Content -LiteralPath (Join-Path $script:shipped 'Remediate-IntuneWUO.ps1') -Raw
        $t | Should -Match 'FixResetStack\s+=\s+0'
        $t | Should -Match 'InstallOverdueUpdates\s+=\s+1'
    }
}

Describe 'Standalone config semantics' {
    BeforeAll { $script:cfg = ConvertTo-WUOConfig -Raw @{ Mode = 'Remediate'; InstallOverdueUpdates = '1' } }

    It 'defaults FixResetStack and InstallOverdueUpdates to off for the registry config' {
        $c = ConvertTo-WUOConfig -Raw @{}
        $c.FixResetStack | Should -BeFalse
        $c.InstallOverdueUpdates | Should -BeFalse
    }
    It 'gates SCAN_STALE on FixResetStack, not FixServices' {
        $f = [pscustomobject]@{ Id = 'SCAN_STALE'; Severity = 'Warning'; AutoFix = 'ResetStack' }
        Test-WUOFixEnabled -Finding $f -Config $script:cfg | Should -BeFalse
        Test-WUOFixEnabled -Finding $f -Config (ConvertTo-WUOConfig -Raw @{ Mode = 'Remediate'; FixResetStack = '1' }) | Should -BeTrue
    }
    It 'lets Remediate install only when InstallOverdueUpdates is on' {
        $f = [pscustomobject]@{ Id = 'UPDATE_OVERDUE'; Severity = 'Warning'; AutoFix = 'Updates' }
        Test-WUOFixEnabled -Finding $f -Config $script:cfg | Should -BeTrue
        Test-WUOFixEnabled -Finding $f -Config (ConvertTo-WUOConfig -Raw @{ Mode = 'Remediate' }) | Should -BeFalse
        Test-WUOFixEnabled -Finding $f -Config (ConvertTo-WUOConfig -Raw @{ Mode = 'RemediateAndFallback' }) | Should -BeTrue
    }
    It 'never lets ReportOnly install, even with InstallOverdueUpdates on' {
        $backend = @{ GetOffered = { @() }; InstallerBusy = { $false }; OnBattery = { $false }; Install = { throw 'must not install' } }
        $state = @{ PolicyManager = @{}; Reboot = @{}; DiskFreeGB = 100 }
        $run = Invoke-WUOFallbackRun -Config (ConvertTo-WUOConfig -Raw @{ Mode = 'ReportOnly'; InstallOverdueUpdates = '1' }) `
            -State $state -Backend $backend -StatePath 'TestRegistry:\WUO'
        $run.Outcome | Should -Be 'Skipped'
    }
}

Describe 'UPDATE_OVERDUE finding' {
    BeforeAll {
        $script:cfg = ConvertTo-WUOConfig -Raw @{ Mode = 'Remediate'; InstallOverdueUpdates = '1' }
        function New-State($Updates, $Pm = @{}) {
            @{
                OS = @{ Build = 26100; Arch = 'AMD64' }; PolicyManager = $Pm; PolicyManagerSystem = @{}; Gpo = @{}; GpoAU = @{}
                GpoDataCollection = @{}; UpdatePolicySettings = @{}; Services = @(); LastSync = (Get-Date); Reboot = @{}
                DiskFreeGB = 100; DeviceGuard = @{ VBSStatus = 2 }; ConfigMgr = @{ Present = $false }; Wua = @{}
                Hotpatch = @{ Enrolled = $null }
                OfferedUpdates = $Updates; UpdateFirstSeen = @{}; UpdateAttempts = @{}
            }
        }
    }
    It 'is raised for a security update offered longer than deadline + grace' {
        $f = @(Get-WUOFinding -State (New-State @(New-Update 'a' 11)) -Config $script:cfg)
        ($f | Where-Object Id -eq 'UPDATE_OVERDUE').AutoFix | Should -Be 'Updates'
    }
    It 'is not raised inside the deadline + grace window' {
        @(Get-WUOFinding -State (New-State @(New-Update 'a' 5)) -Config $script:cfg | Where-Object Id -eq 'UPDATE_OVERDUE') | Should -BeNullOrEmpty
    }
    It 'honours the ring deadline from PolicyManager' {
        $s = New-State @(New-Update 'a' 5) @{ ConfigureDeadlineForQualityUpdates = 1 }
        @(Get-WUOFinding -State $s -Config $script:cfg | Where-Object Id -eq 'UPDATE_OVERDUE').Count | Should -Be 1
    }
    It 'ignores drivers and feature updates' {
        $s = New-State @((New-Update 'd' 60 @('Drivers') 2), (New-Update 'u' 60 @('Upgrades')))
        @(Get-WUOFinding -State $s -Config $script:cfg | Where-Object Id -eq 'UPDATE_OVERDUE') | Should -BeNullOrEmpty
    }
    It 'is not evaluated when the offered updates were not collected' {
        $s = New-State $null
        @(Get-WUOFinding -State $s -Config $script:cfg | Where-Object Id -eq 'UPDATE_OVERDUE') | Should -BeNullOrEmpty
    }
}
