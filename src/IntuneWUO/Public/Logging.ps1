function Write-WUOLog {
    <#
    .SYNOPSIS
        Appends a JSON line and a CMTrace-format line to the IntuneWUO log folder.
        Never throws: logging must not break a run.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('Info', 'Warning', 'Error')][string]$Level = 'Info',
        [string]$Component = 'IntuneWUO',
        [hashtable]$Data,
        [string]$LogDir = (Join-Path $env:ProgramData 'Microsoft\IntuneManagementExtension\Logs\IntuneWUO'),
        [int64]$MaxBytes = 5MB
    )

    try {
        # Under SYSTEM the IME logs folder is writable. Elsewhere (for example a non-admin test run) fall back to %TEMP%.
        try {
            if (-not (Test-Path -LiteralPath $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force -ErrorAction Stop | Out-Null }
            $probe = Join-Path $LogDir '.write-test'
            Set-Content -LiteralPath $probe -Value '' -ErrorAction Stop
            Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
        }
        catch {
            $LogDir = Join-Path $env:TEMP 'IntuneWUO'
            if (-not (Test-Path -LiteralPath $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
        }

        $now = Get-Date
        $jsonFile = Join-Path $LogDir 'IntuneWUO.jsonl'
        $cmFile = Join-Path $LogDir 'IntuneWUO.log'

        foreach ($f in $jsonFile, $cmFile) {
            if ((Test-Path -LiteralPath $f) -and (Get-Item -LiteralPath $f).Length -gt $MaxBytes) {
                Move-Item -LiteralPath $f -Destination ($f + '.old') -Force
            }
        }

        $entry = [ordered]@{
            time      = $now.ToString('o')
            level     = $Level
            component = $Component
            message   = $Message
        }
        if ($Data) { $entry['data'] = $Data }
        Add-Content -LiteralPath $jsonFile -Value ($entry | ConvertTo-Json -Compress -Depth 5) -Encoding UTF8

        $type = switch ($Level) { 'Warning' { 2 } 'Error' { 3 } default { 1 } }
        $cm = '<![LOG[{0}]LOG]!><time="{1}" date="{2}" component="{3}" context="" type="{4}" thread="{5}" file="">' -f `
            $Message, $now.ToString('HH:mm:ss.fff+000'), $now.ToString('MM-dd-yyyy'), $Component, $type, $PID
        Add-Content -LiteralPath $cmFile -Value $cm -Encoding UTF8
    }
    catch {
        # Swallow: a logging failure must never fail detection.
    }
}
