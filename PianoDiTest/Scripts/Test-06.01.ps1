<#
.SYNOPSIS
  Test-06.01 - Honey-object auditing e trap detection.

.DESCRIPTION
  Verifica la presenza dell'honey-object e cerca eventi correlati in Security/Application.
#>

[CmdletBinding()]
param(
    [string]$HoneyUser = 'admin.backup',
    [int]$LookBackHours = 24,
    [switch]$RequireEvents,
    [string]$OutputDir = '.\Esiti'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

$TestId = 'Test-06.01'
$ResolvedOutputDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDir)
if (-not (Test-Path -LiteralPath $ResolvedOutputDir)) { New-Item -ItemType Directory -Path $ResolvedOutputDir -Force | Out-Null }
$OutFile = Join-Path $ResolvedOutputDir "$TestId.out"

Set-Content -Path $OutFile -Encoding UTF8 -Value @(
    "TestId=$TestId",
    "Started=$(Get-Date -Format o)",
    "Computer=$env:COMPUTERNAME",
    "User=$env:USERDOMAIN\$env:USERNAME",
    "HoneyUser=$HoneyUser",
    "LookBackHours=$LookBackHours",
    "RequireEvents=$($RequireEvents.IsPresent)",
    "---"
)

$script:Failed = $false
$script:Warnings = 0
function Write-TestLog { param([string]$Message,[ValidateSet('INFO','PASS','WARN','FAIL','DATA')][string]$Level='INFO') $line="{0} [{1}] {2}" -f (Get-Date -Format o),$Level,$Message; Add-Content -Path $OutFile -Encoding UTF8 -Value $line; Write-Host $line; if($Level -eq 'FAIL'){$script:Failed=$true}; if($Level -eq 'WARN'){$script:Warnings++} }
function Finish-Test { Add-Content -Path $OutFile -Encoding UTF8 -Value @('---',"Warnings=$script:Warnings","Completed=$(Get-Date -Format o)","Result=$(if($script:Failed){'FAIL'}else{'PASS'})"); if($script:Failed){exit 1}else{exit 0} }

try {
    Import-Module ActiveDirectory -ErrorAction Stop
    $u = Get-ADUser -Identity $HoneyUser -Properties DistinguishedName,Enabled,LastLogonDate,MemberOf,ServicePrincipalName -ErrorAction Stop
    Write-TestLog "Honey-object presente: SamAccountName=$($u.SamAccountName); Enabled=$($u.Enabled); DN=$($u.DistinguishedName)" 'PASS'
    Write-TestLog "LastLogonDate=$($u.LastLogonDate); SPN=$($u.ServicePrincipalName -join ',')" 'DATA'
} catch {
    Write-TestLog "Honey-object non trovato o non leggibile: $($_.Exception.Message)" 'FAIL'
    Finish-Test
}

try {
    $auditOut = auditpol /get /category:* 2>&1
    foreach ($line in $auditOut) {
        if ($line -match 'Logon|Account|Kerberos|Credential|Accesso|Account|Credenziali|Convalida') { Write-TestLog "AuditPolicy=$line" 'DATA' }
    }
    Write-TestLog 'Audit policy ispezionata' 'PASS'
} catch { Write-TestLog "Impossibile leggere auditpol: $($_.Exception.Message)" 'WARN' }

$start = (Get-Date).AddHours(-1 * $LookBackHours)
$events = @()

try {
    $securityEvents = Get-WinEvent -FilterHashtable @{ LogName='Security'; Id=4625,4771,4776,4740,4662; StartTime=$start } -ErrorAction SilentlyContinue |
        Where-Object { $_.Message -match [regex]::Escape($HoneyUser) }
    $events += $securityEvents
    Write-TestLog "SecurityEventsMatched=$(@($securityEvents).Count)" 'DATA'
} catch { Write-TestLog "Errore lettura Security log: $($_.Exception.Message)" 'WARN' }

try {
    $customEvents = Get-WinEvent -FilterHashtable @{ LogName='Application'; ProviderName='LAB-AD-HoneyTrap'; Id=6601,6602; StartTime=$start } -ErrorAction SilentlyContinue |
        Where-Object { $_.Message -match [regex]::Escape($HoneyUser) }
    $events += $customEvents
    Write-TestLog "CustomTrapEventsMatched=$(@($customEvents).Count)" 'DATA'
} catch { Write-TestLog "Eventi custom LAB-AD-HoneyTrap non leggibili o non presenti: $($_.Exception.Message)" 'WARN' }

$events = @($events | Sort-Object TimeCreated)
if ($events.Count -gt 0) {
    Write-TestLog "Eventi rilevanti trovati: $($events.Count)" 'PASS'
    foreach ($e in $events) {
        Write-TestLog "Event Time=$($e.TimeCreated.ToString('o')); Id=$($e.Id); Provider=$($e.ProviderName); Machine=$($e.MachineName)" 'DATA'
        $msg = ($e.Message -replace "`r|`n", ' ')
        if ($msg.Length -gt 1200) { $msg = $msg.Substring(0,1200) + '...' }
        Write-TestLog "EventMessage=$msg" 'DATA'
    }
} else {
    $msg = "Nessun evento rilevante trovato per $HoneyUser nelle ultime $LookBackHours ore. Eseguire Setup-Test-06.01-Detection.ps1 -EmitTrapEvent e verificare audit policy/logging."
    if ($RequireEvents) { Write-TestLog $msg 'FAIL' } else { Write-TestLog $msg 'WARN' }
}
Finish-Test
