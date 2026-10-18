#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\src\IntuneWUO\IntuneWUO.psd1') -Force
    $script:catalogue = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\docs\findings.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $script:known = InModuleScope IntuneWUO { $script:WUOKnownFindings }
}

Describe 'docs/findings.json (used by the MCP server and the AI-agent skill)' {
    It 'documents every finding id the module can emit' {
        $ids = @($script:catalogue.findings | ForEach-Object id)
        $missing = @($script:known | Where-Object { $_ -notin $ids })
        $missing | Should -BeNullOrEmpty
    }
    It 'does not document ids the module does not know' {
        $ids = @($script:catalogue.findings | ForEach-Object id)
        $extra = @($ids | Where-Object { $_ -notin $script:known })
        $extra | Should -BeNullOrEmpty
    }
    It 'has no duplicate ids' {
        $ids = @($script:catalogue.findings | ForEach-Object id)
        ($ids | Group-Object | Where-Object Count -gt 1) | Should -BeNullOrEmpty
    }
    It 'uses only valid severities and auto-fix categories, with every field filled in' {
        foreach ($f in $script:catalogue.findings) {
            $f.severity | Should -BeIn 'Critical', 'Warning', 'Info'
            $f.autoFix | Should -BeIn 'None', 'Services', 'Pauses', 'SyncAndCleanup', 'PolicyKeys'
            foreach ($p in 'title', 'cause', 'toolAction', 'adminAction') { [string]$f.$p | Should -Not -BeNullOrEmpty }
        }
    }
    It 'matches the severity and auto-fix the code assigns (spot-checked from DESIGN.md claims)' {
        $by = @{}; foreach ($f in $script:catalogue.findings) { $by[$f.id] = $f }
        $by['SVC_DISABLED_wuauserv'].severity | Should -Be 'Critical'
        $by['SVC_DISABLED_BITS'].severity | Should -Be 'Warning'
        $by['SYNC_STALE'].autoFix | Should -Be 'SyncAndCleanup'
        $by['PAUSE_QUALITY_USER'].autoFix | Should -Be 'Pauses'
        $by['POLICY_CONFLICT_NOAUTOUPDATE'].autoFix | Should -Be 'None'
        $by['SCAN_STALE'].autoFix | Should -Be 'Services'
    }
}
