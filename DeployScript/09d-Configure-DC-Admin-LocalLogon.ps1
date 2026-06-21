# ============================================================
# LAB Active Directory - 09d-Configure-DC-Admin-LocalLogon.ps1
#
# Scopo:
# - Rendere gli account admin.* del laboratorio Domain Admins.
# - Consentire agli utenti admin separati di accedere localmente e via RDP
#   a tutti i Domain Controller presenti e futuri.
# - Applicare i diritti di logon tramite GPO linkata a OU=Domain Controllers.
#
# ATTENZIONE:
# - Questo script aggiunge GG_LAB_Admins al gruppo Domain Admins.
# - Tutti gli utenti admin.it.* membri di GG_LAB_Admins diventano quindi
#   amministratori del dominio.
# - Usare solo in ambiente LAB/demo.
#
# Cosa configura:
# - Membership admin.it.* -> GG_LAB_Admins
# - Membership GG_LAB_Admins -> Domain Admins
# - SeInteractiveLogonRight sui DC
# - SeRemoteInteractiveLogonRight sui DC
# - RDP/NLA abilitato sul DC corrente
#
# Cosa NON modifica:
# - Non tocca i deny-logon dei service account.
# - Non modifica le policy firewall: quelle restano gestite dagli script 07/07b.
#
# Da eseguire su DC01 come Domain Admin.
# Idempotente / rieseguibile.
# ============================================================

$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "=== 09d - DC Admin Domain Admins + Local/RDP Logon Rights ===" -ForegroundColor Cyan
Write-Host ""

# ------------------------------------------------------------
# 0. Moduli e variabili base
# ------------------------------------------------------------
Import-Module ActiveDirectory -ErrorAction Stop
Import-Module GroupPolicy -ErrorAction Stop

$Domain    = Get-ADDomain
$DomainDN  = $Domain.DistinguishedName
$DomainDNS = $Domain.DNSRoot
$NetBIOS   = $Domain.NetBIOSName

$LabDN = "OU=LAB,$DomainDN"
$GroupsSecurityDN = "OU=Security,OU=Groups,$LabDN"
$DomainControllersOU = "OU=Domain Controllers,$DomainDN"

$GpoName = "GPO-LAB-DC-Admin-Logon-Rights"
$LabAdminsGroup = "GG_LAB_Admins"

# Account admin separati attesi nel lab.
$LabAdminAccounts = @(
    "admin.it.user01",
    "admin.it.user02",
    "admin.it.user03",
    "admin.it.user04"
)

# Gruppi che devono poter effettuare logon locale/RDP sui DC.
# Poiché GG_LAB_Admins viene aggiunto a Domain Admins, Domain Admins sarebbe già sufficiente.
# Manteniamo comunque GG_LAB_Admins esplicito per chiarezza e audit del lab.
$AllowedLogonPrincipals = @(
    "$NetBIOS\$LabAdminsGroup",
    "$NetBIOS\Domain Admins",
    "$NetBIOS\Enterprise Admins",
    "BUILTIN\Administrators"
)

# ------------------------------------------------------------
# 1. Helper
# ------------------------------------------------------------
function Assert-ADOUExists {
    param([Parameter(Mandatory)] [string] $DistinguishedName)

    if (-not (Get-ADOrganizationalUnit -Identity $DistinguishedName -ErrorAction SilentlyContinue)) {
        throw "OU mancante: $DistinguishedName"
    }
}

function Ensure-ADGroupLocal {
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [ValidateSet("Global", "DomainLocal", "Universal")] [string] $Scope,
        [string] $Description = "LAB security group"
    )

    $Existing = Get-ADGroup -LDAPFilter "(sAMAccountName=$Name)" -ErrorAction SilentlyContinue

    if (-not $Existing) {
        New-ADGroup `
            -Name $Name `
            -SamAccountName $Name `
            -GroupCategory Security `
            -GroupScope $Scope `
            -Path $Path `
            -Description $Description
        Write-Host "[OK] Gruppo creato: $Name" -ForegroundColor Green
    }
    else {
        Write-Host "[SKIP] Gruppo già presente: $Name" -ForegroundColor Yellow
    }
}

function Ensure-ADGroupMemberLocal {
    param(
        [Parameter(Mandatory)] [string] $Group,
        [Parameter(Mandatory)] [string[]] $Members
    )

    foreach ($Member in $Members) {
        $Obj = Get-ADObject -LDAPFilter "(|(sAMAccountName=$Member)(name=$Member))" -ErrorAction SilentlyContinue
        if (-not $Obj) {
            Write-Warning "Oggetto non trovato, membership saltata: $Member -> $Group"
            continue
        }

        $ExistingMember = Get-ADGroupMember -Identity $Group -Recursive -ErrorAction Stop | Where-Object {
            $_.DistinguishedName -eq $Obj.DistinguishedName
        }

        if (-not $ExistingMember) {
            Add-ADGroupMember -Identity $Group -Members $Obj.DistinguishedName
            Write-Host "[OK] Aggiunto $Member a $Group" -ForegroundColor Green
        }
        else {
            Write-Host "[SKIP] $Member già membro di $Group" -ForegroundColor Yellow
        }
    }
}

function Ensure-GPOWithLinkLocal {
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [string] $TargetDN,
        [string] $Comment = "LAB GPO"
    )

    $Gpo = Get-GPO -Name $Name -ErrorAction SilentlyContinue

    if (-not $Gpo) {
        $Gpo = New-GPO -Name $Name -Comment $Comment
        Write-Host "[OK] GPO creata: $Name" -ForegroundColor Green
    }
    else {
        Write-Host "[SKIP] GPO già presente: $Name" -ForegroundColor Yellow
    }

    $Inheritance = Get-GPInheritance -Target $TargetDN
    $ExistingLink = $Inheritance.GpoLinks | Where-Object { $_.DisplayName -eq $Name }

    if (-not $ExistingLink) {
        New-GPLink -Name $Name -Target $TargetDN -LinkEnabled Yes | Out-Null
        Write-Host "[OK] Link GPO: $Name -> $TargetDN" -ForegroundColor Green
    }
    else {
        Set-GPLink -Name $Name -Target $TargetDN -LinkEnabled Yes | Out-Null
        Write-Host "[SKIP/UPDATE] Link già presente: $Name -> $TargetDN" -ForegroundColor Yellow
    }

    return Get-GPO -Name $Name
}

function Resolve-PrincipalToSidToken {
    param([Parameter(Mandatory)] [string] $Principal)

    try {
        $NtAccount = New-Object System.Security.Principal.NTAccount($Principal)
        $Sid = $NtAccount.Translate([System.Security.Principal.SecurityIdentifier])
        return "*$($Sid.Value)"
    }
    catch {
        throw "Impossibile risolvere SID per '$Principal'. Dettaglio: $_"
    }
}

function Set-GpoSecurityCseExtension {
    param(
        [Parameter(Mandatory)] [Guid] $GpoGuid,
        [Parameter(Mandatory)] [string] $DomainDN
    )

    $SecurityExtension = "[{827D319E-6EAC-11D2-A4EA-00C04F79F83A}{803E14A0-B4FB-11D0-A0D0-00A0C90F574B}]"
    $GpoGuidString = $GpoGuid.ToString("B").ToUpper()
    $GpoAdPath = "CN=$GpoGuidString,CN=Policies,CN=System,$DomainDN"

    $GpoAdObject = Get-ADObject -Identity $GpoAdPath -Properties gPCMachineExtensionNames
    $Current = [string]$GpoAdObject.gPCMachineExtensionNames

    if ([string]::IsNullOrWhiteSpace($Current)) {
        Set-ADObject -Identity $GpoAdPath -Replace @{ gPCMachineExtensionNames = $SecurityExtension }
        Write-Host "[OK] gPCMachineExtensionNames impostato per Security Settings." -ForegroundColor Green
    }
    elseif ($Current -notlike "*827D319E-6EAC-11D2-A4EA-00C04F79F83A*") {
        Set-ADObject -Identity $GpoAdPath -Replace @{ gPCMachineExtensionNames = ($Current + $SecurityExtension) }
        Write-Host "[OK] Security Settings CSE aggiunta a gPCMachineExtensionNames." -ForegroundColor Green
    }
    else {
        Write-Host "[SKIP] Security Settings CSE già presente in gPCMachineExtensionNames." -ForegroundColor Yellow
    }
}

function Update-GptIniMachineVersion {
    param([Parameter(Mandatory)] [string] $GptIniPath)

    if (-not (Test-Path $GptIniPath)) {
        @"
[General]
Version=0
"@ | Set-Content -Path $GptIniPath -Encoding ASCII
    }

    $Content = Get-Content -Path $GptIniPath -ErrorAction Stop
    $VersionLine = $Content | Where-Object { $_ -match '^Version=' } | Select-Object -First 1

    if (-not $VersionLine) {
        Add-Content -Path $GptIniPath -Value "Version=65536"
        Write-Host "[OK] gpt.ini inizializzato con machine version." -ForegroundColor Green
        return
    }

    $Version = [int]($VersionLine -replace '^Version=', '')

    # Version è un DWORD: high word = Computer, low word = User.
    $UserVersion = $Version -band 0x0000FFFF
    $ComputerVersion = ($Version -shr 16) -band 0x0000FFFF
    $ComputerVersion++
    $NewVersion = ($ComputerVersion -shl 16) -bor $UserVersion

    $NewContent = $Content | ForEach-Object {
        if ($_ -match '^Version=') { "Version=$NewVersion" } else { $_ }
    }

    Set-Content -Path $GptIniPath -Value $NewContent -Encoding ASCII
    Write-Host "[OK] gpt.ini aggiornato: ComputerVersion=$ComputerVersion, UserVersion=$UserVersion" -ForegroundColor Green
}

function Set-DCAdminLogonRightsInGptTmpl {
    param(
        [Parameter(Mandatory)] [string] $GptTmplPath,
        [Parameter(Mandatory)] [string[]] $SidTokens
    )

    $SecEditDir = Split-Path $GptTmplPath
    New-Item -Path $SecEditDir -ItemType Directory -Force | Out-Null

    $Value = ($SidTokens | Sort-Object -Unique) -join ","

    $Template = @"
[Unicode]
Unicode=yes
[Version]
signature="`$CHICAGO`$"
Revision=1
[Privilege Rights]
SeInteractiveLogonRight = $Value
SeRemoteInteractiveLogonRight = $Value
"@

    Set-Content -Path $GptTmplPath -Value $Template -Encoding Unicode
    Write-Host "[OK] GptTmpl.inf scritto: $GptTmplPath" -ForegroundColor Green
}

# ------------------------------------------------------------
# 2. Verifiche preliminari
# ------------------------------------------------------------
Assert-ADOUExists -DistinguishedName $GroupsSecurityDN
Assert-ADOUExists -DistinguishedName $DomainControllersOU

# ------------------------------------------------------------
# 3. Gruppo admin, membership e Domain Admins
# ------------------------------------------------------------
Ensure-ADGroupLocal `
    -Name $LabAdminsGroup `
    -Path $GroupsSecurityDN `
    -Scope Global `
    -Description "LAB separated admin accounts - members are Domain Admins in this lab"

Ensure-ADGroupMemberLocal -Group $LabAdminsGroup -Members $LabAdminAccounts

# Richiesto: tutti gli utenti admin.* devono essere Domain Admins.
# Per mantenere il modello più pulito, aggiungiamo GG_LAB_Admins a Domain Admins.
# Poiché gli admin.it.* sono membri di GG_LAB_Admins, diventano Domain Admins.
Ensure-ADGroupMemberLocal -Group "Domain Admins" -Members @($LabAdminsGroup)

# ------------------------------------------------------------
# 4. GPO per logon locale/RDP sui DC
# ------------------------------------------------------------
$Gpo = Ensure-GPOWithLinkLocal `
    -Name $GpoName `
    -TargetDN $DomainControllersOU `
    -Comment "Allow LAB admin accounts to log on locally and through RDP on all Domain Controllers"

$SidTokens = foreach ($Principal in $AllowedLogonPrincipals) {
    Resolve-PrincipalToSidToken -Principal $Principal
}

Write-Host ""
Write-Host "Principali autorizzati al logon su DC:" -ForegroundColor Cyan
$AllowedLogonPrincipals | ForEach-Object { Write-Host "  - $_" }

$GpoGuid = $Gpo.Id
$GpoGuidString = $GpoGuid.ToString("B").ToUpper()
$GpoSysvolPath = "\\$DomainDNS\SYSVOL\$DomainDNS\Policies\$GpoGuidString"
$GptTmplPath = Join-Path $GpoSysvolPath "Machine\Microsoft\Windows NT\SecEdit\GptTmpl.inf"
$GptIniPath = Join-Path $GpoSysvolPath "gpt.ini"

Set-DCAdminLogonRightsInGptTmpl -GptTmplPath $GptTmplPath -SidTokens $SidTokens
Set-GpoSecurityCseExtension -GpoGuid $GpoGuid -DomainDN $DomainDN
Update-GptIniMachineVersion -GptIniPath $GptIniPath

# ------------------------------------------------------------
# 5. Abilitazione RDP/NLA sul DC corrente
# ------------------------------------------------------------
try {
    Set-ItemProperty `
        -Path "HKLM:\System\CurrentControlSet\Control\Terminal Server" `
        -Name "fDenyTSConnections" `
        -Value 0

    Set-ItemProperty `
        -Path "HKLM:\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" `
        -Name "UserAuthentication" `
        -Value 1

    Set-Service -Name TermService -StartupType Automatic
    Start-Service -Name TermService -ErrorAction SilentlyContinue

    Write-Host "[OK] RDP/NLA abilitato sul DC corrente." -ForegroundColor Green
}
catch {
    Write-Warning "Non sono riuscito ad abilitare RDP sul DC corrente. Dettaglio: $_"
}

# ------------------------------------------------------------
# 6. Riepilogo
# ------------------------------------------------------------
Write-Host ""
Write-Host "=== Riepilogo 09d ===" -ForegroundColor Cyan
Write-Host "GPO: $GpoName"
Write-Host "Link target: $DomainControllersOU"
Write-Host "Gruppo admin lab: $LabAdminsGroup"
Write-Host "Membership privilegiata: GG_LAB_Admins -> Domain Admins"
Write-Host "Diritti impostati:"
Write-Host "  - SeInteractiveLogonRight"
Write-Host "  - SeRemoteInteractiveLogonRight"
Write-Host ""
Write-Host "[OK] 09d completato." -ForegroundColor Green
Write-Host ""
Write-Host "Prossimi step consigliati:" -ForegroundColor Cyan
Write-Host "1. Esegui gpupdate /force su DC01."
Write-Host "2. Verifica con gpresult /h C:\Temp\gpresult-dc-admin-logon.html."
Write-Host "3. Verifica membership: Get-ADGroupMember 'Domain Admins' -Recursive | ? SamAccountName -like 'admin.it.*'"
Write-Host "4. Prova logon locale/RDP con admin.it.user01 o altro admin.it.*."
