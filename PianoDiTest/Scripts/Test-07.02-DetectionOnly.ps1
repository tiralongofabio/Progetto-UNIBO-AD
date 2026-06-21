<#
.SYNOPSIS
  Test-07.02-DetectionOnly - Silver/Golden Ticket detection harness.

.DESCRIPTION
  Non crea, non firma e non inietta ticket.
  Cerca indicatori di detection in Security log e in eventi custom trap.
#>

[CmdletBinding()]
param(
    [string]$HoneyUser='admin.backup',
    [int]$LookBackHours=24,
    [switch]$RequireEvents,
    [string]$OutputDir='.\Esiti'
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Continue'
$TestId='Test-07.02'
$ResolvedOutputDir=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDir);if(!(Test-Path $ResolvedOutputDir)){New-Item -ItemType Directory -Path $ResolvedOutputDir -Force|Out-Null}
$OutFile=Join-Path $ResolvedOutputDir "$TestId.out";Set-Content $OutFile @("TestId=$TestId","Mode=DetectionOnly","Started=$(Get-Date -Format o)","Computer=$env:COMPUTERNAME","User=$env:USERDOMAIN\$env:USERNAME","HoneyUser=$HoneyUser","LookBackHours=$LookBackHours","---") -Encoding UTF8
$script:Failed=$false;$script:Warnings=0
function Write-TestLog{param([string]$Message,[ValidateSet('INFO','PASS','WARN','FAIL','DATA')][string]$Level='INFO')$line="{0} [{1}] {2}" -f (Get-Date -Format o),$Level,$Message;Add-Content $OutFile $line -Encoding UTF8;Write-Host $line;if($Level-eq'FAIL'){$script:Failed=$true};if($Level-eq'WARN'){$script:Warnings++}}
function Finish-Test{Add-Content $OutFile @('---',"Warnings=$script:Warnings","Completed=$(Get-Date -Format o)","Result=$(if($script:Failed){'FAIL'}else{'PASS'})") -Encoding UTF8;if($script:Failed){exit 1}else{exit 0}}
try{Import-Module ActiveDirectory -ErrorAction Stop;$u=Get-ADUser -Identity $HoneyUser -Properties SID,Enabled,DistinguishedName -ErrorAction Stop;$domainSid=(Get-ADDomain).DomainSID.Value;Write-TestLog "HoneyUser trovato: SID=$($u.SID); Enabled=$($u.Enabled); DN=$($u.DistinguishedName)" PASS;Write-TestLog "DomainSID=$domainSid" DATA}catch{Write-TestLog "HoneyUser/Dominio non leggibile: $($_.Exception.Message)" FAIL;Finish-Test}
try{$klist = klist 2>&1;foreach($line in $klist){Write-TestLog "KLIST=$line" DATA};Write-TestLog 'Cache Kerberos locale ispezionata' PASS}catch{Write-TestLog "klist non disponibile o errore: $($_.Exception.Message)" WARN}
$start=(Get-Date).AddHours(-1*$LookBackHours);$events=@()
try{$sec=Get-WinEvent -FilterHashtable @{LogName='Security';Id=4624,4672,4768,4769,4770,4771,4776;StartTime=$start} -ErrorAction SilentlyContinue | Where-Object {$_.Message -match [regex]::Escape($HoneyUser)};$events+=$sec;Write-TestLog "SecurityEventsMatched=$(@($sec).Count)" DATA}catch{Write-TestLog "Errore lettura Security log: $($_.Exception.Message)" WARN}
try{$custom=Get-WinEvent -FilterHashtable @{LogName='Application';ProviderName='LAB-AD-HoneyTrap';Id=6601,6602,6701,6702;StartTime=$start} -ErrorAction SilentlyContinue | Where-Object {$_.Message -match [regex]::Escape($HoneyUser)};$events+=$custom;Write-TestLog "CustomTrapEventsMatched=$(@($custom).Count)" DATA}catch{Write-TestLog "Eventi custom non disponibili: $($_.Exception.Message)" WARN}
$events=@($events|Sort-Object TimeCreated)
if($events.Count){Write-TestLog "Eventi Kerberos/logon correlati rilevati: $($events.Count)" PASS;foreach($e in $events){Write-TestLog "Event Time=$($e.TimeCreated.ToString('o')); Id=$($e.Id); Provider=$($e.ProviderName); Machine=$($e.MachineName)" DATA;$msg=($e.Message -replace "`r|`n",' ');if($msg.Length -gt 1200){$msg=$msg.Substring(0,1200)+'...'};Write-TestLog "EventMessage=$msg" DATA}}else{$msg="Nessun evento Kerberos/logon/custom correlato a $HoneyUser nelle ultime $LookBackHours ore";if($RequireEvents){Write-TestLog $msg FAIL}else{Write-TestLog $msg WARN}}
Finish-Test
