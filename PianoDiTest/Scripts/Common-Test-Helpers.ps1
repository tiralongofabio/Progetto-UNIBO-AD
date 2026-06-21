Set-StrictMode -Version Latest

function New-TestContext {
  param([string]$TestId,[string]$OutputDir='.\Esiti')
  $od=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDir)
  if(!(Test-Path $od)){New-Item -ItemType Directory -Path $od -Force|Out-Null}
  $of=Join-Path $od "$TestId.out"
  Set-Content -Path $of -Encoding UTF8 -Value @("TestId=$TestId","Started=$(Get-Date -Format o)","Computer=$env:COMPUTERNAME","User=$env:USERDOMAIN\$env:USERNAME","---")
  [pscustomobject]@{TestId=$TestId;OutFile=$of;Failed=$false;Warnings=0}
}
function Write-TestLog { param($Ctx,[string]$Message,[ValidateSet('INFO','PASS','WARN','FAIL','DATA')][string]$Level='INFO')
  $line="{0} [{1}] {2}" -f (Get-Date -Format o),$Level,$Message
  Add-Content -Path $Ctx.OutFile -Encoding UTF8 -Value $line; Write-Host $line
  if($Level -eq 'FAIL'){$Ctx.Failed=$true}; if($Level -eq 'WARN'){$Ctx.Warnings++}
}
function Finish-Test { param($Ctx)
  Add-Content -Path $Ctx.OutFile -Encoding UTF8 -Value @('---',"Warnings=$($Ctx.Warnings)","Completed=$(Get-Date -Format o)","Result=$(if($Ctx.Failed){'FAIL'}else{'PASS'})")
  if($Ctx.Failed){exit 1}else{exit 0}
}
function Import-NeededModule { param($Ctx,[string]$Name,[switch]$Required)
  try{Import-Module $Name -ErrorAction Stop; Write-TestLog $Ctx "Modulo importato: $Name" PASS; return $true}
  catch{if($Required){Write-TestLog $Ctx "Modulo mancante: $Name - $($_.Exception.Message)" FAIL}else{Write-TestLog $Ctx "Modulo mancante: $Name" WARN}; return $false}
}
function Get-DomainOrFail { param($Ctx)
  if(!(Import-NeededModule $Ctx ActiveDirectory -Required)){return $null}
  try{$d=Get-ADDomain -ErrorAction Stop; Write-TestLog $Ctx "Dominio=$($d.DNSRoot) DN=$($d.DistinguishedName)" PASS; return $d}
  catch{Write-TestLog $Ctx "Get-ADDomain fallito: $($_.Exception.Message)" FAIL; return $null}
}
function Invoke-RemoteOrLocal { param($Ctx,[string]$ComputerName,[scriptblock]$ScriptBlock,[object[]]$ArgumentList=@())
  try{if($ComputerName -ieq $env:COMPUTERNAME -or $ComputerName.Split('.')[0] -ieq $env:COMPUTERNAME){& $ScriptBlock @ArgumentList}else{Invoke-Command -ComputerName $ComputerName -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList -ErrorAction Stop}}
  catch{Write-TestLog $Ctx "Errore remoto su $ComputerName : $($_.Exception.Message)" FAIL; return $null}
}
function Test-Tcp { param($Ctx,[string]$ComputerName,[int]$Port,[string]$Label='TCP')
  try{$r=Test-NetConnection -ComputerName $ComputerName -Port $Port -WarningAction SilentlyContinue; if($r.TcpTestSucceeded){Write-TestLog $Ctx "$Label ${ComputerName}:$Port raggiungibile" PASS}else{Write-TestLog $Ctx "$Label ${ComputerName}:$Port non raggiungibile" FAIL}}
  catch{Write-TestLog $Ctx "Test-NetConnection ${ComputerName}:$Port fallito: $($_.Exception.Message)" FAIL}
}
function Test-AccessPath { param($Ctx,[string]$Path,[pscredential]$Credential,[string]$Role)
  try{if($Credential){$n='T'+[guid]::NewGuid().ToString('N').Substring(0,5); New-PSDrive -Name $n -PSProvider FileSystem -Root $Path -Credential $Credential -ErrorAction Stop|Out-Null; Remove-PSDrive $n -Force; Write-TestLog $Ctx "$Role accesso riuscito: $Path" DATA}else{Write-TestLog $Ctx "$Role target=$Path" DATA}}
  catch{Write-TestLog $Ctx "$Role accesso fallito: $Path - $($_.Exception.Message)" DATA}
}

function Invoke-LabTest {
param(
  [Parameter(Mandatory=$true)][string]$TestId,
  [string]$OutputDir='.\Esiti',
  [string]$ExpectedDomain='ad-lab-domain.local',
  [string]$ExpectedDC='DC01',
  [string]$ComputerName,
  [string]$FileServer='SRV-FS-001',
  [string]$RootPath='D:\Shares',
  [pscredential]$TestCredential,
  [pscredential]$BoardCredential,
  [pscredential]$DirectorCredential,
  [pscredential]$UnauthorizedCredential,
  [string]$AdminUser='Administrator',
  [string]$TemporarySpn='SERVICE/lab-kerberoast-test',
  [switch]$SkipTgsRequest,
  [string]$HoneyUser='admin.backup',
  [string]$TargetServiceSpn='cifs/SRV-FS-001.ad-lab-domain.local',
  [int]$LookBackHours=24,
  [int]$LookBackMinutes=60,
  [switch]$PurgeKerberosCacheAtEnd
)
$ctx=New-TestContext $TestId $OutputDir
switch($TestId){
'Test-01.01' {
  $d=Get-DomainOrFail $ctx
  if($d){if($d.DNSRoot -ieq $ExpectedDomain){Write-TestLog $ctx 'Dominio atteso confermato' PASS}else{Write-TestLog $ctx "Dominio inatteso: $($d.DNSRoot)" FAIL}}
  try{$dc=Get-ADDomainController -Discover -DomainName $ExpectedDomain -ErrorAction Stop; Write-TestLog $ctx "DC discover=$($dc.HostName)" PASS}catch{Write-TestLog $ctx "DC discover fallito: $($_.Exception.Message)" FAIL}
  try{Resolve-DnsName $ExpectedDomain -ErrorAction Stop|Out-String|%{Write-TestLog $ctx $_ DATA}; Write-TestLog $ctx 'DNS dominio OK' PASS}catch{Write-TestLog $ctx "DNS fallito: $($_.Exception.Message)" FAIL}
  53,88,389,445|%{Test-Tcp $ctx $ExpectedDC $_ 'Servizio dominio'}
}
'Test-01.02' {
  $d=Get-DomainOrFail $ctx; if($d){$dn=$d.DistinguishedName}else{break}
  $ous=@("OU=LAB,$dn","OU=Departments,OU=LAB,$dn","OU=Governance,OU=LAB,$dn","OU=Admins,OU=LAB,$dn","OU=Groups,OU=LAB,$dn","OU=ServiceAccounts,OU=LAB,$dn","OU=Computers,OU=LAB,$dn","OU=Workstations,OU=Computers,OU=LAB,$dn","OU=Servers,OU=Computers,OU=LAB,$dn","OU=FileServers,OU=Servers,OU=Computers,OU=LAB,$dn","OU=AppServers,OU=Servers,OU=Computers,OU=LAB,$dn","OU=DBServers,OU=Servers,OU=Computers,OU=LAB,$dn","OU=Staging,OU=Computers,OU=LAB,$dn")
  foreach($ou in $ous){try{Get-ADOrganizationalUnit -Identity $ou -ErrorAction Stop|Out-Null; Write-TestLog $ctx "OU trovata: $ou" PASS}catch{Write-TestLog $ctx "OU mancante: $ou" FAIL}}
}
'Test-01.03' {
  Get-DomainOrFail $ctx|Out-Null
  $critical='GG_LAB_Admins','GG_LAB_BreakGlass','GG_LAB_ServiceAccounts','GG_Board_Members','GG_LAB_Directors'
  foreach($g in $critical){try{$x=Get-ADGroup $g -Properties GroupScope,GroupCategory,Members -ErrorAction Stop; Write-TestLog $ctx "Gruppo=$g Scope=$($x.GroupScope) Members=$(@($x.Members).Count)" PASS}catch{Write-TestLog $ctx "Gruppo critico mancante: $g" FAIL}}
  $gg=@(Get-ADGroup -LDAPFilter '(cn=GG_*)' -ErrorAction SilentlyContinue); $dl=@(Get-ADGroup -LDAPFilter '(cn=DL_*)' -ErrorAction SilentlyContinue)
  Write-TestLog $ctx "GG_*=$($gg.Count); DL_*=$($dl.Count)" DATA
  if($gg.Count -eq 0){Write-TestLog $ctx 'Nessun GG_*' FAIL}; if($dl.Count -eq 0){Write-TestLog $ctx 'Nessun DL_*' FAIL}
}
'Test-01.04' {
  Get-DomainOrFail $ctx|Out-Null
  foreach($u in 'super.user','admin.backup','svc.securityapp'){try{$x=Get-ADUser $u -Properties Enabled,MemberOf,ServicePrincipalName,DistinguishedName -ErrorAction Stop; Write-TestLog $ctx "User=$u Enabled=$($x.Enabled) DN=$($x.DistinguishedName) SPN=$(@($x.ServicePrincipalName).Count)" PASS; @($x.MemberOf)|%{Write-TestLog $ctx "  MemberOf=$_" DATA}}catch{Write-TestLog $ctx "Utente mancante: $u" FAIL}}
}
'Test-02.01' {
  Get-DomainOrFail $ctx|Out-Null
  $expected=@{'CLI01'='OU=Workstations,OU=Computers,OU=LAB';'SRV-FS-001'='OU=FileServers,OU=Servers,OU=Computers,OU=LAB';'DC01'='OU=Domain Controllers'}
  foreach($c in $expected.Keys){try{$x=Get-ADComputer $c -Properties DistinguishedName,Enabled -ErrorAction Stop; Write-TestLog $ctx "Computer=$c DN=$($x.DistinguishedName)" DATA; if($x.DistinguishedName -like "*$($expected[$c])*"){Write-TestLog $ctx "$c in OU attesa" PASS}else{Write-TestLog $ctx "$c fuori OU attesa" FAIL}}catch{Write-TestLog $ctx "Computer mancante: $c" FAIL}}
}
'Test-02.02' {
  $d=Get-DomainOrFail $ctx; Import-NeededModule $ctx GroupPolicy -Required|Out-Null; if(!$d){break}; $dn=$d.DistinguishedName
  $map=@{"OU=AppServers,OU=Servers,OU=Computers,OU=LAB,$dn"='GPO-LAB-AppServers-Firewall';"OU=DBServers,OU=Servers,OU=Computers,OU=LAB,$dn"='GPO-LAB-DBServers-Firewall';"OU=FileServers,OU=Servers,OU=Computers,OU=LAB,$dn"='GPO-LAB-FileServers-Firewall';"OU=Workstations,OU=Computers,OU=LAB,$dn"='GPO-LAB-Workstations-Firewall'}
  foreach($ou in $map.Keys){try{Get-ADOrganizationalUnit $ou -ErrorAction Stop|Out-Null; $links=@((Get-GPInheritance -Target $ou).GpoLinks|% DisplayName); Write-TestLog $ctx "OU=$ou Links=$($links -join ';')" DATA; if($links -contains $map[$ou]){Write-TestLog $ctx "Link presente: $($map[$ou])" PASS}else{Write-TestLog $ctx "Link mancante: $($map[$ou])" FAIL}}catch{Write-TestLog $ctx "Errore su $ou : $($_.Exception.Message)" FAIL}}
}
'Test-03.01' {
  Import-NeededModule $ctx GroupPolicy -Required|Out-Null
  $gpos='GPO-LAB-DomainControllers-Firewall','GPO-LAB-Workstations-Firewall','GPO-LAB-FileServers-Firewall','GPO-LAB-AppServers-Firewall','GPO-LAB-DBServers-Firewall','GPO-LAB-Staging-Firewall'
  foreach($g in $gpos){try{$x=Get-GPO -Name $g -ErrorAction Stop; Write-TestLog $ctx "GPO=$g Id=$($x.Id) Status=$($x.GpoStatus)" PASS}catch{Write-TestLog $ctx "GPO mancante: $g" FAIL}}
}
'Test-03.02' { if(!$ComputerName){$ComputerName='DC01'}; Test-FirewallResult $ctx $ComputerName @(53,88,389,445) }
'Test-03.03' { if(!$ComputerName){$ComputerName='SRV-FS-001'}; Test-FirewallResult $ctx $ComputerName @(445,5985) }
'Test-03.04' { if(!$ComputerName){$ComputerName='CLI01'}; Test-FirewallResult $ctx $ComputerName @() }
'Test-04.01' {
  $sb={Get-SmbShare|?{$_.Path -like 'D:\Shares*' -or $_.Name -match 'Departments|Governance|Shared'}|Select Name,Path,FolderEnumerationMode}
  $shares=@(Invoke-RemoteOrLocal $ctx $FileServer $sb); Write-TestLog $ctx "Share rilevate=$($shares.Count)" DATA
  foreach($s in $shares){Write-TestLog $ctx "Share=$($s.Name) Path=$($s.Path)" DATA}
  foreach($n in 'Departments','Governance','Shared'){if(@($shares|?{$_.Name -like "*$n*" -or $_.Path -like "*$n*"}).Count){Write-TestLog $ctx "$n presente" PASS}else{Write-TestLog $ctx "$n mancante" FAIL}}
}
'Test-04.02' {
  $sb={param($RootPath) if(!(Test-Path $RootPath)){return @([pscustomobject]@{MissingRoot=$true})}; $items=@($RootPath)+(Get-ChildItem $RootPath -Directory -Recurse -Depth 2 -ErrorAction SilentlyContinue|% FullName); foreach($i in $items){$acl=Get-Acl $i; foreach($a in $acl.Access){[pscustomobject]@{MissingRoot=$false;Path=$i;Identity=$a.IdentityReference.Value;Rights=$a.FileSystemRights;Type=$a.AccessControlType;Inherited=$a.IsInherited}}}}
  $aces=@(Invoke-RemoteOrLocal $ctx $FileServer $sb @($RootPath)); if($aces.Count -eq 0 -or $aces[0].MissingRoot){Write-TestLog $ctx "Root mancante: $RootPath" FAIL; break}
  foreach($a in $aces|Select -First 200){Write-TestLog $ctx "ACL $($a.Path) -> $($a.Identity) $($a.Rights)" DATA}
  $bad=@($aces|?{$_.Identity -notmatch '\\DL_' -and $_.Identity -notmatch 'BUILTIN|NT AUTHORITY|CREATOR OWNER|Domain Admins|Enterprise Admins|SYSTEM'})
  if($bad.Count -eq 0){Write-TestLog $ctx 'ACL coerenti con uso DL_* nel campione' PASS}else{Write-TestLog $ctx "ACE da revisionare=$($bad.Count)" WARN}
}
'Test-04.03' {
  if(!$TestCredential){Write-TestLog $ctx 'Nessuna TestCredential: test applicativo in modalità ricognizione' WARN}
  Test-AccessPath $ctx '\\SRV-FS-001\Departments' $TestCredential 'DepartmentUser'
  Test-AccessPath $ctx '\\SRV-FS-001\Shared' $TestCredential 'DepartmentUser'
  Test-AccessPath $ctx '\\SRV-FS-001\Governance' $TestCredential 'DepartmentUser'
}
'Test-04.04' {
  $targets='\\SRV-FS-001\Governance','\\SRV-FS-001\BoardOnly','\\SRV-FS-001\BoardDirectors'; $creds=@{Board=$BoardCredential;Director=$DirectorCredential;Unauthorized=$UnauthorizedCredential}
  foreach($role in $creds.Keys){if(!$creds[$role]){Write-TestLog $ctx "Credenziale $role non fornita" WARN; continue}; foreach($t in $targets){Test-AccessPath $ctx $t $creds[$role] $role}}
}
'Test-05.01' {
  Import-NeededModule $ctx GroupPolicy -Required|Out-Null
  $gpos=@(Get-GPO -All|?{$_.DisplayName -match 'User|Drive|Board|Governance|Admin|Break|Honey|Service|Baseline'})
  foreach($g in $gpos){Write-TestLog $ctx "GPO=$($g.DisplayName) Status=$($g.GpoStatus)" DATA}
  if($gpos.Count -ge 3){Write-TestLog $ctx 'GPO utente candidate presenti' PASS}else{Write-TestLog $ctx 'Poche GPO utente candidate rilevate' WARN}
}
'Test-05.02' {
  Import-NeededModule $ctx GroupPolicy -Required|Out-Null
  $found=@{}; foreach($d in 'S:','H:','O:','G:'){$found[$d]=$false}
  foreach($g in Get-GPO -All){try{$xml=Get-GPOReport -Guid $g.Id -ReportType Xml; foreach($drive in @($found.Keys)){if($xml -match [regex]::Escape($drive)){$found[$drive]=$true; Write-TestLog $ctx "Mapping $drive in GPO $($g.DisplayName)" PASS}}}catch{Write-TestLog $ctx "Report GPO fallito: $($g.DisplayName)" WARN}}
  foreach($drive in @($found.Keys)){if(!$found[$drive]){Write-TestLog $ctx "Mapping non trovato: $drive" WARN}}
}
'Test-05.03' {
  Import-NeededModule $ctx GroupPolicy -Required|Out-Null
  $group='GG_LAB_ServiceAccounts'; try{Get-ADGroup $group -ErrorAction Stop|Out-Null; Write-TestLog $ctx "Gruppo service account presente: $group" PASS}catch{Write-TestLog $ctx "Gruppo service account mancante" FAIL}
  $hits=0; foreach($g in Get-GPO -All){try{$xml=Get-GPOReport -Guid $g.Id -ReportType Xml; if($xml -match 'SeDenyInteractiveLogonRight|SeDenyRemoteInteractiveLogonRight' -or $xml -match [regex]::Escape($group)){$hits++; Write-TestLog $ctx "Possibile GPO deny logon: $($g.DisplayName)" DATA}}catch{}}
  if($hits){Write-TestLog $ctx 'Policy deny logon rilevata' PASS}else{Write-TestLog $ctx 'Policy deny logon non rilevata' FAIL}
}
'Test-05.04' {
  $members=@(Invoke-RemoteOrLocal $ctx $FileServer {Get-LocalGroupMember -Group 'Remote Desktop Users'|Select Name,ObjectClass,PrincipalSource})
  foreach($m in $members){Write-TestLog $ctx "RDP member=$($m.Name)" DATA}
  if(@($members|?{$_.Name -match 'DL_.*RDP|GG_.*Admin'}).Count){Write-TestLog $ctx 'Gruppo RDP amministrativo rilevato' PASS}else{Write-TestLog $ctx 'Gruppo RDP amministrativo non rilevato' FAIL}
}
'Test-06.01' {
  Get-DomainOrFail $ctx|Out-Null
  try{$u=Get-ADUser $HoneyUser -Properties Enabled,DistinguishedName,MemberOf -ErrorAction Stop; Write-TestLog $ctx "Honey=$HoneyUser Enabled=$($u.Enabled) DN=$($u.DistinguishedName)" PASS}catch{Write-TestLog $ctx "Honey-object mancante" FAIL}
  try{auditpol /get /category:* 2>$null|Select-String 'Logon|Account Logon|Directory Service'|%{Write-TestLog $ctx "Audit=$($_.Line)" DATA}; Write-TestLog $ctx 'Audit policy leggibile' PASS}catch{Write-TestLog $ctx 'auditpol non leggibile' WARN}
  try{$start=(Get-Date).AddHours(-1*$LookBackHours); $ev=@(Get-WinEvent -FilterHashtable @{LogName='Security';Id=4624,4625,4768,4769,4771;StartTime=$start} -ErrorAction SilentlyContinue|?{$_.Message -match [regex]::Escape($HoneyUser)}|Select -First 50); foreach($e in $ev){Write-TestLog $ctx "Event=$($e.Id) Time=$($e.TimeCreated)" DATA}; if($ev.Count){Write-TestLog $ctx 'Eventi honey rilevati' PASS}else{Write-TestLog $ctx 'Nessun evento honey nel periodo' WARN}}catch{Write-TestLog $ctx 'Security log non leggibile' WARN}
}
'Test-07.01' {
  Write-TestLog $ctx 'Kerberoasting exposure test: non esporta ticket, non effettua cracking, non scrive hash.' INFO
  Get-DomainOrFail $ctx|Out-Null
  try{$u=Get-ADUser $AdminUser -Properties ServicePrincipalName -ErrorAction Stop; $initial=@($u.ServicePrincipalName); $initial|%{Write-TestLog $ctx "SPN iniziale=$_" DATA}}catch{Write-TestLog $ctx "Admin target non trovato: $AdminUser" FAIL; break}
  $added=$false
  try{if($initial -contains $TemporarySpn){Write-TestLog $ctx 'SPN temporaneo già presente' WARN}else{Set-ADUser $AdminUser -ServicePrincipalNames @{Add=$TemporarySpn} -ErrorAction Stop; $added=$true; Write-TestLog $ctx "SPN temporaneo aggiunto: $TemporarySpn" PASS}
      if(!$SkipTgsRequest){try{Add-Type -AssemblyName System.IdentityModel -ErrorAction Stop; $t=New-Object System.IdentityModel.Tokens.KerberosRequestorSecurityToken -ArgumentList $TemporarySpn; Write-TestLog $ctx "TGS richiesto per SPN controllato; ValidTo=$($t.ValidTo)" PASS}catch{Write-TestLog $ctx "Richiesta TGS fallita: $($_.Exception.Message)" FAIL}; try{klist|Out-String|%{Write-TestLog $ctx $_ DATA}}catch{Write-TestLog $ctx 'klist non disponibile' WARN}}}
  finally{if($added){try{Set-ADUser $AdminUser -ServicePrincipalNames @{Remove=$TemporarySpn} -ErrorAction Stop; Write-TestLog $ctx 'Cleanup SPN completato' PASS}catch{Write-TestLog $ctx "Cleanup SPN fallito: $($_.Exception.Message)" FAIL}}}
}
'Test-07.02' {
  Write-TestLog $ctx 'Silver Ticket detection harness: non genera e non inietta ticket artefatti.' WARN
  $d=Get-DomainOrFail $ctx; if($d){Write-TestLog $ctx "DomainSID=$($d.DomainSID.Value)" DATA}
  try{Get-ADUser $HoneyUser -ErrorAction Stop|Out-Null; Write-TestLog $ctx "Honey-object presente: $HoneyUser" PASS}catch{Write-TestLog $ctx "Honey-object mancante: $HoneyUser" FAIL}
  try{klist|Out-String|%{Write-TestLog $ctx $_ DATA}}catch{Write-TestLog $ctx 'klist non disponibile' WARN}
  try{$start=(Get-Date).AddMinutes(-1*$LookBackMinutes); $ev=@(Get-WinEvent -FilterHashtable @{LogName='Security';Id=4624,4625,4769,4771;StartTime=$start} -ErrorAction SilentlyContinue|?{$_.Message -match [regex]::Escape($HoneyUser) -or $_.Message -match [regex]::Escape($TargetServiceSpn)}|Select -First 100); foreach($e in $ev){Write-TestLog $ctx "Event=$($e.Id) Time=$($e.TimeCreated)" DATA}; if($ev.Count){Write-TestLog $ctx 'Evidenze correlate rilevate' PASS}else{Write-TestLog $ctx 'Nessuna evidenza correlata nel periodo' WARN}}catch{Write-TestLog $ctx 'Security log non leggibile' WARN}
  if($PurgeKerberosCacheAtEnd){try{klist purge|Out-String|%{Write-TestLog $ctx $_ DATA}; Write-TestLog $ctx 'Cache Kerberos pulita' PASS}catch{Write-TestLog $ctx 'Purge Kerberos fallito' WARN}}
}
'Test-08.01' {
  $od=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDir); $files=Get-ChildItem $od -Filter 'Test-*.out' -ErrorAction SilentlyContinue|Sort Name
  $report=Join-Path $od 'Riepilogo-Test-LAB-AD.md'
  $md=@('# Riepilogo Test LAB Active Directory','',"Generato: $(Get-Date -Format o)",'','| Test | Esito | Warning | File |','|---|---:|---:|---|')
  foreach($f in $files){$c=Get-Content $f.FullName; $res=(($c|?{$_ -like 'Result=*'}|Select -Last 1) -replace '^Result=',''); $w=(($c|?{$_ -like 'Warnings=*'}|Select -Last 1) -replace '^Warnings=',''); $md += "| $($f.BaseName) | $res | $w | `$($f.FullName)` |"}
  Set-Content -Path $report -Encoding UTF8 -Value $md; Write-TestLog $ctx "Report generato: $report" PASS
}
default { Write-TestLog $ctx "TestId non riconosciuto: $TestId" FAIL }
}
Finish-Test $ctx
}

function Test-FirewallResult { param($Ctx,[string]$ComputerName,[int[]]$Ports)
  $sb={$profiles=Get-NetFirewallProfile|Select Name,Enabled,DefaultInboundAction,DefaultOutboundAction; $rules=Get-NetFirewallRule -Enabled True -Direction Inbound|Select -First 60 DisplayName,Action,Profile; [pscustomobject]@{Profiles=$profiles;Rules=$rules}}
  $r=Invoke-RemoteOrLocal $Ctx $ComputerName $sb
  if($r){foreach($p in $r.Profiles){Write-TestLog $Ctx "Profile=$($p.Name) Enabled=$($p.Enabled) In=$($p.DefaultInboundAction)" DATA; if($p.Enabled){Write-TestLog $Ctx "Firewall attivo: $($p.Name)" PASS}else{Write-TestLog $Ctx "Firewall disattivo: $($p.Name)" FAIL}}; foreach($rule in $r.Rules){Write-TestLog $Ctx "Rule=$($rule.DisplayName) Action=$($rule.Action) Profile=$($rule.Profile)" DATA}}
  foreach($p in $Ports){Test-Tcp $Ctx $ComputerName $p 'Porta attesa'}
}
