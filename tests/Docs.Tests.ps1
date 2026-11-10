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
            $f.autoFix | Should -BeIn 'None', 'Services', 'Pauses', 'SyncAndCleanup', 'PolicyKeys', 'ResetStack', 'Updates'
            foreach ($p in 'title', 'cause', 'toolAction', 'adminAction') { [string]$f.$p | Should -Not -BeNullOrEmpty }
        }
    }
    It 'is mirrored in the README status flags reference, with matching severity and event id' {
        $readme = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\README.md') -Raw -Encoding UTF8
        $start = $readme.IndexOf('## Status flags reference')
        $start | Should -BeGreaterThan 0
        $section = $readme.Substring($start)
        $section = $section.Substring(0, $section.IndexOf("`n## ", 5))
        $rows = @($section -split "`n" | Where-Object { $_ -match '^\| \*\*`[A-Za-z_]+`\*\*' })
        $by = @{}; foreach ($f in $script:catalogue.findings) { $by[$f.id] = $f }
        for ($i = 0; $i -lt $script:known.Count; $i++) {
            $id = $script:known[$i]
            $row = @($rows | Where-Object { $_.StartsWith("| **``$id``**") })
            $row.Count | Should -Be 1 -Because "$id needs exactly one row in the README reference"
            $row[0] | Should -Match ("<br>{0} " -f $by[$id].severity) -Because "$id severity"
            if ($row[0] -match 'event (\d{4})') { [int]$Matches[1] | Should -Be (2000 + $i) -Because "$id event id" }
            elseif ($by[$id].severity -ne 'Info') { throw "$id is $($by[$id].severity) but its README row has no event id" }
        }
        $rows.Count | Should -Be $script:known.Count
    }
    It 'matches the severity and auto-fix the code assigns (spot-checked from DESIGN.md claims)' {
        $by = @{}; foreach ($f in $script:catalogue.findings) { $by[$f.id] = $f }
        $by['SVC_DISABLED_wuauserv'].severity | Should -Be 'Critical'
        $by['SVC_DISABLED_BITS'].severity | Should -Be 'Warning'
        $by['SYNC_STALE'].autoFix | Should -Be 'SyncAndCleanup'
        $by['PAUSE_QUALITY_USER'].autoFix | Should -Be 'Pauses'
        $by['POLICY_CONFLICT_NOAUTOUPDATE'].autoFix | Should -Be 'None'
        $by['SCAN_STALE'].autoFix | Should -Be 'ResetStack'
        $by['UPDATE_OVERDUE'].autoFix | Should -Be 'Updates'
    }
}
