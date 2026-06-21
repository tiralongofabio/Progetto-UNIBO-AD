$ErrorActionPreference="Stop"; Import-Module ActiveDirectory; Import-Module GroupPolicy
$D=Get-ADDomain; $DomainDN=$D.DistinguishedName; $DomainDNS=$D.DNSRoot; $LabDN="OU=LAB,$DomainDN"; $GDN="OU=Security,OU=Groups,$LabDN"; $ComputersOU="OU=Computers,$LabDN"; $Group="GG_LAB_ServiceAccounts"; $GpoName="GPO-LAB-Deny-ServiceAccounts-InteractiveLogon"
if(-not(Get-ADGroup $Group -ErrorAction SilentlyContinue)){New-ADGroup -Name $Group -SamAccountName $Group -GroupCategory Security -GroupScope Global -Path $GDN -Description "All LAB service accounts"}
foreach($svc in @("svc.securityapp")){if(Get-ADUser $svc -ErrorAction SilentlyContinue){if(-not(Get-ADGroupMember $Group -Recursive|? SamAccountName -eq $svc)){Add-ADGroupMember $Group $svc}; if(Get-ADGroup GG_SecurityApp -ErrorAction SilentlyContinue){if(-not(Get-ADGroupMember GG_SecurityApp -Recursive|? SamAccountName -eq $svc)){Add-ADGroupMember GG_SecurityApp $svc}}; Set-ADUser $svc -AccountNotDelegated $true -Description "LAB service account - no interactive logon expected"}}
$Sid=(Get-ADGroup $Group).SID.Value; Write-Host "[OK] SID ${Group}: $Sid" -ForegroundColor Green
if(-not(Get-GPO -Name $GpoName -ErrorAction SilentlyContinue)){New-GPO -Name $GpoName -Comment "Deny interactive/RDP logon to service accounts"|Out-Null}; if(-not((Get-GPInheritance $ComputersOU).GpoLinks|? DisplayName -eq $GpoName)){New-GPLink -Name $GpoName -Target $ComputersOU -LinkEnabled Yes|Out-Null}
$Gpo=Get-GPO $GpoName; $Guid=$Gpo.Id.ToString('B').ToUpper(); $Path="\\$DomainDNS\SYSVOL\$DomainDNS\Policies\$Guid"; $Sec="$Path\Machine\Microsoft\Windows NT\SecEdit"; New-Item $Sec -ItemType Directory -Force|Out-Null
@"
[Unicode]
Unicode=yes
[Version]
signature="`$CHICAGO`$"
Revision=1
[Privilege Rights]
SeDenyInteractiveLogonRight = *$Sid
SeDenyRemoteInteractiveLogonRight = *$Sid
"@|Set-Content "$Sec\GptTmpl.inf" -Encoding Unicode
$ad="CN=$Guid,CN=Policies,CN=System,$DomainDN"; $ext="[{827D319E-6EAC-11D2-A4EA-00C04F79F83A}{803E14A0-B4FB-11D0-A0D0-00A0C90F574B}]"; $obj=Get-ADObject $ad -Properties gPCMachineExtensionNames; if(([string]$obj.gPCMachineExtensionNames) -notlike "*827D319E-6EAC-11D2-A4EA-00C04F79F83A*"){Set-ADObject $ad -Replace @{gPCMachineExtensionNames=(([string]$obj.gPCMachineExtensionNames)+$ext)}}
$ini="$Path\gpt.ini"; if(-not(Test-Path $ini)){"[General]`nVersion=65536"|Set-Content $ini -Encoding ASCII}else{$c=Get-Content $ini; $v=($c|?{$_ -match '^Version='}|select -First 1) -replace '^Version=',''; if(-not $v){$v=0}; $nv=(([int]$v)+65536); ($c|%{if($_ -match '^Version='){"Version=$nv"}else{$_}})|Set-Content $ini -Encoding ASCII}
Write-Host "[OK] Service account deny logon GPO complete" -ForegroundColor Green
