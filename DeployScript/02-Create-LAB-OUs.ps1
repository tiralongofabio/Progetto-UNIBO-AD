$ErrorActionPreference="Stop"; $ScriptRoot="C:\LAB-AD\Scripts"; if(-not $Global:LabDN){& "$ScriptRoot\00-Init-LAB-Session.ps1"}; if(-not(Get-Command Ensure-ADOU -ErrorAction SilentlyContinue)){. "$ScriptRoot\01-Load-LAB-Helpers.ps1"}
Ensure-ADOU "LAB" $DomainDN "LAB root OU"
foreach($ou in @("Departments","Governance","Admins","Groups","ServiceAccounts","Computers")){Ensure-ADOU $ou $LabDN "LAB $ou"}
foreach($d in $Departments){Ensure-ADOU $d "OU=Departments,$LabDN" "Department $d"}
Ensure-ADOU "Board" "OU=Governance,$LabDN" "Board users"
foreach($ou in @("IT-Admins","Break-Glass","Honey-Objects")){Ensure-ADOU $ou "OU=Admins,$LabDN" "Admin area $ou"}
foreach($ou in @("Security","Distribution")){Ensure-ADOU $ou "OU=Groups,$LabDN" "Group area $ou"}
foreach($ou in @("UserManagedServiceAccounts","gMSA","SecurityApp")){Ensure-ADOU $ou "OU=ServiceAccounts,$LabDN" "Service area $ou"}
foreach($ou in @("Staging","Workstations","Servers")){Ensure-ADOU $ou "OU=Computers,$LabDN" "Computer area $ou"}
foreach($ou in @("FileServers","AppServers","DBServers")){Ensure-ADOU $ou "OU=Servers,OU=Computers,$LabDN" "Server class $ou"}
Write-Host "[OK] OU structure complete" -ForegroundColor Green
