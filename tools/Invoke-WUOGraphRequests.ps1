<#
.SYNOPSIS
    Applies the Graph requests produced by the MCP tool wuo_generate_graph_requests (or wuo_generate_mode_change),
    one at a time, with a confirmation on every request.
.DESCRIPTION
    For agents and admins that have a terminal and Microsoft Graph PowerShell but no tenant MCP server.
      - shows each request (script contents are summarised, never dumped) and asks before sending it
      - substitutes {placeholders} in URLs with ids returned by earlier responses (saveResponseIdAs)
      - skips requests marked skipIfNoGroups
      - stops on the first error
      - writes a log of everything it created
      - -WhatIf prints the plan and calls nothing, not even Connect-MgGraph
    Needs: Microsoft.Graph.Authentication (Install-Module Microsoft.Graph.Authentication -Scope CurrentUser) and an
    account allowed to create Intune Remediations. Delegated scopes requested: DeviceManagementScripts.ReadWrite.All
    (and Group.Read.All for reads).
.EXAMPLE
    .\tools\Invoke-WUOGraphRequests.ps1 -RequestsFile .\requests.json -WhatIf
.EXAMPLE
    .\tools\Invoke-WUOGraphRequests.ps1 -RequestsFile .\requests.json -Variable @{ configScriptId_ReportOnly = '<id>' }
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$RequestsFile,
    [hashtable]$Variable = @{},
    [string]$LogPath,
    [switch]$AutoApprove,
    [string[]]$Scopes = @('DeviceManagementScripts.ReadWrite.All', 'Group.Read.All')
)

function Resolve-WUOPlaceholders {
    <# Replaces {name} in a URL with $Vars[name]. Throws if any placeholder is unresolved, unless -KeepUnresolved (dry runs). #>
    param([Parameter(Mandatory)][string]$Url, [hashtable]$Vars = @{}, [switch]$KeepUnresolved)
    $known = $Vars
    $keep = $KeepUnresolved
    [regex]::Replace($Url, '\{([A-Za-z0-9_]+)\}', {
        param($m)
        $name = $m.Groups[1].Value
        if (-not $known.ContainsKey($name) -or -not $known[$name]) {
            if ($keep) { return $m.Value }
            throw "Unresolved placeholder {$name} in $Url"
        }
        [string]$known[$name]
    })
}

function Get-WUORequestSummary {
    <# A human-readable one-screen summary. Base64 script bodies are replaced by their length. #>
    param([Parameter(Mandatory)]$Request)
    $lines = @("$($Request.method) $($Request.url)", "  $($Request.description)")
    if ($Request.body) {
        $b = $Request.body
        foreach ($p in 'displayName', 'runAsAccount', 'runAs32Bit', 'enforceSignatureCheck') {
            if ($b.PSObject.Properties[$p]) { $lines += "  $p = $($b.$p)" }
        }
        foreach ($p in 'detectionScriptContent', 'remediationScriptContent') {
            if ($b.PSObject.Properties[$p]) { $lines += "  $p = <base64, $($b.$p.Length) chars>" }
        }
        if ($b.PSObject.Properties['deviceHealthScriptAssignments']) {
            foreach ($a in $b.deviceHealthScriptAssignments) {
                $kind = if ($a.target.'@odata.type' -like '*exclusion*') { 'EXCLUDE' } else { 'INCLUDE' }
                $sched = if ($a.runSchedule) { " schedule=$($a.runSchedule.'@odata.type' -replace '.*deviceHealthScript','') interval=$($a.runSchedule.interval)" } else { '' }
                $lines += "  $kind group $($a.target.groupId)$sched"
            }
            if (@($b.deviceHealthScriptAssignments).Count -eq 0) { $lines += '  (empty assignment list: this REMOVES all assignments)' }
        }
    }
    $lines -join "`n"
}

function Invoke-WUORequestPlan {
    <#
      Runs the plan. -Invoker is injectable for tests; the default calls Invoke-MgGraphRequest.
      Returns one result object per request: Description, Status (Sent|Skipped|WhatIf|Declined), Id.
    #>
    param(
        [Parameter(Mandatory)]$Requests,
        [hashtable]$Vars = @{},
        [scriptblock]$Invoker = { param($method, $uri, $body) Invoke-MgGraphRequest -Method $method -Uri $uri -Body ($body | ConvertTo-Json -Depth 20) -ContentType 'application/json' },
        [scriptblock]$Confirm = { param($summary) (Read-Host "$summary`nSend this request? (y/N)") -match '^(y|yes)$' },
        [switch]$DryRun,
        [switch]$AutoApprove
    )
    $state = @{}; foreach ($k in $Vars.Keys) { $state[$k] = $Vars[$k] }   # not named $vars: variable names are case-insensitive
    $results = New-Object System.Collections.Generic.List[object]

    foreach ($r in $Requests) {
        $res = [ordered]@{ Description = $r.description; Method = $r.method; Status = ''; Id = $null }

        if ($r.skipIfNoGroups) { $res.Status = 'Skipped'; $results.Add([pscustomobject]$res); continue }

        $url = Resolve-WUOPlaceholders -Url $r.url -Vars $state -KeepUnresolved:$DryRun   # a live run throws here, before anything is sent
        $summary = Get-WUORequestSummary -Request ([pscustomobject]@{ method = $r.method; url = $url; description = $r.description; body = $r.body })

        if ($DryRun) { Write-Host $summary; $res.Status = 'WhatIf'; $results.Add([pscustomobject]$res); continue }

        $ok = $AutoApprove -or (& $Confirm $summary)
        if (-not $ok) { $res.Status = 'Declined'; $results.Add([pscustomobject]$res); break }

        $response = & $Invoker $r.method $url $r.body
        $res.Status = 'Sent'
        if ($r.saveResponseIdAs) {
            $id = $response.id
            if (-not $id) { throw "The response to '$($r.description)' had no id, so {$($r.saveResponseIdAs)} cannot be resolved. Stopping." }
            $state[$r.saveResponseIdAs] = $id
            $res.Id = $id
        }
        $results.Add([pscustomobject]$res)
    }
    [pscustomobject]@{ Results = $results.ToArray(); Variables = $state }
}

# ---- script entry (skipped when dot-sourced by tests) ------------------------------------------------------
if ($MyInvocation.InvocationName -ne '.') {
    $ErrorActionPreference = 'Stop'
    $json = Get-Content -LiteralPath $RequestsFile -Raw -Encoding UTF8 | ConvertFrom-Json
    $requests = if ($json.PSObject.Properties['requests']) { $json.requests } else { $json }

    $dry = [bool]$WhatIfPreference
    if (-not $dry) {
        if (-not (Get-Module -ListAvailable Microsoft.Graph.Authentication)) { throw 'Install-Module Microsoft.Graph.Authentication -Scope CurrentUser' }
        Import-Module Microsoft.Graph.Authentication
        $ctx = Get-MgContext
        if (-not $ctx) { Connect-MgGraph -Scopes $Scopes -NoWelcome | Out-Null; $ctx = Get-MgContext }
        Write-Host "Signed in as $($ctx.Account) in tenant $($ctx.TenantId)" -ForegroundColor Cyan
    }

    $outcome = Invoke-WUORequestPlan -Requests $requests -Vars $Variable -DryRun:$dry -AutoApprove:$AutoApprove
    $outcome.Results | Format-Table Status, Method, Description, Id -AutoSize

    if (-not $LogPath) { $LogPath = Join-Path (Get-Location) ("IntuneWUO-graph-{0:yyyyMMdd-HHmmss}.json" -f (Get-Date)) }
    if (-not $dry) {
        [pscustomobject]@{ when = (Get-Date).ToString('o'); results = $outcome.Results; variables = $outcome.Variables } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $LogPath -Encoding UTF8
        Write-Host "Log: $LogPath"
    }
}
