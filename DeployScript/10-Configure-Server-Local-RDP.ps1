$ErrorActionPreference="Stop"; $ScriptRoot="C:\LAB-AD\Scripts"; if(-not $Global:NetBIOS){& "$ScriptRoot\00-Init-LAB-Session.ps1"}
Invoke-Command -ComputerName SRV-FS-001 -ArgumentList $NetBIOS -ScriptBlock {param($n); Add-LocalGroupMember -Group "Remote Desktop Users" -Member "$n\DL_RDP_SRV-FS-001_Admins" -ErrorAction SilentlyContinue}
# Future SRV-APP-001 / SRV-DB-001 blocks intentionally commented until machines exist.
Write-Host "[OK] Local RDP configured" -ForegroundColor Green
