$ErrorActionPreference="Stop"; $ScriptRoot="C:\LAB-AD\Scripts"; if(-not $Global:LabDN){& "$ScriptRoot\00-Init-LAB-Session.ps1"}; Import-Module ActiveDirectory
function Move-C($n,$ou){$c=Get-ADComputer $n -ErrorAction SilentlyContinue; if($c -and $c.DistinguishedName -notlike "*$ou") {Move-ADObject $c.DistinguishedName -TargetPath $ou; Write-Host "[OK] $n -> $ou" -ForegroundColor Green}elseif($c){Write-Host "[SKIP] $n" -ForegroundColor Yellow}else{Write-Warning "$n not found"}}
Move-C "CLI01" "OU=Workstations,OU=Computers,$LabDN"; Move-C "SRV-FS-001" "OU=FileServers,OU=Servers,OU=Computers,$LabDN"
# Future: Move-C "SRV-APP-001" "OU=AppServers,OU=Servers,OU=Computers,$LabDN"
# Future: Move-C "SRV-DB-001" "OU=DBServers,OU=Servers,OU=Computers,$LabDN"
