<#
.SYNOPSIS
  Setup-Test-06.01-Detection - Configura un setup sicuro di detection per honey-object AD.

.DESCRIPTION
  Questo script NON esegue attacchi a forza bruta e NON tenta di carpire password.
  Configura invece un harness difensivo per generare e rilevare segnali controllati:
    - verifica honey user;
    - registra una sorgente eventi custom LAB-AD-HoneyTrap;
    - genera un evento custom di simulazione trap;
    - crea, opzionalmente, un monitor schedulato che cerca eventi Security e custom correlati all'honey user;
    - opzionalmente invia email se viene fornito un server SMTP.

  Eventi cercati dal monitor:
    - 4625: failed logon
    - 4771: Kerberos pre-authentication failed
    - 4776: credential validation failed
    - 4740: account locked out
    - 4662: directory service access, se auditing/SACL sono configurati
    - 6601/6602: eventi custom LAB-AD-HoneyTrap

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

function Write-Info($m) { Write-Host "[INFO] $m" }
function Write-Warn($m) { Write-Warning $m }
function Write-Fail($m) { Write-Error $m }

$source = 'LAB-AD-HoneyTrap'
$logName = 'Application'

New-Item -ItemType Directory -Path $AlertRoot -Force | Out-Null

try {
    Import-Module ActiveDirectory -ErrorAction Stop
    $u = Get-ADUser -Identity $HoneyUser -Properties DistinguishedName,Enabled,LastLogonDate,MemberOf -ErrorAction Stop
    Write-Info "Honey user trovato: $($u.SamAccountName) DN=$($u.DistinguishedName) Enabled=$($u.Enabled)"
}
catch {
    throw "Honey user '$HoneyUser' non trovato o modulo AD non disponibile: $($_.Exception.Message)"
}

try {
    if (-not [System.Diagnostics.EventLog]::SourceExists($source)) {
        New-EventLog -LogName $logName -Source $source
        Write-Info "Sorgente eventi creata: $source su $logName"
    }
    else {
        Write-Info "Sorgente eventi gia' presente: $source"
    }
}
catch {
    throw "Impossibile creare/verificare event source $source. Eseguire come amministratore. Dettaglio: $($_.Exception.Message)"
}

# Best effort: mostra audit policy corrente. Non forza nomi localizzati, per evitare rotture su OS in italiano.
$auditFile = Join-Path $AlertRoot 'auditpol-current.txt'
try {
    auditpol /get /category:* | Out-File -FilePath $auditFile -Encoding UTF8
    Write-Info "Audit policy corrente esportata in $auditFile"
    Write-Warn "Verificare che siano abilitati almeno: Account Logon/Credential Validation, Kerberos Authentication Service, Logon, Account Lockout. I nomi possono essere localizzati."
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
    `$sec = Get-WinEvent -FilterHashtable @{ LogName='Security'; Id=4625,4771,4776,4740,4662; StartTime=`$start } -ErrorAction SilentlyContinue |
        Where-Object { `$_.Message -match [regex]::Escape(`$HoneyUser) }
    `$events += `$sec
}
catch {}

try {
    `$custom = Get-WinEvent -FilterHashtable @{ LogName='Application'; ProviderName='LAB-AD-HoneyTrap'; Id=6601,6602; StartTime=`$start } -ErrorAction SilentlyContinue |
        Where-Object { `$_.Message -match [regex]::Escape(`$HoneyUser) }
    `$events += `$custom
}
catch {}

if (`$events.Count -gt 0) {
    `$lines = New-Object System.Collections.Generic.List[string]
    `$lines.Add('==== HONEY TRAP ALERT ' + `$now.ToString('o') + ' ====')
    `$lines.Add('HoneyUser=' + `$HoneyUser)
    foreach (`$e in `$events | Sort-Object TimeCreated) {
        `$lines.Add(('Time={0}; Id={1}; Provider={2}; Machine={3}' -f `$e.TimeCreated.ToString('o'), `$e.Id, `$e.ProviderName, `$e.MachineName))
        `$msg = (`$e.Message -replace "`r|`n", ' ')
        if (`$msg.Length -gt 1000) { `$msg = `$msg.Substring(0,1000) + '...' }
        `$lines.Add('Message=' + `$msg)
    }
    Add-Content -Path `$alertFile -Value `$lines -Encoding UTF8

    if (`$SmtpServer -and `$MailFrom -and `$MailTo) {
        try {
            Send-MailMessage -SmtpServer `$SmtpServer -From `$MailFrom -To `$MailTo -Subject "LAB HoneyTrap alert: `$HoneyUser" -Body (`$lines -join "`r`n")
        }
        catch {
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

    try {
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Force | Out-Null
        Write-Info "Scheduled task creata/aggiornata: $taskName ogni $MonitorIntervalMinutes minuti"
    }
    catch {
        throw "Errore creazione scheduled task: $($_.Exception.Message)"
    }
}

Write-Info "Setup completato."
Write-Info "Per generare un segnale sicuro immediato: rieseguire con -EmitTrapEvent oppure usare Write-EventLog con source $source e EventId 6601."
