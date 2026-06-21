# LAB Active Directory - 00-Init-LAB-Session.ps1
$ErrorActionPreference = "Stop"
Import-Module ActiveDirectory -ErrorAction Stop
Import-Module GroupPolicy -ErrorAction Stop
$Global:LABRoot="C:\LAB-AD"; $Global:ScriptRoot="$LABRoot\Scripts"; $Global:LogRoot="$LABRoot\Logs"
New-Item $LABRoot,$ScriptRoot,$LogRoot,"C:\Temp" -ItemType Directory -Force | Out-Null
$Global:Domain=Get-ADDomain
$Global:DomainDN=$Domain.DistinguishedName; $Global:DomainDNS=$Domain.DNSRoot; $Global:NetBIOS=$Domain.NetBIOSName
$Global:LabOUName="LAB"; $Global:LabDN="OU=$LabOUName,$DomainDN"
$Global:Departments=@("IT","Finance","HR","Marketing","Sales")
$Global:FileServerName="SRV-FS-001"; $Global:AppServerNames=@("SRV-APP-001"); $Global:DbServerNames=@("SRV-DB-001")
$Global:ShareRoot="D:\Shares"; $Global:DeptRoot="$ShareRoot\Departments"; $Global:GovernanceRoot="$ShareRoot\Governance"; $Global:SharedRoot="$ShareRoot\Shared"
$Global:BoardRoot="$GovernanceRoot\Board"; $Global:BoardOnlyPath="$BoardRoot\BoardOnly"; $Global:BoardDirPath="$BoardRoot\BoardDirectors"
$Global:DefaultUserPassword=ConvertTo-SecureString "P@ssw0rd-LAB-ChangeMe!2026" -AsPlainText -Force
$Global:AdminPassword=ConvertTo-SecureString "Adm1n-LAB-ChangeMe!2026" -AsPlainText -Force
$Global:BreakGlassPassword=ConvertTo-SecureString "BreakGlass-LAB-ChangeMe!2026" -AsPlainText -Force
$Global:HoneyPassword=ConvertTo-SecureString "Honey-LAB-ChangeMe!2026" -AsPlainText -Force
$Global:ServicePassword=ConvertTo-SecureString "Svc-LAB-ChangeMe!2026" -AsPlainText -Force
Write-Host "[OK] LAB session initialized for $DomainDNS" -ForegroundColor Green
