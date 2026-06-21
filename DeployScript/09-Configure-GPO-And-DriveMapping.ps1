$ErrorActionPreference="Stop"; $ScriptRoot="C:\LAB-AD\Scripts"; if(-not $Global:LabDN){& "$ScriptRoot\00-Init-LAB-Session.ps1"}; if(-not(Get-Command Ensure-GPOWithLink -ErrorAction SilentlyContinue)){. "$ScriptRoot\01-Load-LAB-Helpers.ps1"}
Ensure-GPOWithLink "GPO-LAB-DriveMapping" "OU=Departments,$LabDN" "Drive mapping departments"; Ensure-GPOWithLink "GPO-LAB-Governance-DriveMapping" "OU=Governance,$LabDN" "Drive mapping governance"
$sp="\\$DomainDNS\SYSVOL\$DomainDNS\scripts"; New-Item $sp -ItemType Directory -Force|Out-Null
@'
New-PSDrive -Name S -PSProvider FileSystem -Root "\\SRV-FS-001\Shared" -Persist -ErrorAction SilentlyContinue|Out-Null
'@|Set-Content "$sp\Map-LABDrives.ps1" -Encoding UTF8
@'
New-PSDrive -Name O -PSProvider FileSystem -Root "\\SRV-FS-001\Governance\Board\BoardOnly" -Persist -ErrorAction SilentlyContinue|Out-Null
New-PSDrive -Name G -PSProvider FileSystem -Root "\\SRV-FS-001\Governance\Board\BoardDirectors" -Persist -ErrorAction SilentlyContinue|Out-Null
'@|Set-Content "$sp\Map-LABGovernanceDrives.ps1" -Encoding UTF8
Set-GPRegistryValue -Name "GPO-LAB-DriveMapping" -Key "HKCU\Software\Microsoft\Windows\CurrentVersion\Run" -ValueName "LABDriveMapping" -Type String -Value "powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -File `"\\$DomainDNS\SYSVOL\$DomainDNS\scripts\Map-LABDrives.ps1`""
Set-GPRegistryValue -Name "GPO-LAB-Governance-DriveMapping" -Key "HKCU\Software\Microsoft\Windows\CurrentVersion\Run" -ValueName "LABGovernanceDriveMapping" -Type String -Value "powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -File `"\\$DomainDNS\SYSVOL\$DomainDNS\scripts\Map-LABGovernanceDrives.ps1`""
Write-Host "[OK] GPO and drive mapping configured" -ForegroundColor Green
