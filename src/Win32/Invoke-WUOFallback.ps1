<#
.SYNOPSIS
    Scheduled-task entry point for the Intune-WUO fallback installer.
.DESCRIPTION
    Installs only quality/security updates that Windows Update already offers this device, that are older
    than the ring deadline plus FallbackGraceDays, and only when every guardrail is clear. Never restarts.
    Runs as SYSTEM in 64-bit Windows PowerShell 5.1 from <InstallDir>.
#>
[CmdletBinding()]
param(
    [string]$InstallDir = $PSScriptRoot
)

$ErrorActionPreference = 'Stop'
$lock = $null

try {
    Import-Module (Join-Path $InstallDir 'Module\IntuneWUO.psd1') -Force

    $config = Get-WUOConfig
    if ($config.Mode -ne 'RemediateAndFallback') {
        Write-WUOLog -Component 'Fallback' -Message "Mode is $($config.Mode); fallback skipped."
        Write-WUOEvent -Id (Get-WUOEventId -Kind FallbackSkipped) -Message "Mode is $($config.Mode); fallback skipped."
        exit 0
    }

    $lock = Enter-WUOLock
    if (-not $lock) {
        Write-WUOLog -Component 'Fallback' -Message 'Another IntuneWUO run holds the lock; exiting.'
        exit 0
    }

    $state = Get-WUOState
    $backend = Get-WUODefaultFallbackBackend `
        -ModulePath (Join-Path $InstallDir 'ThirdParty\PSWindowsUpdate') `
        -ManifestPath (Join-Path $InstallDir 'ThirdParty\manifest.json')
    Write-WUOLog -Component 'Fallback' -Message "Backend: $($backend.Name)"

    $summary = Invoke-WUOFallbackRun -Config $config -State $state -Backend $backend

    foreach ($d in $summary.Candidates) {
        Write-WUOLog -Component 'Fallback' -Message ("{0} [{1}] eligible={2} reason={3} age={4}d" -f $d.Update.Title, $d.Update.KB, $d.Eligible, $d.Reason, $d.AgeDays)
    }

    switch ($summary.Outcome) {
        'Blocked' {
            Write-WUOLog -Level Warning -Component 'Fallback' -Message ('Blocked by guardrail(s): ' + ($summary.Guardrails -join ', '))
            Write-WUOEvent -Id (Get-WUOEventId -Kind FallbackSkipped) -EntryType Warning -Message ('Blocked: ' + ($summary.Guardrails -join ', '))
        }
        'NothingEligible' {
            Write-WUOLog -Component 'Fallback' -Message 'Nothing overdue; native path is healthy.'
            Write-WUOEvent -Id (Get-WUOEventId -Kind FallbackNothing) -Message 'Nothing overdue; native path is healthy.'
        }
        'Installed' {
            Write-WUOLog -Component 'Fallback' -Message ('Installed: ' + ($summary.Installed -join ', ') + ' (no restart requested)')
            Write-WUOEvent -Id (Get-WUOEventId -Kind FallbackInstalled) -Message ('Installed: ' + ($summary.Installed -join ', '))
        }
        'PartiallyFailed' {
            Write-WUOLog -Level Error -Component 'Fallback' -Message ('Failed: ' + ($summary.Failed -join ', ') + '; installed: ' + ($summary.Installed -join ', '))
            Write-WUOEvent -Id (Get-WUOEventId -Kind FallbackFailed) -EntryType Error -Message ('Failed: ' + ($summary.Failed -join ', '))
        }
    }
    exit 0
}
catch {
    try {
        Write-WUOLog -Level Error -Component 'Fallback' -Message $_.Exception.Message
        Write-WUOEvent -Id 9000 -EntryType Error -Message $_.Exception.Message
    } catch { }
    exit 1
}
finally {
    if ($lock) { Exit-WUOLock -Mutex $lock }
}
