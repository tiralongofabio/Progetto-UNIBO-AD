[CmdletBinding()]
param(
    [string[]]$ExpectedDriveLetters = @('S:','H:','O:','G:'),
    [switch]$FailOnMissing = $true,
    [string]$OutputDir = '.\Esiti'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'
$TestId='Test-05.02'
$ResolvedOutputDir=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDir);if(!(Test-Path $ResolvedOutputDir)){New-Item -ItemType Directory -Path $ResolvedOutputDir -Force|Out-Null}
$OutFile=Join-Path $ResolvedOutputDir "$TestId.out";Set-Content $OutFile @("TestId=$TestId","Started=$(Get-Date -Format o)","Computer=$env:COMPUTERNAME","User=$env:USERDOMAIN\$env:USERNAME","---") -Encoding UTF8
$script:Failed=$false;$script:Warnings=0
function Write-TestLog{param([string]$Message,[ValidateSet('INFO','PASS','WARN','FAIL','DATA')][string]$Level='INFO')$line="{0} [{1}] {2}" -f (Get-Date -Format o),$Level,$Message;Add-Content $OutFile $line -Encoding UTF8;Write-Host $line;if($Level-eq'FAIL'){$script:Failed=$true};if($Level-eq'WARN'){$script:Warnings++}}
function Finish-Test{Add-Content $OutFile @("---","Warnings=$script:Warnings","Completed=$(Get-Date -Format o)","Result=$(if($script:Failed){'FAIL'}else{'PASS'})") -Encoding UTF8;if($script:Failed){exit 1}else{exit 0}}
try{Import-Module ActiveDirectory -ErrorAction Stop;Import-Module GroupPolicy -ErrorAction Stop}catch{Write-TestLog "Modulo mancante ActiveDirectory/GroupPolicy: $($_.Exception.Message)" FAIL;Finish-Test}
$found=@{};foreach($d in $ExpectedDriveLetters){$found[$d]=New-Object System.Collections.Generic.List[string]}
try{
 $domain=Get-ADDomain; $sysvol="\\$($domain.DNSRoot)\SYSVOL\$($domain.DNSRoot)\Policies"
 Write-TestLog "SYSVOL=$sysvol" DATA
 $driveXmlFiles=@(Get-ChildItem -Path $sysvol -Recurse -Filter Drives.xml -ErrorAction SilentlyContinue)
 if($driveXmlFiles.Count -eq 0){Write-TestLog "Nessun Drives.xml trovato in SYSVOL: le GPP Drive Maps probabilmente non sono state create" FAIL}
 foreach($file in $driveXmlFiles){
   Write-TestLog "DrivesXml=$($file.FullName)" DATA
   [xml]$xml=Get-Content $file.FullName -ErrorAction Stop
   $xml.SelectNodes('//*[local-name()="Drive"]') | ForEach-Object {
     $letter=$_.Properties.letter; $path=$_.Properties.path; $action=$_.Properties.action; $name=$_.Name
     Write-TestLog "DriveMap File=$($file.FullName); Name=$name; Letter=$letter; Path=$path; Action=$action" DATA
     if($letter){$key="$letter`:"; if($found.ContainsKey($key)){$found[$key].Add("$($file.FullName) -> $path")}}
   }
 }
 foreach($gpo in Get-GPO -All){
   try{$report=Get-GPOReport -Guid $gpo.Id -ReportType Xml; foreach($d in $ExpectedDriveLetters){if($report -match [regex]::Escape($d)){if($found[$d].Count -eq 0){$found[$d].Add("GPOReport:$($gpo.DisplayName)")}; Write-TestLog "Mapping $d rilevato in GPO report: $($gpo.DisplayName)" DATA}}}catch{}
 }
 foreach($d in $ExpectedDriveLetters){
   if($found[$d].Count -gt 0){Write-TestLog "Mapping atteso trovato: $d -> $($found[$d] -join ' | ')" PASS}
   else{if($FailOnMissing){Write-TestLog "Mapping atteso NON trovato: $d" FAIL}else{Write-TestLog "Mapping atteso NON trovato: $d" WARN}}
 }
 # Additional structural checks: if Departments/Shared/Governance strings are absent, fail broad mapping issue.
 $allXmlText = ($driveXmlFiles | ForEach-Object { Get-Content $_.FullName -Raw -ErrorAction SilentlyContinue }) -join "`n"
 foreach($needle in @('SRV-FS-001','Departments','Shared')){ if($allXmlText -match [regex]::Escape($needle)){Write-TestLog "Riferimento mapping presente in Drives.xml: $needle" PASS}else{Write-TestLog "Riferimento mapping mancante in Drives.xml: $needle" FAIL} }
}catch{Write-TestLog "Errore verifica drive mapping: $($_.Exception.Message)" FAIL}
Finish-Test
