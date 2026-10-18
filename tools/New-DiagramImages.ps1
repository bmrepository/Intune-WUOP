<#
.SYNOPSIS
    Generates the README diagrams as plain SVG images (light and dark variants) in docs\images.
.DESCRIPTION
    Mermaid does not render in every viewer (for example the GitHub mobile app), so each Mermaid diagram in
    the README also has a static SVG. The images are drawn narrow (640 px wide) with large text so they stay
    readable on a phone. Edit the diagram definitions at the bottom, then re-run this script.
.EXAMPLE
    .\tools\New-DiagramImages.ps1
#>
[CmdletBinding()]
param([string]$OutDir)

$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $OutDir) { $OutDir = Join-Path (Join-Path $here '..') 'docs\images' }
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null

$themes = @{
    light = @{
        bg = '#ffffff'; text = '#1f2328'; muted = '#57606a'; arrow = '#57606a'
        proc   = @{ fill = '#eaf2ff'; stroke = '#2f6fdb' }
        decide = @{ fill = '#fff4d6'; stroke = '#b8860b' }
        term   = @{ fill = '#e6f6ea'; stroke = '#2e9e5b' }
        stop   = @{ fill = '#fde8e8'; stroke = '#d14343' }
        note   = @{ fill = '#f2f4f7'; stroke = '#8c959f' }
        panel  = @{ fill = '#f6f8fa'; stroke = '#d0d7de' }
    }
    dark = @{
        bg = '#0d1117'; text = '#e6edf3'; muted = '#9da7b3'; arrow = '#9da7b3'
        proc   = @{ fill = '#14233f'; stroke = '#5b9dff' }
        decide = @{ fill = '#3a2e0f'; stroke = '#e0a526' }
        term   = @{ fill = '#12301e'; stroke = '#3fb96b' }
        stop   = @{ fill = '#3a1517'; stroke = '#f06c6c' }
        note   = @{ fill = '#1c2128'; stroke = '#6e7681' }
        panel  = @{ fill = '#161b22'; stroke = '#30363d' }
    }
}

$W = 640
$FS = 24          # font size
$LH = 31          # line height
$PADY = 15
$CW = $FS * 0.52  # approximate character width

function Esc([string]$s) { [System.Security.SecurityElement]::Escape($s) }

function Wrap([string]$Text, [double]$Width) {
    $max = [math]::Max(8, [int][math]::Floor($Width / $CW))
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($para in $Text -split '\\n') {
        $cur = ''
        foreach ($word in ($para -split ' ')) {
            if (-not $cur) { $cur = $word }
            elseif (($cur.Length + 1 + $word.Length) -le $max) { $cur += ' ' + $word }
            else { $lines.Add($cur); $cur = $word }
        }
        if ($cur) { $lines.Add($cur) }
    }
    , $lines.ToArray()
}

class Canvas {
    [System.Text.StringBuilder]$Panels = (New-Object System.Text.StringBuilder)
    [System.Text.StringBuilder]$Body = (New-Object System.Text.StringBuilder)
}

function New-Box {
    # Draws a rounded box with centred wrapped text. Returns its height.
    param($Canvas, $Theme, [double]$X, [double]$Y, [double]$Width, [string]$Text, [string]$Style = 'proc', [switch]$Bold, [switch]$Measure, [double]$Height = 0)
    $lines = Wrap $Text ($Width - 28)
    $natural = $PADY * 2 + $lines.Count * $LH - ($LH - $FS)
    if ($Measure) { return $natural }
    $h = if ($Height -gt $natural) { $Height } else { $natural }
    $c = $Theme[$Style]
    $sw = if ($Style -eq 'decide') { 3 } else { 2 }
    [void]$Canvas.Body.AppendLine(('<rect x="{0}" y="{1}" width="{2}" height="{3}" rx="12" fill="{4}" stroke="{5}" stroke-width="{6}"/>' -f $X, $Y, $Width, $h, $c.fill, $c.stroke, $sw))
    $weight = if ($Bold) { 'bold' } else { 'normal' }
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $ty = $Y + ($h - ($lines.Count * $LH - ($LH - $FS))) / 2 + $FS * 0.8 + $i * $LH
        [void]$Canvas.Body.AppendLine(('<text x="{0}" y="{1}" text-anchor="middle" font-weight="{2}" fill="{3}">{4}</text>' -f ($X + $Width / 2), $ty, $weight, $Theme.text, (Esc $lines[$i])))
    }
    $h
}

function New-Arrow {
    param($Canvas, $Theme, [double]$X1, [double]$Y1, [double]$X2, [double]$Y2, [string]$Label = '', [string]$LabelSide = 'right')
    [void]$Canvas.Body.AppendLine(('<line x1="{0}" y1="{1}" x2="{2}" y2="{3}" stroke="{4}" stroke-width="3" marker-end="url(#ah)"/>' -f $X1, $Y1, $X2, $Y2, $Theme.arrow))
    if ($Label) {
        $mx = ($X1 + $X2) / 2; $my = ($Y1 + $Y2) / 2
        if ($Y1 -eq $Y2) { $tx = $mx; $ty = $my - 12; $anchor = 'middle' }
        else { $tx = $mx + 10; $ty = $my + 8; $anchor = 'start' }
        [void]$Canvas.Body.AppendLine(('<text x="{0}" y="{1}" text-anchor="{2}" font-size="20" font-weight="bold" fill="{3}">{4}</text>' -f $tx, $ty, $anchor, $Theme.muted, (Esc $Label)))
    }
}

function Complete-Svg {
    param($Canvas, $Theme, [double]$Height, [string]$Title, [string]$Desc)
    @"
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 $W $Height" width="$W" height="$Height" role="img" aria-labelledby="t d" font-family="'Segoe UI', -apple-system, Helvetica, Arial, sans-serif" font-size="$FS">
<title id="t">$(Esc $Title)</title>
<desc id="d">$(Esc $Desc)</desc>
<defs><marker id="ah" viewBox="0 0 10 10" refX="8" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse"><path d="M0,0 L10,5 L0,10 z" fill="$($Theme.arrow)"/></marker></defs>
<rect width="$W" height="$Height" fill="$($Theme.bg)"/>
$($Canvas.Panels.ToString())$($Canvas.Body.ToString())</svg>
"@
}

function New-FlowSvg {
    <# Vertical flow. Each node: Text, Style, optional MainLabel (label on the arrow INTO this node),
       optional Side = @{ Text; Style; Label; Dir = 'out'|'in' } drawn to the right of the node. #>
    param($Theme, [string]$Title, [string]$Desc, $Nodes)
    $cv = New-Object Canvas
    $mainX = 20; $mainW = 360; $sideX = 440; $sideW = 180; $gap = 40
    $y = 20
    $prevBottom = $null
    foreach ($n in $Nodes) {
        $style = if ($n.Style) { $n.Style } else { 'proc' }
        if ($null -ne $prevBottom) {
            New-Arrow $cv $Theme ($mainX + $mainW / 2) $prevBottom ($mainX + $mainW / 2) $y $n.MainLabel
        }
        $h = New-Box $cv $Theme $mainX $y $mainW $n.Text $style -Bold:($style -eq 'term')
        if ($n.Side) {
            $s = $n.Side
            $sh = New-Box $cv $Theme $sideX 0 $sideW $s.Text $(if ($s.Style) { $s.Style } else { 'note' }) -Measure
            $syTop = $y + $h / 2 - $sh / 2
            [void](New-Box $cv $Theme $sideX $syTop $sideW $s.Text $(if ($s.Style) { $s.Style } else { 'note' }))
            $ay = $y + $h / 2
            if ($s.Dir -eq 'in') { New-Arrow $cv $Theme $sideX $ay ($mainX + $mainW) $ay $s.Label }
            else { New-Arrow $cv $Theme ($mainX + $mainW) $ay $sideX $ay $s.Label }
            $rowBottom = [math]::Max($y + $h, $syTop + $sh)
        }
        else { $rowBottom = $y + $h }
        $prevBottom = $y + $h
        $y = $rowBottom + $gap
    }
    Complete-Svg $cv $Theme ($prevBottom + 20) $Title $Desc
}

function Save-Diagram([string]$Name, [scriptblock]$Build) {
    foreach ($t in 'light', 'dark') {
        $svg = & $Build $themes[$t]
        $path = Join-Path $OutDir "$Name-$t.svg"
        [IO.File]::WriteAllText($path, $svg, (New-Object System.Text.UTF8Encoding($false)))
        Write-Host "wrote $path"
    }
}

# --------------------------------------------------------------------------------------------------------
# 1. Architecture (panels, custom layout)
# --------------------------------------------------------------------------------------------------------
Save-Diagram 'architecture' {
    param($T)
    $cv = New-Object Canvas
    $pad = 20; $inner = 600 - 2 * $pad; $colW = ($inner - 14) / 2; $gap = 12
    $st = @{ y = 20 }

    function Add-Panel([string]$Title, [scriptblock]$Content) {
        # Draw contents first to learn the height, then put the panel behind them.
        $top = $st.y
        $st.y += 52
        & $Content
        $height = $st.y - $top + $pad
        $pc = $T.panel
        [void]$cv.Panels.AppendLine(('<rect x="10" y="{0}" width="620" height="{1}" rx="16" fill="{2}" stroke="{3}" stroke-width="2"/>' -f $top, $height, $pc.fill, $pc.stroke))
        [void]$cv.Panels.AppendLine(('<text x="320" y="{0}" text-anchor="middle" font-weight="bold" fill="{1}">{2}</text>' -f ($top + 34), $T.text, (Esc $Title)))
        $st.y = $top + $height
    }
    function Add-Full([string]$Text, [string]$Style, [switch]$Bold) {
        $h = New-Box $cv $T (10 + $pad) $st.y $inner $Text $Style -Bold:$Bold
        $st.y += $h + $gap
    }
    function Add-Pair([string]$Left, [string]$Right, [string]$LStyle, [string]$RStyle) {
        $hl = New-Box $cv $T 0 0 $colW $Left $LStyle -Measure
        $hr = New-Box $cv $T 0 0 $colW $Right $RStyle -Measure
        $h = [math]::Max($hl, $hr)
        [void](New-Box $cv $T (10 + $pad) $st.y $colW $Left $LStyle -Height $h)
        [void](New-Box $cv $T (10 + $pad + $colW + 14) $st.y $colW $Right $RStyle -Height $h)
        $st.y += $h + $gap
    }

    Add-Panel 'Intune + Windows Autopatch (cloud)' {
        Add-Full 'Autopatch policies: rings, approvals, hotpatch' 'proc'
        Add-Pair 'Config package: sets the mode' 'Remediation: detect and fix, every 8 hours' 'proc' 'proc'
        Add-Full 'Win32 app: engine and fallback task' 'proc'
        $st.y -= $gap
    }
    $a1 = $st.y; $st.y += 56
    New-Arrow $cv $T 320 $a1 320 $st.y 'MDM + management agent'

    Add-Panel 'Windows device' {
        Add-Pair 'Intune policy (PolicyManager)' 'Legacy: GPO, WSUS, ConfigMgr' 'proc' 'stop'
        Add-Full 'IntuneWUO engine: detect, fix, fallback' 'term' -Bold
        Add-Pair 'Mode and settings (registry)' 'Fallback task (SYSTEM)' 'proc' 'proc'
        Add-Pair 'Windows Update stack' 'Logs and Event Log' 'proc' 'proc'
        $st.y -= $gap
    }
    $a2 = $st.y; $st.y += 56
    New-Arrow $cv $T 320 $a2 320 $st.y 'status line + logs'
    $h = New-Box $cv $T 30 $st.y 580 'Intune: Remediation output and Collect diagnostics' 'note'
    Complete-Svg $cv $T ($st.y + $h + 20) 'Intune-WUO architecture' 'Intune and Windows Autopatch deliver policy, a config package, the Win32 app and the Remediation to the device. On the device the IntuneWUO engine reads Intune policy and legacy sources, applies safe fixes, runs a fallback task, and reports through logs and the Remediation output.'
}

# --------------------------------------------------------------------------------------------------------
# 2. Detect and remediate (every 8 hours)
# --------------------------------------------------------------------------------------------------------
Save-Diagram 'detect-remediate' {
    param($T)
    New-FlowSvg $T 'Detect and remediate flow' 'Every 8 hours the Remediation checks the mode, collects device state, reports blockers, and only if the mode and switches allow, applies safe fixes with repeat suppression, then writes logs and a status line.' @(
        @{ Text = 'Remediation runs every 8 hours'; Style = 'term' }
        @{ Text = 'Mode is Off?'; Style = 'decide'; MainLabel = ''; Side = @{ Text = 'Yes: stop. Reports Disabled'; Style = 'stop'; Label = 'Yes' } }
        @{ Text = 'Collect device state: policy, services, pauses, sync, disk, Autopatch'; MainLabel = 'No' }
        @{ Text = 'Blockers found?'; Style = 'decide'; Side = @{ Text = 'No: Compliant'; Style = 'term'; Label = 'No' } }
        @{ Text = 'Mode and switches allow a fix?'; Style = 'decide'; MainLabel = 'Yes'; Side = @{ Text = 'No: report only'; Style = 'note'; Label = 'No' } }
        @{ Text = 'Detect exits 1. Remediation script runs under a lock'; MainLabel = 'Yes' }
        @{ Text = 'Fixable, switch on, not a repeat?'; Style = 'decide'; Side = @{ Text = 'No: reported, not changed'; Style = 'note'; Label = 'No' } }
        @{ Text = 'Apply fix. Log before and after'; MainLabel = 'Yes' }
        @{ Text = 'Same fix needed 3 times in 7 days?'; Style = 'decide'; Side = @{ Text = 'Yes: suppressed, reported'; Style = 'stop'; Label = 'Yes' } }
        @{ Text = 'Write logs, events and the status line to Intune'; Style = 'term'; MainLabel = 'No' }
    )
}

# --------------------------------------------------------------------------------------------------------
# 3. Fallback install
# --------------------------------------------------------------------------------------------------------
Save-Diagram 'fallback' {
    param($T)
    New-FlowSvg $T 'Fallback install flow' 'A scheduled task installs overdue, already approved quality updates only when the mode allows it and all guardrails are clear. It never restarts the device.' @(
        @{ Text = 'Scheduled task: daily, at startup, or catch-up'; Style = 'term' }
        @{ Text = 'Mode is RemediateAndFallback?'; Style = 'decide'; Side = @{ Text = 'No: skipped'; Style = 'note'; Label = 'No' } }
        @{ Text = 'Another IntuneWUO run active?'; Style = 'decide'; MainLabel = 'Yes'; Side = @{ Text = 'Yes: exit'; Style = 'note'; Label = 'Yes' } }
        @{ Text = 'Guardrails clear? AC power, disk space, no restart pending, no install running, no maintenance window'; Style = 'decide'; MainLabel = 'No'; Side = @{ Text = 'No: blocked and reported'; Style = 'stop'; Label = 'No' } }
        @{ Text = 'Scan the default Windows Update service: quality and security updates only'; MainLabel = 'Yes' }
        @{ Text = 'Offered longer than ring deadline + grace, under 3 failures?'; Style = 'decide'; Side = @{ Text = 'No: nothing overdue, exit'; Style = 'term'; Label = 'No' } }
        @{ Text = 'Install exactly those updates. Never restart'; MainLabel = 'Yes' }
        @{ Text = 'Record result in logs, events and state'; Style = 'term' }
    )
}

# --------------------------------------------------------------------------------------------------------
# 4. Policy path to the registry
# --------------------------------------------------------------------------------------------------------
Save-Diagram 'policy-to-registry' {
    param($T)
    New-FlowSvg $T 'How an Intune setting reaches the registry' 'Intune and Autopatch policy reaches the device over the MDM channel, is stored per provider under PolicyManager, resolved to a winning value, and read by the Windows Update client together with any Group Policy, WSUS or ConfigMgr leftovers. Intune-WUO reads these locations.' @(
        @{ Text = 'Intune + Autopatch policy'; Style = 'term' }
        @{ Text = 'DMClient: MDM sync over the management channel' }
        @{ Text = 'PolicyManager providers: values as received' }
        @{ Text = 'PolicyManager current: the winning value'; Side = @{ Text = 'Autopatch Client Broker reads and reports'; Style = 'note'; Label = 'reads'; Dir = 'in' } }
        @{ Text = 'Windows Update client: UsoSvc, wuauserv, Orchestrator'; Side = @{ Text = 'GPO, WSUS, ConfigMgr leftovers'; Style = 'stop'; Label = 'also read'; Dir = 'in' } }
        @{ Text = 'State Windows keeps: pause status, restart flags' }
        @{ Text = 'Intune-WUO reads these and only fixes the safe ones'; Style = 'term' }
    )
}




