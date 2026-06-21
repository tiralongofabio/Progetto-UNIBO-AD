<#
.SYNOPSIS
  Test-07.01-DetectionOnly - Kerberoasting detection-only.

.DESCRIPTION
  Non estrae ticket, non salva hash, non esegue cracking.
  Verifica auditing Kerberos e cerca eventi TGS 4769 correlati ad account/SPN osservati.
  Gli step offensivi, se richiesti dal corso, restano manuali e fuori dallo script.
#>

[CmdletBinding()]
param(
    [string]$TargetAccount = 'admin.backup',
    [int]$LookBackHours = 24,
    [switch]$RequireEvents,
    [string]$OutputDir = '.\Esiti'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'
$TestId='Test-07.01'
$ResolvedOutputDir=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDir)
if(!(Test-Path $ResolvedOutputDir)){New-Item -ItemType Directory -Path $ResolvedOutputDir -Force|Out-Null}
$OutFile=Join-Path $ResolvedOutputDir "$TestId.out"
Set-Content $OutFile @("TestId=$TestId","Mode=DetectionOnly","Started=$(Get-Date -Format o)","Computer=$env:COMPUTERNAME","User=$env:USERDOMAIN\$env:USERNAME","TargetAccount=$TargetAccount","LookBackHours=$LookBackHours","---") -Encoding UTF8
$script:Failed=$false;$script:Warnings=0
function Write-TestLog{param([string]$Message,[ValidateSet('INFO','PASS','WARN','FAIL','DATA')][string]$Level='INFO')$line="{0} [{1}] {2}" -f (Get-Date -Format o),$Level,$Message;Add-Content $OutFile $line -Encoding UTF8;Write-Host $line;if($Level-eq'FAIL'){$script:Failed=$true};if($Level-eq'WARN'){$script:Warnings++}}
function Finish-Test{Add-Content $OutFile @('---',"Warnings=$script:Warnings","Completed=$(Get-Date -Format o)","Result=$(if($script:Failed){'FAIL'}else{'PASS'})") -Encoding UTF8;if($script:Failed){exit 1}else{exit 0}}
try{Import-Module ActiveDirectory -ErrorAction Stop;$acct=Get-ADUser -Identity $TargetAccount -Properties ServicePrincipalName,Enabled,DistinguishedName -ErrorAction Stop;Write-TestLog "TargetAccount trovato: Enabled=$($acct.Enabled); DN=$($acct.DistinguishedName)" PASS; if($acct.ServicePrincipalName){foreach($spn in $acct.ServicePrincipalName){Write-TestLog "SPN=$spn" DATA}}else{Write-TestLog "Nessun SPN sul target account; scenario Kerberoasting diretto non applicabile al target" WARN}}catch{Write-TestLog "Account target non trovato: $($_.Exception.Message)" FAIL;Finish-Test}
try{$audit=auditpol /get /subcategory:* 2>&1;foreach($l in $audit|Where-Object{$_ -match 'Kerberos|Account Logon|Accesso account|Servizio di autenticazione'} ){Write-TestLog "AuditPolicy=$l" DATA};Write-TestLog 'Audit Kerberos/Account Logon ispezionato' PASS}catch{Write-TestLog "auditpol non leggibile: $($_.Exception.Message)" WARN}
$start=(Get-Date).AddHours(-1*$LookBackHours);$events=@()
try{
    $candidateEvents = Get-WinEvent -FilterHashtable @{LogName='Security';Id=4769;StartTime=$start} -ErrorAction SilentlyContinue
    if($acct.ServicePrincipalName){
        $spnPattern=($acct.ServicePrincipalName|ForEach-Object{[regex]::Escape($_)}) -join '|'
        $events=$candidateEvents | Where-Object {$_.Message -match $spnPattern -or $_.Message -match [regex]::Escape($TargetAccount)}
    } else {
        $events=$candidateEvents | Where-Object {$_.Message -match [regex]::Escape($TargetAccount)}
    }
}catch{Write-TestLog "Errore lettura eventi 4769: $($_.Exception.Message)" WARN}
$events=@($events|Sort-Object TimeCreated)
if($events.Count){Write-TestLog "Eventi TGS 4769 rilevati: $($events.Count)" PASS;foreach($e in $events){Write-TestLog "Event Time=$($e.TimeCreated.ToString('o')); Id=$($e.Id); Machine=$($e.MachineName)" DATA;$msg=($e.Message -replace "`r|`n",' ');if($msg.Length -gt 1200){$msg=$msg.Substring(0,1200)+'...'};Write-TestLog "EventMessage=$msg" DATA}}else{$msg="Nessun evento TGS 4769 correlato a $TargetAccount/SPN nelle ultime $LookBackHours ore";if($RequireEvents){Write-TestLog $msg FAIL}else{Write-TestLog $msg WARN}}
Finish-Test
