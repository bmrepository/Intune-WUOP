#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\src\IntuneWUO\IntuneWUO.psd1') -Force

    function New-FakeModule([string]$Root) {
        New-Item -ItemType Directory -Path $Root -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $Root 'PSWindowsUpdate.psd1') -Value '@{}'
        Set-Content -LiteralPath (Join-Path $Root 'PSWindowsUpdate.dll') -Value 'binary'
        $files = [ordered]@{}
        foreach ($f in Get-ChildItem $Root -File) { $files[$f.Name] = (Get-FileHash $f.FullName -Algorithm SHA256).Hash }
        $manifest = Join-Path (Split-Path $Root) 'manifest.json'
        [ordered]@{ schema = 1; files = $files } | ConvertTo-Json | Set-Content -LiteralPath $manifest
        $manifest
    }
}

Describe 'Test-WUOModuleCall (PSWindowsUpdate allow-list)' {
    It 'allows a read-only scan' {
        (Test-WUOModuleCall -Cmdlet 'Get-WindowsUpdate').Allowed | Should -BeTrue
    }
    It 'allows an install of explicit ids with restarts suppressed' {
        $p = @{ Install = $true; AcceptAll = $true; IgnoreReboot = $true; UpdateID = @('abc') }
        (Test-WUOModuleCall -Cmdlet 'Get-WindowsUpdate' -Parameters $p).Allowed | Should -BeTrue
    }
    It 'refuses an install without explicit update ids' {
        $r = Test-WUOModuleCall -Cmdlet 'Get-WindowsUpdate' -Parameters @{ Install = $true; AcceptAll = $true }
        $r.Allowed | Should -BeFalse
        $r.Reason | Should -Match 'UpdateID'
    }
    It 'refuses -MicrosoftUpdate, -KBArticleID and -ServiceID' {
        foreach ($p in 'MicrosoftUpdate', 'KBArticleID', 'ServiceID', 'AutoReboot', 'ScheduleReboot') {
            (Test-WUOModuleCall -Cmdlet 'Get-WindowsUpdate' -Parameters @{ $p = $true }).Allowed | Should -BeFalse
        }
    }
    It 'refuses every blocked cmdlet' {
        foreach ($c in 'Set-WUSettings', 'Add-WUServiceManager', 'Remove-WUServiceManager', 'Enable-WURemoting', 'Invoke-WUJob', 'Update-WUModule', 'Remove-WindowsUpdate') {
            (Test-WUOModuleCall -Cmdlet $c).Allowed | Should -BeFalse
        }
    }
    It 'refuses anything not on the list' {
        (Test-WUOModuleCall -Cmdlet 'Get-Process').Allowed | Should -BeFalse
    }
}

Describe 'Test-WUOModuleIntegrity and backend choice' {
    BeforeEach {
        $root = Join-Path $TestDrive 'pkg'
        Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
        $mod = Join-Path $root 'PSWindowsUpdate'
        $manifest = New-FakeModule $mod
    }

    It 'accepts an untouched copy' {
        (Test-WUOModuleIntegrity -ModulePath $mod -ManifestPath $manifest).Valid | Should -BeTrue
    }
    It 'detects a modified file' {
        Set-Content -LiteralPath (Join-Path $mod 'PSWindowsUpdate.dll') -Value 'tampered'
        $r = Test-WUOModuleIntegrity -ModulePath $mod -ManifestPath $manifest
        $r.Valid | Should -BeFalse
        ($r.Problems -join ' ') | Should -Match 'Hash mismatch'
    }
    It 'detects an extra file' {
        Set-Content -LiteralPath (Join-Path $mod 'evil.dll') -Value 'x'
        (Test-WUOModuleIntegrity -ModulePath $mod -ManifestPath $manifest).Valid | Should -BeFalse
    }
    It 'detects a missing file' {
        Remove-Item (Join-Path $mod 'PSWindowsUpdate.dll')
        (Test-WUOModuleIntegrity -ModulePath $mod -ManifestPath $manifest).Valid | Should -BeFalse
    }
    It 'fails when there is no manifest' {
        (Test-WUOModuleIntegrity -ModulePath $mod -ManifestPath (Join-Path $root 'nope.json')).Valid | Should -BeFalse
    }
    It 'picks PSWindowsUpdate only when verified and in FullLanguage' {
        Get-WUOBackendName -ModulePath $mod -ManifestPath $manifest -LanguageMode 'FullLanguage' | Should -Be 'PSWindowsUpdate'
        Get-WUOBackendName -ModulePath $mod -ManifestPath $manifest -LanguageMode 'ConstrainedLanguage' | Should -Be 'WuaCom'
    }
    It 'falls back to native COM when the copy is tampered or absent' {
        Set-Content -LiteralPath (Join-Path $mod 'PSWindowsUpdate.dll') -Value 'tampered'
        Get-WUOBackendName -ModulePath $mod -ManifestPath $manifest -LanguageMode 'FullLanguage' | Should -Be 'WuaCom'
        Get-WUOBackendName -LanguageMode 'FullLanguage' | Should -Be 'WuaCom'
    }
    It 'refuses to run a disallowed call even if the module is valid' {
        { Invoke-WUOModuleCommand -Cmdlet 'Set-WUSettings' -ModulePath $mod -ManifestPath $manifest } | Should -Throw '*Refused*'
    }
}

Describe 'Fallback scheduled task definition' {
    BeforeAll { $d = New-WUOFallbackTaskDefinition -InstallDir 'C:\Program Files\IntuneWUO' }

    It 'runs as SYSTEM with highest privileges' {
        # Windows normalises 'NT AUTHORITY\SYSTEM' to 'SYSTEM'.
        $d.Principal.UserId | Should -BeIn 'SYSTEM', 'NT AUTHORITY\SYSTEM'
        $d.Principal.RunLevel | Should -Be 'Highest'
    }
    It 'has a daily trigger with random delay and a delayed startup trigger' {
        $d.Triggers.Count | Should -Be 2
        $d.Triggers[1].Delay | Should -Be 'PT15M'
        $d.Triggers[0].RandomDelay | Should -Not -BeNullOrEmpty
    }
    It 'catches up after a missed run, one instance at a time, 4 hour limit, AC only' {
        $d.Settings.StartWhenAvailable | Should -BeTrue
        $d.Settings.MultipleInstances | Should -Be 'IgnoreNew'
        $d.Settings.ExecutionTimeLimit | Should -Be 'PT4H'
        $d.Settings.DisallowStartIfOnBatteries | Should -BeTrue
        $d.Settings.WakeToRun | Should -BeFalse
    }
    It 'launches the 64-bit Windows PowerShell fallback script' {
        $d.Action.Execute | Should -BeLike '*System32\WindowsPowerShell\v1.0\powershell.exe'
        $d.Action.Arguments | Should -BeLike '*Invoke-WUOFallback.ps1*'
    }
}

Describe 'Scripts launched with powershell -File (regressions found by the on-device validation)' {
    It 'no script uses $PSScriptRoot in a param-block default (it is empty there under -File on Windows PowerShell 5.1)' {
        $root = Join-Path $PSScriptRoot '..'
        $files = Get-ChildItem -Path (Join-Path $root 'src\Remediation'), (Join-Path $root 'src\Win32'), (Join-Path $root 'build'), (Join-Path $root 'tools') -Filter '*.ps1' -File
        $files.Count | Should -BeGreaterThan 5
        $offenders = foreach ($f in $files) {
            $tokens = $null; $errors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errors)
            $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.ParameterAst] -and $n.DefaultValue }, $true) | ForEach-Object {
                $uses = $_.DefaultValue.FindAll({ param($v) $v -is [System.Management.Automation.Language.VariableExpressionAst] -and $v.VariablePath.UserPath -in 'PSScriptRoot', 'PSCommandPath' }, $true)
                if ($uses.Count -gt 0) { "$($f.Name): -$($_.Name.VariablePath.UserPath)" }
            }
        }
        $offenders | Should -BeNullOrEmpty
    }

    It 'the built fallback script runs with NO arguments, exactly as the scheduled task launches it' {
        $cfg = Get-ItemProperty 'HKLM:\SOFTWARE\IntuneWUO' -ErrorAction SilentlyContinue
        if ($cfg -and $cfg.Mode -eq 'RemediateAndFallback') { Set-ItResult -Skipped -Because 'this machine is in RemediateAndFallback; the script would do a real scan'; return }
        $out = Join-Path $TestDrive 'out-fallback'
        & (Join-Path $PSScriptRoot '..\build\Build-IntuneWUO.ps1') -Version 1.2.4 -OutDir $out -WarningAction SilentlyContinue | Out-Null
        $o = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $out 'Win32\Invoke-WUOFallback.ps1') 2>&1
        $LASTEXITCODE | Should -Be 0 -Because (($o | ForEach-Object { "$_" }) -join ' ')
    }

    It 'the built Detect script runs with no arguments and prints a status line' {
        $out = Join-Path $TestDrive 'out-detect'
        & (Join-Path $PSScriptRoot '..\build\Build-IntuneWUO.ps1') -Version 1.2.5 -OutDir $out -WarningAction SilentlyContinue | Out-Null
        $mod = Join-Path $out 'Win32\Module\IntuneWUO.psd1'
        $o = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $out 'Remediation\Detect-WUO.ps1') -ModulePath $mod 2>&1 | ForEach-Object { "$_" }) -join "`n"
        $o | Should -Match '^WUO\|v1\|'
    }
}

Describe 'Build script' {
    It 'stamps config packages and the version' {
        $out = Join-Path $TestDrive 'out'
        & (Join-Path $PSScriptRoot '..\build\Build-IntuneWUO.ps1') -Version 1.2.3 -OutDir $out -WarningAction SilentlyContinue | Out-Null
        Get-Content (Join-Path $out 'Win32\version.txt') -Raw | Should -Be '1.2.3'
        Get-Content (Join-Path $out 'Config\Remediate\Remediate.ps1') -Raw | Should -Match "Mode = 'Remediate'"
        Get-Content (Join-Path $out 'Config\Off\Detect.ps1') -Raw | Should -Match "Mode = 'Off'"
        Get-Content (Join-Path $out 'Win32-Detect\Detect-IntuneWUOApp.ps1') -Raw | Should -Match "'1.2.3'"
        Test-Path (Join-Path $out 'Remediation\Remediate-WUO.ps1') | Should -BeTrue
        (Get-Content (Join-Path $out 'Win32\Module\IntuneWUO.psd1') -Raw) | Should -Match "ModuleVersion\s*=\s*'1.2.3'"
    }
}
