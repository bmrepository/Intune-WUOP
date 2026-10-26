function Format-WUOStatus {
    <#
    .SYNOPSIS
        Builds the compact status string reported through Remediation output.
        Never longer than $MaxLength (Intune truncates output at 2,048 characters).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [object[]]$Findings = @(),
        [int]$Build = 0,
        [string]$Ring,
        [switch]$Disabled,
        # Shown as Mode=; the standalone Remediations package passes 'Script' because Intune, not Mode, decides.
        [string]$ModeLabel,
        [int]$MaxLength = 2048
    )
    if (-not $ModeLabel) { $ModeLabel = $Config.Mode }

    $result = if ($Disabled) { 'Disabled' }
    elseif (@($Findings | Where-Object { $_.Severity -in 'Warning', 'Critical' }).Count -gt 0) { 'NonCompliant' }
    else { 'Compliant' }

    $head = 'WUO|v1|{0}|Mode={1}|Build={2}' -f $result, $ModeLabel, $Build
    if ($Ring) { $head += '|Ring=' + ($Ring -replace '[^A-Za-z0-9_.-]', '') }
    $ids = @($Findings | Sort-Object @{ Expression = { switch ($_.Severity) { 'Critical' { 0 } 'Warning' { 1 } default { 2 } } } }, Id |
        ForEach-Object { $_.Id })
    if ($ids.Count -eq 0) { return $head }

    $out = $head + '|F='
    $used = 0
    foreach ($id in $ids) {
        $remaining = $ids.Count - $used
        # Reserve room for a "+N" overflow marker.
        $candidate = $out + $(if ($used) { ',' } else { '' }) + $id
        if (($candidate.Length + 6) -gt $MaxLength -and $remaining -gt 1) { break }
        $out = $candidate
        $used++
    }
    if ($used -lt $ids.Count) { $out += '+' + ($ids.Count - $used) }
    if ($out.Length -gt $MaxLength) { $out = $out.Substring(0, $MaxLength) }
    $out
}
