<#
.SYNOPSIS
  Setup-Test-06.01-Detection - Setup sicuro per honey-object detection.

.DESCRIPTION
  Non esegue attacchi a forza bruta e non tenta di carpire password.
  Prepara un harness difensivo:
  - verifica honey user;
  - registra sorgente eventi custom LAB-AD-HoneyTrap;
  - genera evento custom di simulazione trap;
  - crea opzionalmente monitor schedulato con alert su file/email.

.NOTES
  Eseguire su DC01 come amministratore.
#>

[CmdletBinding()]
param(
    [string]$HoneyUser = 'admin.backup',
    [string]$AlertRoot = 'C:\LAB-AD\Alerts',
    [switch]$CreateScheduledMonitor,
    [int]$MonitorIntervalMinutes = 5,
    [string]$SmtpServer,
    [string]$MailFrom,
    [string]$MailTo,
    [switch]$EmitTrapEvent
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Info { param([string]$Message) Write-Host "[INFO] $Message" }
function Write-Warn { param([string]$Message) Write-Warning $Message }

$source = 'LAB-AD-HoneyTrap'
$logName = 'Application'
New-Item -ItemType Directory -Path $AlertRoot -Force | Out-Null

Import-Module ActiveDirectory -ErrorAction Stop
$u = Get-ADUser -Identity $HoneyUser -Properties DistinguishedName,Enabled,LastLogonDate,MemberOf -ErrorAction Stop
Write-Info "Honey user trovato: $($u.SamAccountName); DN=$($u.DistinguishedName); Enabled=$($u.Enabled)"

if (-not [System.Diagnostics.EventLog]::SourceExists($source)) {
    New-EventLog -LogName $logName -Source $source
    Write-Info "Sorgente eventi creata: $source su $logName"
}
else {
    Write-Info "Sorgente eventi gia' presente: $source"
}

$auditFile = Join-Path $AlertRoot 'auditpol-current.txt'
try {
    auditpol /get /category:* | Out-File -FilePath $auditFile -Encoding UTF8
    Write-Info "Audit policy corrente esportata in $auditFile"
    Write-Warn "Verificare che siano abilitati auditing per Logon, Account Logon, Kerberos, Credential Validation, Account Lockout e Directory Service Access se richiesto."
}
catch {
    Write-Warn "Impossibile esportare auditpol: $($_.Exception.Message)"
}

if ($EmitTrapEvent) {
    $msg = "SIMULAZIONE SICURA TRAP: attivita' sospetta controllata su honey user '$HoneyUser'. Nessun brute force eseguito. Timestamp=$(Get-Date -Format o)"
    Write-EventLog -LogName $logName -Source $source -EventId 6601 -EntryType Warning -Message $msg
    Write-Info "Evento custom 6601 generato per $HoneyUser"
}

$monitorScript = Join-Path $AlertRoot 'HoneyTrap-Monitor.ps1'
$monitorContent = @"
param(
    [string]`$HoneyUser = '$HoneyUser',
    [string]`$AlertRoot = '$AlertRoot',
    [int]`$LookBackMinutes = 10,
    [string]`$SmtpServer = '$SmtpServer',
    [string]`$MailFrom = '$MailFrom',
    [string]`$MailTo = '$MailTo'
)

`$ErrorActionPreference = 'Continue'
New-Item -ItemType Directory -Path `$AlertRoot -Force | Out-Null
`$now = Get-Date
`$start = `$now.AddMinutes(-1 * `$LookBackMinutes)
`$alertFile = Join-Path `$AlertRoot ('HoneyTrap-Alerts-{0}.log' -f `$now.ToString('yyyyMMdd'))
`$events = @()

try {
    `$sec = Get-WinEvent -FilterHashtable @{ LogName='Security'; Id=4625,4771,4776,4740,4662,4768,4769,4624,4672; StartTime=`$start } -ErrorAction SilentlyContinue |
        Where-Object { `$_.Message -match [regex]::Escape(`$HoneyUser) }
    `$events += `$sec
} catch {}

try {
    `$custom = Get-WinEvent -FilterHashtable @{ LogName='Application'; ProviderName='LAB-AD-HoneyTrap'; Id=6601,6602,6701,6702; StartTime=`$start } -ErrorAction SilentlyContinue |
        Where-Object { `$_.Message -match [regex]::Escape(`$HoneyUser) }
    `$events += `$custom
} catch {}

if (`$events.Count -gt 0) {
    `$lines = New-Object System.Collections.Generic.List[string]
    `$lines.Add('==== HONEY/KERBEROS TRAP ALERT ' + `$now.ToString('o') + ' ====')
    `$lines.Add('Subject=' + `$HoneyUser)
    foreach (`$e in `$events | Sort-Object TimeCreated) {
        `$lines.Add(('Time={0}; Id={1}; Provider={2}; Machine={3}' -f `$e.TimeCreated.ToString('o'), `$e.Id, `$e.ProviderName, `$e.MachineName))
        `$msg = (`$e.Message -replace "`r|`n", ' ')
        if (`$msg.Length -gt 1200) { `$msg = `$msg.Substring(0,1200) + '...' }
        `$lines.Add('Message=' + `$msg)
    }
    Add-Content -Path `$alertFile -Value `$lines -Encoding UTF8

    if (`$SmtpServer -and `$MailFrom -and `$MailTo) {
        try {
            Send-MailMessage -SmtpServer `$SmtpServer -From `$MailFrom -To `$MailTo -Subject "LAB Security Trap alert: `$HoneyUser" -Body (`$lines -join "`r`n")
        } catch {
            Add-Content -Path `$alertFile -Value ('MAIL_SEND_ERROR=' + `$_.Exception.Message) -Encoding UTF8
        }
    }
}
"@
Set-Content -Path $monitorScript -Value $monitorContent -Encoding UTF8
Write-Info "Monitor script creato: $monitorScript"

if ($CreateScheduledMonitor) {
    $taskName = 'LAB-HoneyTrap-Monitor'
    $ps = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $arg = "-NoProfile -ExecutionPolicy Bypass -File `"$monitorScript`""
    $action = New-ScheduledTaskAction -Execute $ps -Argument $arg
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes $MonitorIntervalMinutes) -RepetitionDuration (New-TimeSpan -Days 3650)
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Force | Out-Null
    Write-Info "Scheduled task creata/aggiornata: $taskName ogni $MonitorIntervalMinutes minuti"
}

Write-Info 'Setup completato.'
