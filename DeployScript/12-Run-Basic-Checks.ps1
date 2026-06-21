$ErrorActionPreference="Continue"; $ScriptRoot="C:\LAB-AD\Scripts"; if(-not $Global:LabDN){& "$ScriptRoot\00-Init-LAB-Session.ps1"}; Import-Module ActiveDirectory; Import-Module GroupPolicy
Get-ADDomain; Get-ADDomainController; Resolve-DnsName $DomainDNS
Get-ADOrganizationalUnit -SearchBase $LabDN -Filter *|Select Name,DistinguishedName|Sort DistinguishedName|ft -Auto
Get-ADGroup -SearchBase "OU=Security,OU=Groups,$LabDN" -Filter *|Select Name,GroupScope|Sort Name|ft -Auto
Get-ADUser -SearchBase $LabDN -Filter * -Properties Description|Select SamAccountName,Enabled,Description|Sort SamAccountName|ft -Auto
Test-WSMan SRV-FS-001; Test-NetConnection SRV-FS-001 -Port 445; Invoke-Command -ComputerName SRV-FS-001 -ScriptBlock {Get-SmbShare -Name Departments,Governance,Shared; Test-Path D:\Shares}
Get-GPO -All|? DisplayName -like 'GPO-LAB-*'|Select DisplayName|Sort DisplayName|ft -Auto
