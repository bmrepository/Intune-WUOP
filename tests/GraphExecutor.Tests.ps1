#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    . (Join-Path $PSScriptRoot '..\tools\Invoke-WUOGraphRequests.ps1') -RequestsFile 'unused.json'

    function New-Req($desc, $method, $url, $body = $null, $save = $null, $skip = $false) {
        [pscustomobject]@{ description = $desc; method = $method; url = $url; body = $body; saveResponseIdAs = $save; skipIfNoGroups = $skip }
    }
}

Describe 'Resolve-WUOPlaceholders' {
    It 'substitutes known placeholders' {
        Resolve-WUOPlaceholders -Url 'https://x/{a}/assign/{b}' -Vars @{ a = '1'; b = '2' } | Should -Be 'https://x/1/assign/2'
    }
    It 'throws on an unresolved placeholder rather than sending a broken URL' {
        { Resolve-WUOPlaceholders -Url 'https://x/{missing}/assign' -Vars @{} } | Should -Throw '*Unresolved placeholder*'
    }
}

Describe 'Get-WUORequestSummary' {
    It 'never prints script contents, only their length' {
        $b = [pscustomobject]@{ displayName = 'X'; detectionScriptContent = ('QUJD' * 100); remediationScriptContent = 'QUJD' }
        $s = Get-WUORequestSummary -Request (New-Req 'create' 'POST' 'https://x' $b)
        $s | Should -Match 'base64, 400 chars'
        $s | Should -Not -Match 'QUJDQUJD'
    }
    It 'labels include vs exclude groups and warns about an empty assignment list' {
        $b = [pscustomobject]@{ deviceHealthScriptAssignments = @(
            [pscustomobject]@{ target = [pscustomobject]@{ '@odata.type' = '#microsoft.graph.groupAssignmentTarget'; groupId = 'g1' }; runSchedule = [pscustomobject]@{ '@odata.type' = '#microsoft.graph.deviceHealthScriptHourlySchedule'; interval = 8 } }
            [pscustomobject]@{ target = [pscustomobject]@{ '@odata.type' = '#microsoft.graph.exclusionGroupAssignmentTarget'; groupId = 'g2' } }) }
        $s = Get-WUORequestSummary -Request (New-Req 'assign' 'POST' 'https://x' $b)
        $s | Should -Match 'INCLUDE group g1'
        $s | Should -Match 'interval=8'
        $s | Should -Match 'EXCLUDE group g2'
        $empty = Get-WUORequestSummary -Request (New-Req 'assign' 'POST' 'https://x' ([pscustomobject]@{ deviceHealthScriptAssignments = @() }))
        $empty | Should -Match 'REMOVES all assignments'
    }
}

Describe 'Invoke-WUORequestPlan' {
    BeforeEach {
        $script:sent = New-Object System.Collections.Generic.List[string]
        $script:invoker = { param($method, $uri, $body) $script:sent.Add("$method $uri"); [pscustomobject]@{ id = 'new-id-1' } }
        $script:yes = { param($s) $true }
        $script:no = { param($s) $false }
    }

    It 'dry run sends nothing at all' {
        $reqs = @((New-Req 'create' 'POST' 'https://g/scripts' @{} 'mainScriptId'), (New-Req 'assign' 'POST' 'https://g/scripts/{mainScriptId}/assign' @{}))
        $r = Invoke-WUORequestPlan -Requests $reqs -DryRun -Invoker $script:invoker
        $script:sent.Count | Should -Be 0
        $r.Results.Status | Should -Not -Contain 'Sent'
    }
    It 'sends in order and substitutes the id returned by the earlier response' {
        $reqs = @((New-Req 'create' 'POST' 'https://g/scripts' @{} 'mainScriptId'), (New-Req 'assign' 'POST' 'https://g/scripts/{mainScriptId}/assign' @{}))
        $r = Invoke-WUORequestPlan -Requests $reqs -Invoker $script:invoker -Confirm $script:yes
        $script:sent[0] | Should -Be 'POST https://g/scripts'
        $script:sent[1] | Should -Be 'POST https://g/scripts/new-id-1/assign'
        $r.Results[0].Id | Should -Be 'new-id-1'
    }
    It 'skips requests that have no groups yet' {
        $reqs = @((New-Req 'assign' 'POST' 'https://g/{x}/assign' @{} $null $true))
        $r = Invoke-WUORequestPlan -Requests $reqs -Invoker $script:invoker -Confirm $script:yes
        $script:sent.Count | Should -Be 0
        $r.Results[0].Status | Should -Be 'Skipped'
    }
    It 'stops at the first declined request and sends nothing after it' {
        $reqs = @((New-Req 'one' 'POST' 'https://g/1'), (New-Req 'two' 'POST' 'https://g/2'))
        $r = Invoke-WUORequestPlan -Requests $reqs -Invoker $script:invoker -Confirm $script:no
        $script:sent.Count | Should -Be 0
        @($r.Results).Count | Should -Be 1
        $r.Results[0].Status | Should -Be 'Declined'
    }
    It 'throws before sending when a placeholder cannot be resolved' {
        $reqs = @((New-Req 'assign' 'POST' 'https://g/{nope}/assign' @{}))
        { Invoke-WUORequestPlan -Requests $reqs -Invoker $script:invoker -Confirm $script:yes } | Should -Throw '*Unresolved placeholder*'
        $script:sent.Count | Should -Be 0
    }
    It 'stops if a create response has no id' {
        $noId = { param($m, $u, $b) $script:sent.Add("$m $u"); [pscustomobject]@{} }
        $reqs = @((New-Req 'create' 'POST' 'https://g/scripts' @{} 'mainScriptId'), (New-Req 'assign' 'POST' 'https://g/{mainScriptId}/assign' @{}))
        { Invoke-WUORequestPlan -Requests $reqs -Invoker $noId -Confirm $script:yes } | Should -Throw '*had no id*'
        $script:sent.Count | Should -Be 1
    }
    It 'accepts pre-supplied variables (for example ids from an earlier session)' {
        $reqs = @((New-Req 'assign' 'POST' 'https://g/{configScriptId_Off}/assign' @{}))
        $null = Invoke-WUORequestPlan -Requests $reqs -Vars @{ configScriptId_Off = 'abc' } -Invoker $script:invoker -Confirm $script:yes
        $script:sent[0] | Should -Be 'POST https://g/abc/assign'
    }
}
