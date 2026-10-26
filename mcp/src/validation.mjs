// Device-side and Intune-side checks an agent (or admin) runs after each phase.
const IME_LOG = 'C:\\ProgramData\\Microsoft\\IntuneManagementExtension\\Logs\\IntuneWUO\\IntuneWUO.jsonl';

export const PHASES = {
  // Standalone Remediations package (recommended edition)
  detect: [
    { check: 'Detection output reaches Intune', where: 'Intune admin center', command: 'Devices > Scripts and remediations > Intune-WUO > Device status > Pre-remediation detection output', expected: 'Starts with WUO|v1| and shows Mode=Script. Paste it into wuo_interpret_status.' },
    { check: 'Detection ran on the device', where: 'device (elevated PowerShell)', command: `Get-Content '${IME_LOG}' -Tail 5`, expected: "JSON lines from component Detect, 'Detection <version> complete'; no Error entries." },
    { check: 'Event log entries', where: 'device', command: "Get-WinEvent -LogName IntuneWUO -MaxEvents 10 | Select-Object TimeCreated, Id, Message", expected: 'A run-complete event per run, plus one warning per Warning/Critical finding.' },
    { check: 'Nothing was changed', where: 'device', command: "Get-Service wuauserv, UsoSvc, BITS, wlidsvc | Select-Object Name, StartType", expected: 'Same start types as before (detection only changes nothing; its only write is first-seen dates under HKLM\\SOFTWARE\\IntuneWUO\\State).' }
  ],
  fix: [
    { check: 'Remediation is on for the assignment', where: 'Intune admin center', command: 'Intune-WUO > Properties > Assignments', expected: 'The group shows the remediation script as on. (Graph has been seen to read back runRemediationScript: false; trust the admin center and the device status.)' },
    { check: 'Remediation result in Intune', where: 'Intune admin center', command: 'Device status > Remediation status, Pre- and Post-remediation detection output', expected: 'Remediation status Issue fixed or Failed; the remediation output reads WUO|v1|Remediated|Fixed=...|Failed=...|Suppressed=...' },
    { check: 'Fixes and installs are logged', where: 'device', command: `Select-String -Path '${IME_LOG}' -Pattern 'Remediate' | Select-Object -Last 10`, expected: 'Fixed / Failed / Suppressed entries with finding ids; "Update install: <outcome>" when an overdue update was handled.' },
    { check: 'Overdue-update install events', where: 'device', command: 'Get-WinEvent -FilterHashtable @{ LogName = "IntuneWUO"; Id = 4001,4002,4003 } -MaxEvents 10 -ErrorAction SilentlyContinue', expected: '4001 = installed (no restart: it follows the ring deadline), 4002 = failed with HResult, 4003 = blocked by a guardrail (restart pending, low disk, on battery, install running, maintenance window).' },
    { check: 'Fix history', where: 'device', command: "Get-ItemProperty 'HKLM:\\SOFTWARE\\IntuneWUO\\State' -ErrorAction SilentlyContinue", expected: 'FixCount_* and Attempts_* stay low; a fix reaching FixMaxRepeats is suppressed because something keeps undoing it.' }
  ],
  // Win32 app edition
  install: [
    { check: 'Files installed with the expected version', where: 'device (elevated PowerShell)', command: "Get-Content \"$env:ProgramFiles\\IntuneWUO\\version.txt\"", expected: 'The version you built.' },
    { check: 'Fallback task registered as SYSTEM', where: 'device', command: "Get-ScheduledTask -TaskPath '\\IntuneWUO\\' | Select-Object TaskName, State; (Get-ScheduledTask -TaskPath '\\IntuneWUO\\').Principal.UserId", expected: 'IntuneWUO-Fallback, State Ready, UserId SYSTEM.' },
    { check: 'Folder is locked down', where: 'device', command: "(Get-Acl \"$env:ProgramFiles\\IntuneWUO\").Access | Select-Object IdentityReference, FileSystemRights", expected: 'Users have read/execute only.' },
    { check: 'Event log exists', where: 'device', command: "Get-WinEvent -LogName IntuneWUO -MaxEvents 5", expected: 'Events once a detection has run.' }
  ],
  reportonly: [
    { check: 'Mode is ReportOnly', where: 'device', command: "Get-ItemProperty 'HKLM:\\SOFTWARE\\IntuneWUO' | Select-Object Mode", expected: 'ReportOnly (or missing, which also means ReportOnly).' },
    { check: 'Detection output reaches Intune', where: 'Intune admin center', command: 'Devices > Scripts and remediations > IntuneWUO-DetectRemediate > Device status > Pre-remediation detection output', expected: 'Starts with WUO|v1|. Paste it into wuo_interpret_status.' },
    { check: 'Local log shows runs', where: 'device', command: `Get-Content '${IME_LOG}' -Tail 5`, expected: 'JSON lines from component Detect; no Error entries.' },
    { check: 'No change happened', where: 'device', command: "Get-Service wuauserv, UsoSvc, BITS, wlidsvc | Select-Object Name, StartType", expected: 'Same start types as before the pilot (ReportOnly never changes anything).' }
  ],
  remediate: [
    { check: 'Mode is Remediate', where: 'device', command: "Get-ItemProperty 'HKLM:\\SOFTWARE\\IntuneWUO' | Select-Object Mode", expected: 'Remediate.' },
    { check: 'Fixes are logged with outcomes', where: 'device', command: `Select-String -Path '${IME_LOG}' -Pattern 'Remediate' | Select-Object -Last 10`, expected: 'Fixed / Failed / Suppressed entries with finding ids.' },
    { check: 'Remediation status in Intune', where: 'Intune admin center', command: 'Device status > Remediation status; Post-remediation output', expected: 'WUO|v1|Remediated|Fixed=...; Failed and Suppressed lists explained.' },
    { check: 'Fix history', where: 'device', command: "Get-ItemProperty 'HKLM:\\SOFTWARE\\IntuneWUO\\State' -ErrorAction SilentlyContinue", expected: 'FixCount_* values stay low; a count reaching FixMaxRepeats means something keeps undoing the fix.' }
  ],
  fallback: [
    { check: 'Mode is RemediateAndFallback', where: 'device', command: "Get-ItemProperty 'HKLM:\\SOFTWARE\\IntuneWUO' | Select-Object Mode", expected: 'RemediateAndFallback.' },
    { check: 'Task has run', where: 'device', command: "Get-ScheduledTask -TaskPath '\\IntuneWUO\\' | Get-ScheduledTaskInfo | Select-Object LastRunTime, LastTaskResult", expected: 'LastTaskResult 0. The task will not start on battery.' },
    { check: 'Outcome logged', where: 'device', command: `Select-String -Path '${IME_LOG}' -Pattern 'Fallback' | Select-Object -Last 8`, expected: "'Nothing overdue; native path is healthy.' on a current device; guardrail names when blocked." },
    { check: 'Event ids', where: 'device', command: 'Get-WinEvent -FilterHashtable @{ LogName = "IntuneWUO"; Id = 4001,4002,4003,4004 } -MaxEvents 10', expected: '4004 (nothing overdue) is the healthy case; 4001 means it installed an overdue approved update.' }
  ],
  autopatch: [
    { check: 'Client Broker present and reporting', where: 'device', command: "Get-ItemProperty 'HKLM:\\SOFTWARE\\Microsoft\\WindowsAutopatch\\ClientBroker' | Select-Object Ring, DeviceReadinessTimestamp   # do NOT print ActionsFeedUri", expected: 'A ring name and a recent timestamp.' },
    { check: 'Latest readiness verdict', where: 'device', command: "Select-String -Path \"$env:ProgramData\\Microsoft\\AutopatchClientBroker\\Logs\\ClientBroker.log\" -Pattern 'Completed RunDeviceReadinessChecks' | Select-Object -Last 1", expected: 'ResultsBitmask=0 and empty ErrorCodes.' },
    { check: 'Policy arrived', where: 'device', command: "Get-ItemProperty 'HKLM:\\SOFTWARE\\Microsoft\\PolicyManager\\current\\device\\Update'", expected: 'The ring settings (deadlines, grace period, deferrals) from your Autopatch update ring.' }
  ]
};

export function validationChecklist(phase) {
  const list = PHASES[phase];
  if (!list) throw new Error(`Unknown phase '${phase}'. Use one of: ${Object.keys(PHASES).join(', ')}`);
  return { phase, checks: list };
}
