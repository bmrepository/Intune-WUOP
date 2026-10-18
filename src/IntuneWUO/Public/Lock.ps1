function Enter-WUOLock {
    <#
    .SYNOPSIS
        Takes the machine-wide IntuneWUO mutex shared by the Remediation and the fallback task.
        Returns the mutex object, or $null if another run holds it.
    #>
    [CmdletBinding()]
    param(
        [string]$Name = 'Global\IntuneWUO',
        [int]$TimeoutSeconds = 0
    )
    $mutex = New-Object System.Threading.Mutex($false, $Name)
    $acquired = $false
    try { $acquired = $mutex.WaitOne([TimeSpan]::FromSeconds($TimeoutSeconds)) }
    catch [System.Threading.AbandonedMutexException] { $acquired = $true }
    if ($acquired) { return $mutex }
    $mutex.Dispose()
    $null
}

function Exit-WUOLock {
    [CmdletBinding()]
    param($Mutex)
    if ($Mutex) {
        try { $Mutex.ReleaseMutex() } catch { }
        $Mutex.Dispose()
    }
}
