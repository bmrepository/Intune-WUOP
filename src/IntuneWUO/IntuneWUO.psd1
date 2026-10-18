@{
    RootModule        = 'IntuneWUO.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = '5b0e6c1e-6a52-4d0e-9f0b-2f7a1d7a3c11'
    Author            = 'Intune-WUO contributors'
    Description       = 'Detect, report and (later) remediate device-side blockers for Windows Autopatch managed devices.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @(
        'Get-WUOConfig'
        'ConvertTo-WUOConfig'
        'Write-WUOLog'
        'Get-WUOState'
        'Get-WUOFinding'
        'Format-WUOStatus'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
