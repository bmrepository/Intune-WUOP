# PSWindowsUpdate is only ever reached through this allow-list. Anything not listed is refused.
$script:WUOAllowedCalls = @{
    'Get-WindowsUpdate'     = @('Install', 'AcceptAll', 'IgnoreReboot', 'UpdateID', 'Download')
    'Get-WUHistory'         = @('Last', 'MaxDate')
    'Get-WULastResults'     = @()
    'Get-WURebootStatus'    = @('Silent')
    'Get-WUInstallerStatus' = @()
    'Reset-WUComponents'    = @()
}
$script:WUOBlockedCalls = @(
    'Set-WUSettings', 'Set-PSWUSettings', 'Add-WUServiceManager', 'Remove-WUServiceManager',
    'Enable-WURemoting', 'Invoke-WUJob', 'Update-WUModule', 'Remove-WindowsUpdate', 'Get-WUOfflineMSU'
)
$script:WUOCommonParams = @('Verbose', 'Debug', 'ErrorAction', 'WarningAction', 'ErrorVariable', 'WarningVariable', 'OutVariable', 'OutBuffer', 'PipelineVariable', 'InformationAction', 'InformationVariable')

function Test-WUOModuleCall {
    <#
    .SYNOPSIS
        Validates a planned PSWindowsUpdate call against the allow-list.
        Returns an object with Allowed ($true/$false) and Reason.
        Blocks policy writers, service-manager changes, -MicrosoftUpdate, -KBArticleID, and installs that
        do not name exact update ids.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Cmdlet,
        [hashtable]$Parameters = @{}
    )

    if ($script:WUOBlockedCalls -contains $Cmdlet) {
        return [pscustomobject]@{ Allowed = $false; Reason = "Cmdlet '$Cmdlet' is blocked." }
    }
    if (-not $script:WUOAllowedCalls.ContainsKey($Cmdlet)) {
        return [pscustomobject]@{ Allowed = $false; Reason = "Cmdlet '$Cmdlet' is not on the allow-list." }
    }
    $allowed = @($script:WUOAllowedCalls[$Cmdlet]) + $script:WUOCommonParams
    foreach ($p in $Parameters.Keys) {
        if ($allowed -notcontains $p) {
            return [pscustomobject]@{ Allowed = $false; Reason = "Parameter '-$p' is not allowed on $Cmdlet." }
        }
    }
    if ($Cmdlet -eq 'Get-WindowsUpdate' -and ($Parameters.ContainsKey('Install') -or $Parameters.ContainsKey('Download'))) {
        $ids = @($Parameters['UpdateID'])
        if ($ids.Count -eq 0 -or -not $ids[0]) {
            return [pscustomobject]@{ Allowed = $false; Reason = 'Install/Download requires explicit -UpdateID values.' }
        }
    }
    [pscustomobject]@{ Allowed = $true; Reason = '' }
}

function Test-WUOModuleIntegrity {
    <#
    .SYNOPSIS
        Checks every file listed in manifest.json (path -> SHA-256) under -ModulePath, and that no extra
        files are present. Returns Valid and a list of Problems.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ModulePath,
        [Parameter(Mandatory)][string]$ManifestPath
    )

    $problems = New-Object System.Collections.Generic.List[string]
    if (-not (Test-Path -LiteralPath $ManifestPath)) {
        return [pscustomobject]@{ Valid = $false; Problems = @('Manifest not found.') }
    }
    if (-not (Test-Path -LiteralPath $ModulePath)) {
        return [pscustomobject]@{ Valid = $false; Problems = @('Module folder not found.') }
    }

    $manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
    $expected = @{}
    foreach ($prop in $manifest.files.PSObject.Properties) { $expected[$prop.Name] = $prop.Value }
    if ($expected.Count -eq 0) { $problems.Add('Manifest lists no files.') }

    $root = (Resolve-Path -LiteralPath $ModulePath).Path.TrimEnd('\')
    $actualFiles = @(Get-ChildItem -LiteralPath $root -Recurse -File)
    foreach ($f in $actualFiles) {
        $rel = $f.FullName.Substring($root.Length + 1)
        if (-not $expected.ContainsKey($rel)) { $problems.Add("Unexpected file: $rel"); continue }
        $hash = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash
        if ($hash -ne $expected[$rel]) { $problems.Add("Hash mismatch: $rel") }
    }
    foreach ($rel in $expected.Keys) {
        if (-not (Test-Path -LiteralPath (Join-Path $root $rel))) { $problems.Add("Missing file: $rel") }
    }
    [pscustomobject]@{ Valid = ($problems.Count -eq 0); Problems = $problems.ToArray() }
}

function Invoke-WUOModuleCommand {
    <#
    .SYNOPSIS
        Runs one allow-listed PSWindowsUpdate cmdlet from the pinned, hash-verified copy.
        Throws if the call is not allowed or the module fails verification.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Cmdlet,
        [hashtable]$Parameters = @{},
        [Parameter(Mandatory)][string]$ModulePath,
        [Parameter(Mandatory)][string]$ManifestPath
    )

    $check = Test-WUOModuleCall -Cmdlet $Cmdlet -Parameters $Parameters
    if (-not $check.Allowed) { throw "Refused: $($check.Reason)" }

    $integrity = Test-WUOModuleIntegrity -ModulePath $ModulePath -ManifestPath $ManifestPath
    if (-not $integrity.Valid) { throw "PSWindowsUpdate failed verification: $($integrity.Problems -join '; ')" }

    Import-Module (Join-Path $ModulePath 'PSWindowsUpdate.psd1') -Force -ErrorAction Stop
    & $Cmdlet @Parameters
}

function Get-WUOBackendName {
    <#
    .SYNOPSIS
        Chooses the update backend: 'PSWindowsUpdate' when the pinned copy is present and verifies in
        FullLanguage mode, otherwise 'WuaCom'.
    #>
    [CmdletBinding()]
    param(
        [string]$ModulePath,
        [string]$ManifestPath,
        [string]$LanguageMode = "$($ExecutionContext.SessionState.LanguageMode)"
    )

    if ($LanguageMode -ne 'FullLanguage') { return 'WuaCom' }
    if (-not $ModulePath -or -not $ManifestPath) { return 'WuaCom' }
    if (-not (Test-Path -LiteralPath (Join-Path $ModulePath 'PSWindowsUpdate.psd1'))) { return 'WuaCom' }
    if ((Test-WUOModuleIntegrity -ModulePath $ModulePath -ManifestPath $ManifestPath).Valid) { return 'PSWindowsUpdate' }
    'WuaCom'
}
