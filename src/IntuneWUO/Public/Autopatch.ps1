$script:WUOBrokerKey = 'HKLM:\SOFTWARE\Microsoft\WindowsAutopatch\ClientBroker'
$script:WUOBrokerLog = 'Microsoft\AutopatchClientBroker\Logs\ClientBroker.log'

function ConvertFrom-WUOReadinessLog {
    <#
    .SYNOPSIS
        Finds the most recent "Completed RunDeviceReadinessChecks" line in Autopatch Client Broker log lines and
        returns ResultsBitmask (0 = all readiness checks passed) and ErrorCodes. Returns $null if none found.
    #>
    [CmdletBinding()]
    param([string[]]$Lines = @())

    $pattern = 'Completed RunDeviceReadinessChecks\. ResultsBitmask=(\d+), ErrorCodes=([^,\]]*)'
    for ($i = $Lines.Count - 1; $i -ge 0; $i--) {
        $m = [regex]::Match($Lines[$i], $pattern)
        if ($m.Success) {
            $codes = @($m.Groups[2].Value -split '[;,]' | Where-Object { $_.Trim() })
            return @{ ResultsBitmask = [int64]$m.Groups[1].Value; ErrorCodes = $codes }
        }
    }
    $null
}

function Get-WUOAutopatchState {
    <#
    .SYNOPSIS
        Reads what the Windows Autopatch Client Broker publishes on the device (read-only):
        the ring, when readiness was last evaluated, and the latest ResultsBitmask/ErrorCodes from its log.
        Deliberately never reads ActionsFeedUri: it carries a signed access token.
    #>
    [CmdletBinding()]
    param(
        [string]$KeyPath = $script:WUOBrokerKey,
        [string]$LogPath = (Join-Path $env:ProgramData $script:WUOBrokerLog)
    )

    $state = @{ BrokerPresent = $false; Ring = $null; ReadinessAt = $null; ResultsBitmask = $null; ErrorCodes = @() }
    if (-not (Test-Path -LiteralPath $KeyPath)) { return $state }

    $state.BrokerPresent = $true
    $key = Get-Item -LiteralPath $KeyPath
    $state.Ring = $key.GetValue('Ring')
    $ts = $key.GetValue('DeviceReadinessTimestamp')
    if ($ts) { $state.ReadinessAt = [DateTimeOffset]::FromUnixTimeSeconds([int64]$ts).LocalDateTime }

    if (Test-Path -LiteralPath $LogPath) {
        $parsed = ConvertFrom-WUOReadinessLog -Lines @(Get-Content -LiteralPath $LogPath -Tail 400 -ErrorAction SilentlyContinue)
        if ($parsed) { $state.ResultsBitmask = $parsed.ResultsBitmask; $state.ErrorCodes = $parsed.ErrorCodes }
    }
    $state
}
