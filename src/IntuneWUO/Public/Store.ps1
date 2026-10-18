function Get-WUOStoreValue {
    <# Reads a value from the tool-owned State key (attempt counters, first-seen dates, fix history). #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$StatePath = 'HKLM:\SOFTWARE\IntuneWUO\State'
    )
    if (-not (Test-Path -LiteralPath $StatePath)) { return $null }
    (Get-Item -LiteralPath $StatePath).GetValue($Name)
}

function Set-WUOStoreValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]$Value,
        [string]$StatePath = 'HKLM:\SOFTWARE\IntuneWUO\State'
    )
    if (-not (Test-Path -LiteralPath $StatePath)) { New-Item -Path $StatePath -Force | Out-Null }
    if ($Value -is [datetime]) { $Value = $Value.ToString('o') }
    Set-ItemProperty -LiteralPath $StatePath -Name $Name -Value $Value
}

function Remove-WUOStoreValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$StatePath = 'HKLM:\SOFTWARE\IntuneWUO\State'
    )
    if (Test-Path -LiteralPath $StatePath) {
        Remove-ItemProperty -LiteralPath $StatePath -Name $Name -ErrorAction SilentlyContinue
    }
}

function Get-WUOStoreDate {
    <# Reads a date written by Set-WUOStoreValue; returns $null if missing or unparsable. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$StatePath = 'HKLM:\SOFTWARE\IntuneWUO\State'
    )
    $raw = Get-WUOStoreValue -Name $Name -StatePath $StatePath
    $parsed = [datetime]::MinValue
    if ($raw -and [datetime]::TryParse([string]$raw, [ref]$parsed)) { return $parsed }
    $null
}
