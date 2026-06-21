$ErrorActionPreference="Stop"; $ScriptRoot="C:\LAB-AD\Scripts"; if(-not $Global:LabDN){& "$ScriptRoot\00-Init-LAB-Session.ps1"}; if(-not(Get-Command Ensure-ADGroup -ErrorAction SilentlyContinue)){. "$ScriptRoot\01-Load-LAB-Helpers.ps1"}
$GDN="OU=Security,OU=Groups,$LabDN"
foreach($g in @("GG_LAB_AllUsers","GG_LAB_Directors","GG_LAB_Admins","GG_LAB_BreakGlass","GG_Board_Members","GG_SecurityApp","GG_LAB_HoneyObjects","GG_LAB_ServiceAccounts","GG_LAB_FileServers","GG_LAB_AppServers","GG_LAB_DBServers")){Ensure-ADGroup $g $GDN Global "LAB global group $g"}
foreach($d in $Departments){Ensure-ADGroup "GG_${d}_Users" $GDN Global "$d users"; Ensure-ADGroup "GG_${d}_Director" $GDN Global "$d director"}
foreach($g in @("DL_FS_Shared_RO","DL_FS_Shared_MD","DL_FS_Shared_FC","DL_FS_Governance_BoardOnly_MD","DL_FS_Governance_BoardOnly_FC","DL_FS_Governance_BoardDirectors_MD","DL_FS_Governance_BoardDirectors_FC","DL_RDP_SRV-FS-001_Admins","DL_RDP_SRV-APP-001_Admins","DL_RDP_SRV-DB-001_Admins")){Ensure-ADGroup $g $GDN DomainLocal "LAB DL group $g"}
foreach($d in $Departments){foreach($s in @("Public_WO","Public_RO","Public_MD","Public_FC","Internal_MD","Internal_FC","Confidential_MD","Confidential_FC")){Ensure-ADGroup "DL_FS_${d}_$s" $GDN DomainLocal "$d $s"}}
Write-Host "[OK] Groups complete" -ForegroundColor Green
