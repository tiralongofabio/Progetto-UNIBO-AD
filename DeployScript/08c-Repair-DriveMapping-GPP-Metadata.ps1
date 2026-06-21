# ============================================================
# LAB Active Directory - 08c-Repair-DriveMapping-GPP-Metadata.ps1
#
# Scopo:
# - Ripara i metadati della GPO Drive Mapping creata manualmente via Drives.xml.
# - Allinea versione AD e versione SYSVOL della GPO.
# - Assicura gPCUserExtensionNames per Group Policy Preferences Drive Maps.
# - Verifica la presenza di Drives.xml.
#
# Quando usarlo:
# - 08b ha creato correttamente Drives.xml ma i mapping S:/H:/O:/G: non appaiono
#   sugli utenti dopo gpupdate/logout/login.
#
# Da eseguire su DC01 come Domain Admin.
# ============================================================

$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "=== 08c - Repair Drive Mapping GPP Metadata ===" -ForegroundColor Cyan
Write-Host ""

Import-Module ActiveDirectory -ErrorAction Stop
Import-Module GroupPolicy -ErrorAction Stop

$Domain    = Get-ADDomain
$DomainDN  = $Domain.DistinguishedName
$DomainDNS = $Domain.DNSRoot

$GpoName = "GPO-LAB-DriveMapping-GPP"

$Gpo = Get-GPO -Name $GpoName -ErrorAction Stop
$GpoGuid = $Gpo.Id
$GpoGuidString = $GpoGuid.ToString("B").ToUpper()

$GpoAdPath = "CN=$GpoGuidString,CN=Policies,CN=System,$DomainDN"
$GpoSysvolPath = "\\$DomainDNS\SYSVOL\$DomainDNS\Policies\$GpoGuidString"
$GptIniPath = Join-Path $GpoSysvolPath "gpt.ini"
$DrivesXmlPath = Join-Path $GpoSysvolPath "User\Preferences\Drives\Drives.xml"

if (-not (Test-Path $DrivesXmlPath)) {
    throw "Drives.xml non trovato: $DrivesXmlPath. Riesegui prima 08b."
}

Write-Host "[OK] Drives.xml trovato: $DrivesXmlPath" -ForegroundColor Green

# ------------------------------------------------------------
# 1. Assicura Client Side Extension per Drive Maps
# ------------------------------------------------------------
# Drive Maps CSE GUID: 5794DAFD-BE60-433F-88A2-1A31939AC01F
# Tool/Preferences GUID usato dal set GPP: F3CCC681-B74C-4060-9F26-CD84525DCA2A
$DriveMapsCsePair = "[{5794DAFD-BE60-433F-88A2-1A31939AC01F}{F3CCC681-B74C-4060-9F26-CD84525DCA2A}]"

$GpoAdObject = Get-ADObject -Identity $GpoAdPath -Properties gPCUserExtensionNames, versionNumber
$CurrentExtensions = [string]$GpoAdObject.gPCUserExtensionNames

if ([string]::IsNullOrWhiteSpace($CurrentExtensions)) {
    Set-ADObject -Identity $GpoAdPath -Replace @{ gPCUserExtensionNames = $DriveMapsCsePair }
    Write-Host "[OK] gPCUserExtensionNames impostato per Drive Maps." -ForegroundColor Green
}
elseif ($CurrentExtensions -notlike "*5794DAFD-BE60-433F-88A2-1A31939AC01F*") {
    Set-ADObject -Identity $GpoAdPath -Replace @{ gPCUserExtensionNames = ($CurrentExtensions + $DriveMapsCsePair) }
    Write-Host "[OK] Drive Maps CSE aggiunta a gPCUserExtensionNames." -ForegroundColor Green
}
else {
    Write-Host "[SKIP] Drive Maps CSE già presente in gPCUserExtensionNames." -ForegroundColor Yellow
}

# ------------------------------------------------------------
# 2. Allinea versionNumber AD e gpt.ini SYSVOL
# ------------------------------------------------------------
$GpoAdObject = Get-ADObject -Identity $GpoAdPath -Properties versionNumber
$CurrentAdVersion = [int]$GpoAdObject.versionNumber

$ComputerVersion = ($CurrentAdVersion -shr 16) -band 0xFFFF
$UserVersion = $CurrentAdVersion -band 0xFFFF
$UserVersion++
$NewVersion = ($ComputerVersion -shl 16) -bor $UserVersion

Set-ADObject -Identity $GpoAdPath -Replace @{ versionNumber = $NewVersion }
Write-Host "[OK] versionNumber AD aggiornato: $CurrentAdVersion -> $NewVersion" -ForegroundColor Green

if (-not (Test-Path $GptIniPath)) {
    @"
[General]
Version=$NewVersion
"@ | Set-Content -Path $GptIniPath -Encoding ASCII
    Write-Host "[OK] gpt.ini creato con Version=$NewVersion" -ForegroundColor Green
}
else {
    $GptContent = Get-Content -Path $GptIniPath -ErrorAction Stop
    if ($GptContent -match '^Version=') {
        $NewGptContent = $GptContent | ForEach-Object {
            if ($_ -match '^Version=') { "Version=$NewVersion" } else { $_ }
        }
        Set-Content -Path $GptIniPath -Value $NewGptContent -Encoding ASCII
    }
    else {
        Add-Content -Path $GptIniPath -Value "Version=$NewVersion"
    }
    Write-Host "[OK] gpt.ini allineato a Version=$NewVersion" -ForegroundColor Green
}

# ------------------------------------------------------------
# 3. Riepilogo
# ------------------------------------------------------------
$GpoAfter = Get-GPO -Name $GpoName
$AdAfter = Get-ADObject -Identity $GpoAdPath -Properties versionNumber, gPCUserExtensionNames

Write-Host ""
Write-Host "=== Riepilogo ===" -ForegroundColor Cyan
Write-Host "GPO: $GpoName"
Write-Host "GUID: $GpoGuidString"
Write-Host "Drives.xml: $DrivesXmlPath"
Write-Host "AD versionNumber: $($AdAfter.versionNumber)"
Write-Host "gPCUserExtensionNames: $($AdAfter.gPCUserExtensionNames)"
Write-Host ""
Write-Host "[OK] 08c completato." -ForegroundColor Green
Write-Host ""
Write-Host "Prossimi step:" -ForegroundColor Cyan
Write-Host "1. Su CLI01: gpupdate /target:user /force"
Write-Host "2. Logout/login dell'utente hr.user02"
Write-Host "3. Verifica S: e H: in Questo PC"
