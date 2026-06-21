# Runbook operativo LAB Active Directory
## Creazione OU, gruppi, utenti, ACL, share SMB e GPO con PowerShell

**Dominio:** `ad-lab-domain`  
**Perimetro logico:** `OU=LAB`  
**Versione:** 1.0  
**Formato:** Markdown  

> **Nota di sicurezza:** questo runbook è pensato per un laboratorio didattico. Prima di usarlo in ambienti reali, validare naming, privilegi, GPO, ACL e procedure di recovery. Eseguire sempre prima con `-WhatIf` dove disponibile e mantenere un backup/rollback.

---

Ho mantenuto la struttura coerente con il design revisionato del laboratorio ad-lab-domain e con il modello AGDLP già definito nel documento di partenza. 2
Per i cmdlet principali ho usato come riferimento operativo i moduli PowerShell documentati per Active Directory, Group Policy e SMB share: New-ADOrganizationalUnit, New-GPLink / GPO linking e New-SmbShare. [eu-prod.as...rosoft.com] [learn.microsoft.com], [learn.microsoft.com], [learn.microsoft.com]
Nota importante: nel runbook ho lasciato password placeholder tipo ChangeMe; prima di eseguirlo nel lab conviene sostituirle oppure trasformarle in prompt sicuri con Read-Host -AsSecureString.

## 0. Obiettivo del runbook

Questo runbook automatizza la creazione del laboratorio Active Directory **LAB**:

1. prerequisiti e variabili globali;
2. struttura OU;
3. gruppi di sicurezza secondo modello **AGDLP**;
4. utenti standard, Director, Board, admin separati, break-glass e honey object;
5. membership tra utenti, global group e domain local group;
6. struttura file share e ACL NTFS;
7. condivisioni SMB;
8. GPO di base e collegamenti alle OU;
9. script di drive mapping;
10. verifiche finali;
11. rollback controllato.

---

## 1. Convenzioni usate

### 1.1 OU principali

```text
OU=LAB
├── OU=Departments
│   ├── OU=IT
│   ├── OU=Finance
│   ├── OU=HR
│   ├── OU=Marketing
│   ├── OU=Sales
│   └── OU=Board
├── OU=Admins
│   ├── OU=IT-Admins
│   └── OU=Break-Glass
├── OU=Groups
│   ├── OU=Security
│   └── OU=Distribution
├── OU=ServiceAccounts
│   ├── OU=UserManagedServiceAccounts
│   ├── OU=gMSA
│   └── OU=SecurityApp
└── OU=Computers
    ├── OU=Staging
    ├── OU=Workstations
    └── OU=Servers
```

### 1.2 Gruppi

- **Global Group**: rappresentano identità, ruoli e appartenenze organizzative.
- **Domain Local Group**: rappresentano permessi su risorse.
- **ACL**: vengono assegnate solo ai Domain Local Group.

Schema:

```text
Account utente → GG_* → DL_* → ACL sulla risorsa
```

---

## 2. Prerequisiti

Eseguire da un Domain Controller oppure da una macchina amministrativa con RSAT installato.

### 2.1 Moduli PowerShell richiesti

```powershell
Import-Module ActiveDirectory
Import-Module GroupPolicy
Import-Module SmbShare
```

### 2.2 Verifica privilegi

```powershell
whoami /groups | findstr /i "Domain Admins Enterprise Admins"
```

Per il laboratorio è consigliato eseguire con un account membro di `Domain Admins`.

### 2.3 Avvio transcript

```powershell
$TranscriptPath = "C:\Temp\LAB-AD-Runbook-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
New-Item -Path (Split-Path $TranscriptPath) -ItemType Directory -Force | Out-Null
Start-Transcript -Path $TranscriptPath
```

---

## 3. Variabili globali

> Questa sezione evita di scrivere a mano il Distinguished Name del dominio. Il DN viene rilevato dinamicamente con `Get-ADDomain`.

```powershell
Import-Module ActiveDirectory
Import-Module GroupPolicy

$Domain      = Get-ADDomain
$DomainDN    = $Domain.DistinguishedName
$DomainDNS   = $Domain.DNSRoot
$NetBIOS     = $Domain.NetBIOSName

$LabOUName   = "LAB"
$LabDN       = "OU=$LabOUName,$DomainDN"

$Departments = @("IT", "Finance", "HR", "Marketing", "Sales")
$Units       = $Departments + "Board"

$FileServerName = "SRV-FS-001"
$ShareRoot      = "D:\Shares"
$DeptRoot       = Join-Path $ShareRoot "Departments"
$SharedRoot     = Join-Path $ShareRoot "Shared"

$DefaultUserPassword = ConvertTo-SecureString "P@ssw0rd-LAB-ChangeMe!2026" -AsPlainText -Force
$AdminPassword       = ConvertTo-SecureString "Adm1n-LAB-ChangeMe!2026" -AsPlainText -Force
$BreakGlassPassword  = ConvertTo-SecureString "BreakGlass-LAB-ChangeMe!2026" -AsPlainText -Force
$HoneyPassword       = ConvertTo-SecureString "Honey-LAB-ChangeMe!2026" -AsPlainText -Force
```

> In un laboratorio la password può essere fissa per semplicità. In un ambiente reale usare password uniche, robuste, archiviate in modo sicuro e ruotate secondo policy.

---

## 4. Funzioni helper

### 4.1 Creazione OU idempotente

```powershell
function Ensure-ADOU {
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [string] $Path,
        [string] $Description = "LAB OU"
    )

    $TargetDN = "OU=$Name,$Path"
    $Existing = Get-ADOrganizationalUnit -LDAPFilter "(distinguishedName=$TargetDN)" -ErrorAction SilentlyContinue

    if (-not $Existing) {
        New-ADOrganizationalUnit `
            -Name $Name `
            -Path $Path `
            -Description $Description `
            -ProtectedFromAccidentalDeletion $true

        Write-Host "[OK] Creata OU: $TargetDN" -ForegroundColor Green
    }
    else {
        Write-Host "[SKIP] OU già esistente: $TargetDN" -ForegroundColor Yellow
    }
}
```

### 4.2 Creazione gruppo idempotente

```powershell
function Ensure-ADGroup {
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

        Write-Host "[OK] Creato gruppo: $Name" -ForegroundColor Green
    }
    else {
        Write-Host "[SKIP] Gruppo già esistente: $Name" -ForegroundColor Yellow
    }
}
```

### 4.3 Membership idempotente

```powershell
function Ensure-ADGroupMember {
    param(
        [Parameter(Mandatory)] [string] $Group,
        [Parameter(Mandatory)] [string[]] $Members
    )

    foreach ($Member in $Members) {
        try {
            $AlreadyMember = Get-ADGroupMember -Identity $Group -Recursive | Where-Object {
                $_.SamAccountName -eq $Member -or $_.Name -eq $Member
            }

            if (-not $AlreadyMember) {
                Add-ADGroupMember -Identity $Group -Members $Member
                Write-Host "[OK] Aggiunto $Member a $Group" -ForegroundColor Green
            }
            else {
                Write-Host "[SKIP] $Member già membro di $Group" -ForegroundColor Yellow
            }
        }
        catch {
            Write-Warning "Errore membership: $Member -> $Group. Dettaglio: $_"
        }
    }
}
```

### 4.4 Creazione utente idempotente

```powershell
function Ensure-ADUserLab {
    param(
        [Parameter(Mandatory)] [string] $SamAccountName,
        [Parameter(Mandatory)] [string] $GivenName,
        [Parameter(Mandatory)] [string] $Surname,
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [securestring] $Password,
        [string] $Description = "LAB user",
        [bool] $Enabled = $true
    )

    $Existing = Get-ADUser -LDAPFilter "(sAMAccountName=$SamAccountName)" -ErrorAction SilentlyContinue

    if (-not $Existing) {
        $DisplayName = "$GivenName $Surname"
        $UPN = "$SamAccountName@$DomainDNS"

        New-ADUser `
            -Name $DisplayName `
            -GivenName $GivenName `
            -Surname $Surname `
            -DisplayName $DisplayName `
            -SamAccountName $SamAccountName `
            -UserPrincipalName $UPN `
            -Path $Path `
            -AccountPassword $Password `
            -Enabled $Enabled `
            -ChangePasswordAtLogon $true `
            -Description $Description

        Write-Host "[OK] Creato utente: $SamAccountName" -ForegroundColor Green
    }
    else {
        Write-Host "[SKIP] Utente già esistente: $SamAccountName" -ForegroundColor Yellow
    }
}
```

### 4.5 Creazione GPO idempotente e link

```powershell
function Ensure-GPOWithLink {
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [string] $TargetDN,
        [string] $Comment = "LAB GPO"
    )

    $Gpo = Get-GPO -Name $Name -ErrorAction SilentlyContinue

    if (-not $Gpo) {
        $Gpo = New-GPO -Name $Name -Comment $Comment
        Write-Host "[OK] Creata GPO: $Name" -ForegroundColor Green
    }
    else {
        Write-Host "[SKIP] GPO già esistente: $Name" -ForegroundColor Yellow
    }

    $Inheritance = Get-GPInheritance -Target $TargetDN
    $ExistingLink = $Inheritance.GpoLinks | Where-Object { $_.DisplayName -eq $Name }

    if (-not $ExistingLink) {
        New-GPLink -Name $Name -Target $TargetDN -LinkEnabled Yes | Out-Null
        Write-Host "[OK] Link GPO $Name -> $TargetDN" -ForegroundColor Green
    }
    else {
        Write-Host "[SKIP] Link già presente: $Name -> $TargetDN" -ForegroundColor Yellow
    }
}
```

### 4.6 ACL NTFS helper

```powershell
function Reset-FolderAcl {
    param(
        [Parameter(Mandatory)] [string] $Path
    )

    $Acl = Get-Acl -Path $Path
    $Acl.SetAccessRuleProtection($true, $false)

    foreach ($Ace in @($Acl.Access)) {
        $Acl.RemoveAccessRule($Ace) | Out-Null
    }

    Set-Acl -Path $Path -AclObject $Acl
}

function Add-FolderAce {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $Identity,
        [Parameter(Mandatory)] [System.Security.AccessControl.FileSystemRights] $Rights,
        [System.Security.AccessControl.InheritanceFlags] $InheritanceFlags = "ContainerInherit, ObjectInherit",
        [System.Security.AccessControl.PropagationFlags] $PropagationFlags = "None",
        [System.Security.AccessControl.AccessControlType] $Type = "Allow"
    )

    $Acl = Get-Acl -Path $Path
    $Rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        $Identity,
        $Rights,
        $InheritanceFlags,
        $PropagationFlags,
        $Type
    )
    $Acl.AddAccessRule($Rule)
    Set-Acl -Path $Path -AclObject $Acl
}
```

---

## 5. Creazione struttura OU

```powershell
# Root LAB
Ensure-ADOU -Name "LAB" -Path $DomainDN -Description "LAB root OU"

# Primo livello
Ensure-ADOU -Name "Departments"     -Path $LabDN -Description "LAB user identities"
Ensure-ADOU -Name "Admins"          -Path $LabDN -Description "LAB admin accounts"
Ensure-ADOU -Name "Groups"          -Path $LabDN -Description "LAB groups"
Ensure-ADOU -Name "ServiceAccounts" -Path $LabDN -Description "LAB service accounts"
Ensure-ADOU -Name "Computers"       -Path $LabDN -Description "LAB computers"

# Departments + Board
foreach ($Unit in $Units) {
    Ensure-ADOU -Name $Unit -Path "OU=Departments,$LabDN" -Description "LAB unit: $Unit"
}

# Admins
Ensure-ADOU -Name "IT-Admins"   -Path "OU=Admins,$LabDN" -Description "LAB IT admin accounts"
Ensure-ADOU -Name "Break-Glass" -Path "OU=Admins,$LabDN" -Description "LAB emergency accounts"

# Groups
Ensure-ADOU -Name "Security"     -Path "OU=Groups,$LabDN" -Description "LAB security groups"
Ensure-ADOU -Name "Distribution" -Path "OU=Groups,$LabDN" -Description "LAB distribution groups"

# Service accounts
Ensure-ADOU -Name "UserManagedServiceAccounts" -Path "OU=ServiceAccounts,$LabDN" -Description "LAB traditional service accounts"
Ensure-ADOU -Name "gMSA"                       -Path "OU=ServiceAccounts,$LabDN" -Description "LAB group managed service accounts"
Ensure-ADOU -Name "SecurityApp"                -Path "OU=ServiceAccounts,$LabDN" -Description "LAB security application accounts"

# Computers
Ensure-ADOU -Name "Staging"      -Path "OU=Computers,$LabDN" -Description "LAB staging/quarantine computers"
Ensure-ADOU -Name "Workstations" -Path "OU=Computers,$LabDN" -Description "LAB workstations"
Ensure-ADOU -Name "Servers"      -Path "OU=Computers,$LabDN" -Description "LAB member servers"
```

### 5.1 Opzionale: redirect container predefiniti

> Utile per evitare che nuovi utenti/computer finiscano nei container predefiniti `CN=Users` e `CN=Computers`.

```powershell
# Nuovi utenti creati senza Path esplicito
redirusr "OU=Departments,$LabDN"

# Nuovi computer aggiunti al dominio senza prestaging
redircmp "OU=Staging,OU=Computers,$LabDN"
```

---

## 6. Creazione gruppi AGDLP

### 6.1 Percorso gruppi

```powershell
$GroupsSecurityDN = "OU=Security,OU=Groups,$LabDN"
```

### 6.2 Global Group identità/ruoli

```powershell
# Gruppi globali generali
Ensure-ADGroup -Name "GG_LAB_AllUsers"  -Path $GroupsSecurityDN -Scope Global -Description "All standard LAB users"
Ensure-ADGroup -Name "GG_LAB_Directors" -Path $GroupsSecurityDN -Scope Global -Description "All LAB directors and Board members"
Ensure-ADGroup -Name "GG_LAB_Admins"    -Path $GroupsSecurityDN -Scope Global -Description "LAB separated admin accounts"
Ensure-ADGroup -Name "GG_Board_Members" -Path $GroupsSecurityDN -Scope Global -Description "LAB Board members"
Ensure-ADGroup -Name "GG_SecurityApp"   -Path $GroupsSecurityDN -Scope Global -Description "LAB security application/service accounts"
Ensure-ADGroup -Name "GG_LAB_BreakGlass" -Path $GroupsSecurityDN -Scope Global -Description "LAB emergency access account(s)"

# Gruppi globali dipartimentali
foreach ($Dept in $Departments) {
    Ensure-ADGroup -Name "GG_${Dept}_Users"    -Path $GroupsSecurityDN -Scope Global -Description "$Dept standard users"
    Ensure-ADGroup -Name "GG_${Dept}_Director" -Path $GroupsSecurityDN -Scope Global -Description "$Dept director"
}
```

### 6.3 Domain Local Group per permessi file server

```powershell
# Gruppi permessi per share globale Shared
Ensure-ADGroup -Name "DL_FS_Shared_RO" -Path $GroupsSecurityDN -Scope DomainLocal -Description "RO on global Shared share"
Ensure-ADGroup -Name "DL_FS_Shared_MD" -Path $GroupsSecurityDN -Scope DomainLocal -Description "MD on global Shared share"
Ensure-ADGroup -Name "DL_FS_Shared_FC" -Path $GroupsSecurityDN -Scope DomainLocal -Description "FC on global Shared share"

# Gruppi permessi per ogni dipartimento
foreach ($Dept in $Departments) {
    foreach ($Area in @("Public", "Internal", "Confidential")) {
        switch ($Area) {
            "Public" {
                Ensure-ADGroup -Name "DL_FS_${Dept}_${Area}_WO" -Path $GroupsSecurityDN -Scope DomainLocal -Description "$Dept $Area write-only/add-only"
                Ensure-ADGroup -Name "DL_FS_${Dept}_${Area}_MD" -Path $GroupsSecurityDN -Scope DomainLocal -Description "$Dept $Area modify"
                Ensure-ADGroup -Name "DL_FS_${Dept}_${Area}_RO" -Path $GroupsSecurityDN -Scope DomainLocal -Description "$Dept $Area read-only"
                Ensure-ADGroup -Name "DL_FS_${Dept}_${Area}_FC" -Path $GroupsSecurityDN -Scope DomainLocal -Description "$Dept $Area full control"
            }
            "Internal" {
                Ensure-ADGroup -Name "DL_FS_${Dept}_${Area}_MD" -Path $GroupsSecurityDN -Scope DomainLocal -Description "$Dept $Area modify"
                Ensure-ADGroup -Name "DL_FS_${Dept}_${Area}_FC" -Path $GroupsSecurityDN -Scope DomainLocal -Description "$Dept $Area full control"
            }
            "Confidential" {
                Ensure-ADGroup -Name "DL_FS_${Dept}_${Area}_MD" -Path $GroupsSecurityDN -Scope DomainLocal -Description "$Dept $Area modify"
                Ensure-ADGroup -Name "DL_FS_${Dept}_${Area}_FC" -Path $GroupsSecurityDN -Scope DomainLocal -Description "$Dept $Area full control"
            }
        }
    }
}
```

### 6.4 Domain Local Group per RDP amministrativo

```powershell
Ensure-ADGroup -Name "DL_RDP_SRV-FS-001_Admins"  -Path $GroupsSecurityDN -Scope DomainLocal -Description "RDP admins on SRV-FS-001"
Ensure-ADGroup -Name "DL_RDP_SRV-APP-001_Admins" -Path $GroupsSecurityDN -Scope DomainLocal -Description "RDP admins on SRV-APP-001"
Ensure-ADGroup -Name "DL_RDP_SRV-DB-001_Admins"  -Path $GroupsSecurityDN -Scope DomainLocal -Description "RDP admins on SRV-DB-001"
```

---

## 7. Creazione utenti LAB

### 7.1 Dataset utenti standard

Il dataset crea **24 utenti standard**:

- 4 utenti per IT;
- 4 utenti per Finance;
- 4 utenti per HR;
- 4 utenti per Marketing;
- 4 utenti per Sales;
- 4 membri Board.

Per ogni dipartimento operativo, il primo utente è anche Director. I 4 utenti Board sono anche membri Board e Director/Executive.

```powershell
$LabUsers = @(
    # IT
    @{Sam="it.user01"; Given="IT"; Surname="User01"; Unit="IT"; Director=$true;  Board=$false},
    @{Sam="it.user02"; Given="IT"; Surname="User02"; Unit="IT"; Director=$false; Board=$false},
    @{Sam="it.user03"; Given="IT"; Surname="User03"; Unit="IT"; Director=$false; Board=$false},
    @{Sam="it.user04"; Given="IT"; Surname="User04"; Unit="IT"; Director=$false; Board=$false},

    # Finance
    @{Sam="finance.user01"; Given="Finance"; Surname="User01"; Unit="Finance"; Director=$true;  Board=$false},
    @{Sam="finance.user02"; Given="Finance"; Surname="User02"; Unit="Finance"; Director=$false; Board=$false},
    @{Sam="finance.user03"; Given="Finance"; Surname="User03"; Unit="Finance"; Director=$false; Board=$false},
    @{Sam="finance.user04"; Given="Finance"; Surname="User04"; Unit="Finance"; Director=$false; Board=$false},

    # HR
    @{Sam="hr.user01"; Given="HR"; Surname="User01"; Unit="HR"; Director=$true;  Board=$false},
    @{Sam="hr.user02"; Given="HR"; Surname="User02"; Unit="HR"; Director=$false; Board=$false},
    @{Sam="hr.user03"; Given="HR"; Surname="User03"; Unit="HR"; Director=$false; Board=$false},
    @{Sam="hr.user04"; Given="HR"; Surname="User04"; Unit="HR"; Director=$false; Board=$false},

    # Marketing
    @{Sam="marketing.user01"; Given="Marketing"; Surname="User01"; Unit="Marketing"; Director=$true;  Board=$false},
    @{Sam="marketing.user02"; Given="Marketing"; Surname="User02"; Unit="Marketing"; Director=$false; Board=$false},
    @{Sam="marketing.user03"; Given="Marketing"; Surname="User03"; Unit="Marketing"; Director=$false; Board=$false},
    @{Sam="marketing.user04"; Given="Marketing"; Surname="User04"; Unit="Marketing"; Director=$false; Board=$false},

    # Sales
    @{Sam="sales.user01"; Given="Sales"; Surname="User01"; Unit="Sales"; Director=$true;  Board=$false},
    @{Sam="sales.user02"; Given="Sales"; Surname="User02"; Unit="Sales"; Director=$false; Board=$false},
    @{Sam="sales.user03"; Given="Sales"; Surname="User03"; Unit="Sales"; Director=$false; Board=$false},
    @{Sam="sales.user04"; Given="Sales"; Surname="User04"; Unit="Sales"; Director=$false; Board=$false},

    # Board
    @{Sam="board.user01"; Given="Board"; Surname="User01"; Unit="Board"; Director=$true; Board=$true},
    @{Sam="board.user02"; Given="Board"; Surname="User02"; Unit="Board"; Director=$true; Board=$true},
    @{Sam="board.user03"; Given="Board"; Surname="User03"; Unit="Board"; Director=$true; Board=$true},
    @{Sam="board.user04"; Given="Board"; Surname="User04"; Unit="Board"; Director=$true; Board=$true}
)
```

### 7.2 Creazione utenti standard

```powershell
foreach ($User in $LabUsers) {
    $UserOU = "OU=$($User.Unit),OU=Departments,$LabDN"

    Ensure-ADUserLab `
        -SamAccountName $User.Sam `
        -GivenName $User.Given `
        -Surname $User.Surname `
        -Path $UserOU `
        -Password $DefaultUserPassword `
        -Description "LAB standard user - $($User.Unit)" `
        -Enabled $true
}
```

### 7.3 Creazione account admin separati

Gli account admin vengono creati solo per i 4 utenti IT.

```powershell
$AdminSourceUsers = @("it.user01", "it.user02", "it.user03", "it.user04")
$AdminOU = "OU=IT-Admins,OU=Admins,$LabDN"

foreach ($SourceSam in $AdminSourceUsers) {
    $AdminSam = "admin.$SourceSam"

    Ensure-ADUserLab `
        -SamAccountName $AdminSam `
        -GivenName "Admin" `
        -Surname $SourceSam `
        -Path $AdminOU `
        -Password $AdminPassword `
        -Description "LAB separated admin account for $SourceSam" `
        -Enabled $true
}
```

### 7.4 Creazione break-glass

```powershell
$BreakGlassOU = "OU=Break-Glass,OU=Admins,$LabDN"

Ensure-ADUserLab `
    -SamAccountName "super.user" `
    -GivenName "Super" `
    -Surname "User" `
    -Path $BreakGlassOU `
    -Password $BreakGlassPassword `
    -Description "LAB BREAK-GLASS emergency account - use only for recovery" `
    -Enabled $true

# Rafforzamento base dell'account
Set-ADUser -Identity "super.user" -PasswordNeverExpires $true -AccountNotDelegated $true

# Nel laboratorio: account di recovery altamente privilegiato
Ensure-ADGroupMember -Group "GG_LAB_BreakGlass" -Members @("super.user")
Ensure-ADGroupMember -Group "Domain Admins" -Members @("super.user")
```

> In produzione evitare uso quotidiano, monitorare ogni logon e custodire le credenziali offline. Valutare almeno due account di emergenza e procedure di doppio controllo.

### 7.5 Creazione honey object

```powershell
$HoneyOU = "OU=IT-Admins,OU=Admins,$LabDN"

Ensure-ADUserLab `
    -SamAccountName "admin.backup" `
    -GivenName "Admin" `
    -Surname "Backup" `
    -Path $HoneyOU `
    -Password $HoneyPassword `
    -Description "LAB HONEY OBJECT - monitored decoy account - no real privileges" `
    -Enabled $true

Set-ADUser -Identity "admin.backup" -AccountNotDelegated $true
```

> Non aggiungere `admin.backup` a gruppi privilegiati reali. L'oggetto serve solo a generare eventi di sicurezza in caso di uso improprio.

---

## 8. Membership identità → Global Group

```powershell
foreach ($User in $LabUsers) {
    Ensure-ADGroupMember -Group "GG_LAB_AllUsers" -Members @($User.Sam)

    if ($Departments -contains $User.Unit) {
        Ensure-ADGroupMember -Group "GG_$($User.Unit)_Users" -Members @($User.Sam)
    }

    if ($User.Director -eq $true) {
        Ensure-ADGroupMember -Group "GG_LAB_Directors" -Members @($User.Sam)

        if ($Departments -contains $User.Unit) {
            Ensure-ADGroupMember -Group "GG_$($User.Unit)_Director" -Members @($User.Sam)
        }
    }

    if ($User.Board -eq $true) {
        Ensure-ADGroupMember -Group "GG_Board_Members" -Members @($User.Sam)
    }
}

foreach ($SourceSam in $AdminSourceUsers) {
    Ensure-ADGroupMember -Group "GG_LAB_Admins" -Members @("admin.$SourceSam")
}
```

---

## 9. Membership Global Group → Domain Local Group

### 9.1 Shared globale

```powershell
Ensure-ADGroupMember -Group "DL_FS_Shared_RO" -Members @("GG_LAB_AllUsers")
Ensure-ADGroupMember -Group "DL_FS_Shared_FC" -Members @("GG_LAB_BreakGlass")
Ensure-ADGroupMember -Group "DL_FS_Shared_FC" -Members @("GG_LAB_Admins")
```

### 9.2 Permessi dipartimentali

```powershell
foreach ($Dept in $Departments) {
    # Public
    Ensure-ADGroupMember -Group "DL_FS_${Dept}_Public_WO" -Members @("GG_${Dept}_Users")
    Ensure-ADGroupMember -Group "DL_FS_${Dept}_Public_MD" -Members @("GG_${Dept}_Director", "GG_SecurityApp")
    Ensure-ADGroupMember -Group "DL_FS_${Dept}_Public_FC" -Members @("GG_LAB_Admins", "GG_LAB_BreakGlass")

    # Internal
    Ensure-ADGroupMember -Group "DL_FS_${Dept}_Internal_MD" -Members @("GG_${Dept}_Users", "GG_${Dept}_Director", "GG_SecurityApp")
    Ensure-ADGroupMember -Group "DL_FS_${Dept}_Internal_FC" -Members @("GG_LAB_Admins", "GG_LAB_BreakGlass")

    # Confidential: niente admin IT per default
    Ensure-ADGroupMember -Group "DL_FS_${Dept}_Confidential_MD" -Members @("GG_${Dept}_Director", "GG_Board_Members", "GG_SecurityApp")
    Ensure-ADGroupMember -Group "DL_FS_${Dept}_Confidential_FC" -Members @("GG_LAB_BreakGlass")
}
```

### 9.3 RDP amministrativo su server membri

```powershell
Ensure-ADGroupMember -Group "DL_RDP_SRV-FS-001_Admins"  -Members @("GG_LAB_Admins", "GG_LAB_BreakGlass")
Ensure-ADGroupMember -Group "DL_RDP_SRV-APP-001_Admins" -Members @("GG_LAB_Admins", "GG_LAB_BreakGlass")
Ensure-ADGroupMember -Group "DL_RDP_SRV-DB-001_Admins"  -Members @("GG_LAB_Admins", "GG_LAB_BreakGlass")
```

---

## 10. File server: cartelle, ACL NTFS e share SMB

> Questa sezione va eseguita sul file server `SRV-FS-001`. Se si esegue da un DC, usare `Invoke-Command`.

### 10.1 Esecuzione remota consigliata

```powershell
Invoke-Command -ComputerName $FileServerName -ScriptBlock {
    param($ShareRoot, $DeptRoot, $SharedRoot, $Departments, $NetBIOS)

    New-Item -Path $ShareRoot  -ItemType Directory -Force | Out-Null
    New-Item -Path $DeptRoot   -ItemType Directory -Force | Out-Null
    New-Item -Path $SharedRoot -ItemType Directory -Force | Out-Null

    foreach ($Dept in $Departments) {
        New-Item -Path (Join-Path $DeptRoot $Dept) -ItemType Directory -Force | Out-Null
        New-Item -Path (Join-Path $DeptRoot "$Dept\Public") -ItemType Directory -Force | Out-Null
        New-Item -Path (Join-Path $DeptRoot "$Dept\Internal") -ItemType Directory -Force | Out-Null
        New-Item -Path (Join-Path $DeptRoot "$Dept\Confidential") -ItemType Directory -Force | Out-Null
    }
} -ArgumentList $ShareRoot, $DeptRoot, $SharedRoot, $Departments, $NetBIOS
```

### 10.2 Applicazione ACL NTFS

> Le funzioni `Reset-FolderAcl` e `Add-FolderAce` devono essere disponibili anche nella sessione remota. Per semplicità vengono ridefinite dentro lo script block.

```powershell
Invoke-Command -ComputerName $FileServerName -ScriptBlock {
    param($ShareRoot, $DeptRoot, $SharedRoot, $Departments, $NetBIOS)

    function Reset-FolderAcl {
        param([Parameter(Mandatory)] [string] $Path)
        $Acl = Get-Acl -Path $Path
        $Acl.SetAccessRuleProtection($true, $false)
        foreach ($Ace in @($Acl.Access)) {
            $Acl.RemoveAccessRule($Ace) | Out-Null
        }
        Set-Acl -Path $Path -AclObject $Acl
    }

    function Add-FolderAce {
        param(
            [Parameter(Mandatory)] [string] $Path,
            [Parameter(Mandatory)] [string] $Identity,
            [Parameter(Mandatory)] [System.Security.AccessControl.FileSystemRights] $Rights,
            [System.Security.AccessControl.InheritanceFlags] $InheritanceFlags = "ContainerInherit, ObjectInherit",
            [System.Security.AccessControl.PropagationFlags] $PropagationFlags = "None",
            [System.Security.AccessControl.AccessControlType] $Type = "Allow"
        )
        $Acl = Get-Acl -Path $Path
        $Rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $Identity,
            $Rights,
            $InheritanceFlags,
            $PropagationFlags,
            $Type
        )
        $Acl.AddAccessRule($Rule)
        Set-Acl -Path $Path -AclObject $Acl
    }

    # Root shares
    Reset-FolderAcl -Path $ShareRoot
    Add-FolderAce -Path $ShareRoot -Identity "BUILTIN\Administrators" -Rights FullControl
    Add-FolderAce -Path $ShareRoot -Identity "NT AUTHORITY\SYSTEM" -Rights FullControl

    # Shared globale
    Reset-FolderAcl -Path $SharedRoot
    Add-FolderAce -Path $SharedRoot -Identity "BUILTIN\Administrators" -Rights FullControl
    Add-FolderAce -Path $SharedRoot -Identity "NT AUTHORITY\SYSTEM" -Rights FullControl
    Add-FolderAce -Path $SharedRoot -Identity "$NetBIOS\DL_FS_Shared_RO" -Rights ReadAndExecute
    Add-FolderAce -Path $SharedRoot -Identity "$NetBIOS\DL_FS_Shared_MD" -Rights Modify
    Add-FolderAce -Path $SharedRoot -Identity "$NetBIOS\DL_FS_Shared_FC" -Rights FullControl

    foreach ($Dept in $Departments) {
        $DeptPath = Join-Path $DeptRoot $Dept
        $PublicPath = Join-Path $DeptPath "Public"
        $InternalPath = Join-Path $DeptPath "Internal"
        $ConfidentialPath = Join-Path $DeptPath "Confidential"

        foreach ($Path in @($DeptPath, $PublicPath, $InternalPath, $ConfidentialPath)) {
            Reset-FolderAcl -Path $Path
            Add-FolderAce -Path $Path -Identity "BUILTIN\Administrators" -Rights FullControl
            Add-FolderAce -Path $Path -Identity "NT AUTHORITY\SYSTEM" -Rights FullControl
        }

        # Public: WO/add-only + MD + RO + FC
        # Nota: il vero write-only NTFS richiede ACL avanzate. Questa ACE consente creazione/append sul folder.
        Add-FolderAce `
            -Path $PublicPath `
            -Identity "$NetBIOS\DL_FS_${Dept}_Public_WO" `
            -Rights "CreateFiles, AppendData, ReadAttributes, ReadPermissions, Synchronize" `
            -InheritanceFlags None `
            -PropagationFlags None

        Add-FolderAce -Path $PublicPath -Identity "$NetBIOS\DL_FS_${Dept}_Public_MD" -Rights Modify
        Add-FolderAce -Path $PublicPath -Identity "$NetBIOS\DL_FS_${Dept}_Public_RO" -Rights ReadAndExecute
        Add-FolderAce -Path $PublicPath -Identity "$NetBIOS\DL_FS_${Dept}_Public_FC" -Rights FullControl

        # Internal
        Add-FolderAce -Path $InternalPath -Identity "$NetBIOS\DL_FS_${Dept}_Internal_MD" -Rights Modify
        Add-FolderAce -Path $InternalPath -Identity "$NetBIOS\DL_FS_${Dept}_Internal_FC" -Rights FullControl

        # Confidential: admin IT non inseriti. Non usare Deny esplicito se non strettamente necessario.
        Add-FolderAce -Path $ConfidentialPath -Identity "$NetBIOS\DL_FS_${Dept}_Confidential_MD" -Rights Modify
        Add-FolderAce -Path $ConfidentialPath -Identity "$NetBIOS\DL_FS_${Dept}_Confidential_FC" -Rights FullControl
    }
} -ArgumentList $ShareRoot, $DeptRoot, $SharedRoot, $Departments, $NetBIOS
```

### 10.3 Creazione share SMB

```powershell
Invoke-Command -ComputerName $FileServerName -ScriptBlock {
    param($DeptRoot, $SharedRoot, $NetBIOS)

    if (-not (Get-SmbShare -Name "Departments" -ErrorAction SilentlyContinue)) {
        New-SmbShare `
            -Name "Departments" `
            -Path $DeptRoot `
            -FullAccess "BUILTIN\Administrators", "$NetBIOS\GG_LAB_BreakGlass", "$NetBIOS\GG_LAB_Admins" `
            -ChangeAccess "$NetBIOS\GG_LAB_AllUsers" `
            -FolderEnumerationMode AccessBased `
            -CachingMode None `
            -Description "LAB departmental shares"
    }

    if (-not (Get-SmbShare -Name "Shared" -ErrorAction SilentlyContinue)) {
        New-SmbShare `
            -Name "Shared" `
            -Path $SharedRoot `
            -FullAccess "BUILTIN\Administrators", "$NetBIOS\GG_LAB_BreakGlass", "$NetBIOS\GG_LAB_Admins" `
            -ChangeAccess "$NetBIOS\GG_LAB_AllUsers" `
            -FolderEnumerationMode AccessBased `
            -CachingMode None `
            -Description "LAB global shared area"
    }
} -ArgumentList $DeptRoot, $SharedRoot, $NetBIOS
```

### 10.4 Verifica share

```powershell
Invoke-Command -ComputerName $FileServerName -ScriptBlock {
    Get-SmbShare -Name "Departments", "Shared" | Select-Object Name, Path, Description
    Get-SmbShareAccess -Name "Departments"
    Get-SmbShareAccess -Name "Shared"
}
```

---

## 11. Creazione e linking GPO

### 11.1 Variabili OU target

```powershell
$OU_Computers    = "OU=Computers,$LabDN"
$OU_Workstations = "OU=Workstations,OU=Computers,$LabDN"
$OU_Servers      = "OU=Servers,OU=Computers,$LabDN"
$OU_Admins       = "OU=Admins,$LabDN"
$OU_Departments  = "OU=Departments,$LabDN"
$OU_Staging      = "OU=Staging,OU=Computers,$LabDN"
```

### 11.2 Creazione GPO e collegamenti

```powershell
Ensure-GPOWithLink -Name "GPO-LAB-Baseline-Computers"       -TargetDN $OU_Computers    -Comment "LAB computer baseline"
Ensure-GPOWithLink -Name "GPO-LAB-Baseline-Users"           -TargetDN $OU_Departments  -Comment "LAB user baseline"
Ensure-GPOWithLink -Name "GPO-LAB-Workstations-Hardening"   -TargetDN $OU_Workstations -Comment "LAB workstation hardening"
Ensure-GPOWithLink -Name "GPO-LAB-Servers-Hardening"        -TargetDN $OU_Servers      -Comment "LAB server hardening"
Ensure-GPOWithLink -Name "GPO-LAB-Admins-Restrictions"      -TargetDN $OU_Admins       -Comment "LAB admin account restrictions"
Ensure-GPOWithLink -Name "GPO-LAB-Staging-Quarantine"       -TargetDN $OU_Staging      -Comment "LAB staging quarantine policy"
Ensure-GPOWithLink -Name "GPO-LAB-DriveMapping"             -TargetDN $OU_Departments  -Comment "LAB drive mapping"
```

### 11.3 Esempi impostazioni registry-based

> Non tutte le impostazioni GPO sono semplici registry-based policy. Alcune, come User Rights Assignment, richiedono Security Templates, GPMC, LGPO.exe o strumenti dedicati. Qui vengono impostate policy semplici e ripetibili via PowerShell.

#### Firewall dominio attivo

```powershell
Set-GPRegistryValue `
    -Name "GPO-LAB-Baseline-Computers" `
    -Key "HKLM\Software\Policies\Microsoft\WindowsFirewall\DomainProfile" `
    -ValueName "EnableFirewall" `
    -Type DWord `
    -Value 1
```

#### Disabilitazione LM hash

```powershell
Set-GPRegistryValue `
    -Name "GPO-LAB-Baseline-Computers" `
    -Key "HKLM\System\CurrentControlSet\Control\Lsa" `
    -ValueName "NoLMHash" `
    -Type DWord `
    -Value 1
```

#### RDP con Network Level Authentication sui server

```powershell
Set-GPRegistryValue `
    -Name "GPO-LAB-Servers-Hardening" `
    -Key "HKLM\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" `
    -ValueName "UserAuthentication" `
    -Type DWord `
    -Value 1
```

#### Timeout screen saver utente

```powershell
Set-GPRegistryValue `
    -Name "GPO-LAB-Baseline-Users" `
    -Key "HKCU\Software\Policies\Microsoft\Windows\Control Panel\Desktop" `
    -ValueName "ScreenSaveTimeOut" `
    -Type String `
    -Value "900"

Set-GPRegistryValue `
    -Name "GPO-LAB-Baseline-Users" `
    -Key "HKCU\Software\Policies\Microsoft\Windows\Control Panel\Desktop" `
    -ValueName "ScreenSaverIsSecure" `
    -Type String `
    -Value "1"
```

---

## 12. Drive mapping via script PowerShell

### 12.1 Creazione script in SYSVOL

```powershell
$ScriptsPath = "\\$DomainDNS\SYSVOL\$DomainDNS\scripts"
$MapScriptPath = Join-Path $ScriptsPath "Map-LABDrives.ps1"

$MapScript = @'
$Domain = $env:USERDOMAIN
$User = "$Domain\$env:USERNAME"

function Test-GroupMembership {
    param([string]$GroupName)
    try {
        $Current = [Security.Principal.WindowsIdentity]::GetCurrent()
        $Principal = New-Object Security.Principal.WindowsPrincipal($Current)
        return $Principal.IsInRole("$Domain\$GroupName")
    }
    catch {
        return $false
    }
}

# Mappa share globale
New-PSDrive -Name "S" -PSProvider FileSystem -Root "\\SRV-FS-001\Shared" -Persist -ErrorAction SilentlyContinue | Out-Null

# Mappa reparto in base alla membership
$DeptGroups = @("IT", "Finance", "HR", "Marketing", "Sales")
foreach ($Dept in $DeptGroups) {
    if (Test-GroupMembership -GroupName "GG_${Dept}_Users") {
        New-PSDrive -Name "H" -PSProvider FileSystem -Root "\\SRV-FS-001\Departments\$Dept\Internal" -Persist -ErrorAction SilentlyContinue | Out-Null
    }
}
'@

Set-Content -Path $MapScriptPath -Value $MapScript -Encoding UTF8
```

### 12.2 Collegamento tramite GPO usando Run key utente

```powershell
Set-GPRegistryValue `
    -Name "GPO-LAB-DriveMapping" `
    -Key "HKCU\Software\Microsoft\Windows\CurrentVersion\Run" `
    -ValueName "LABDriveMapping" `
    -Type String `
    -Value "powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -File `"\\$DomainDNS\SYSVOL\$DomainDNS\scripts\Map-LABDrives.ps1`""
```

> Variante più pulita: usare Group Policy Preferences → Drive Maps dalla GPMC. Il metodo sopra è comodo in laboratorio perché interamente scriptabile.

---

## 13. Policy locali sui server: RDP group

Per consentire RDP ai soli gruppi previsti, aggiungere il Domain Local Group al gruppo locale **Remote Desktop Users** del server membro.

### 13.1 File server

```powershell
Invoke-Command -ComputerName "SRV-FS-001" -ScriptBlock {
    param($NetBIOS)
    Add-LocalGroupMember -Group "Remote Desktop Users" -Member "$NetBIOS\DL_RDP_SRV-FS-001_Admins" -ErrorAction SilentlyContinue
} -ArgumentList $NetBIOS
```

### 13.2 Application server

```powershell
Invoke-Command -ComputerName "SRV-APP-001" -ScriptBlock {
    param($NetBIOS)
    Add-LocalGroupMember -Group "Remote Desktop Users" -Member "$NetBIOS\DL_RDP_SRV-APP-001_Admins" -ErrorAction SilentlyContinue
} -ArgumentList $NetBIOS
```

### 13.3 Database server

```powershell
Invoke-Command -ComputerName "SRV-DB-001" -ScriptBlock {
    param($NetBIOS)
    Add-LocalGroupMember -Group "Remote Desktop Users" -Member "$NetBIOS\DL_RDP_SRV-DB-001_Admins" -ErrorAction SilentlyContinue
} -ArgumentList $NetBIOS
```

---

## 14. Auditing honey object

### 14.1 Eventi utili da monitorare

Monitorare almeno:

- logon riusciti/falliti dell'utente `admin.backup`;
- modifica membership di `admin.backup`;
- reset password su `admin.backup`;
- abilitazione/disabilitazione account.

### 14.2 Comandi base per verifica eventi su Domain Controller

```powershell
# Eventi logon falliti recenti
Get-WinEvent -FilterHashtable @{LogName='Security'; Id=4625; StartTime=(Get-Date).AddDays(-1)} |
    Where-Object { $_.Properties.Value -contains "admin.backup" } |
    Select-Object TimeCreated, Id, ProviderName, Message

# Eventi logon riusciti recenti
Get-WinEvent -FilterHashtable @{LogName='Security'; Id=4624; StartTime=(Get-Date).AddDays(-1)} |
    Where-Object { $_.Properties.Value -contains "admin.backup" } |
    Select-Object TimeCreated, Id, ProviderName, Message

# Modifica gruppi globali/domain local
Get-WinEvent -FilterHashtable @{LogName='Security'; Id=4728,4732,4756; StartTime=(Get-Date).AddDays(-1)} |
    Where-Object { $_.Message -like "*admin.backup*" } |
    Select-Object TimeCreated, Id, ProviderName, Message
```

### 14.3 Scheduled task di alert locale semplificato

> Esempio didattico: scrive un log locale se trova eventi relativi all'honey object. In ambienti reali usare SIEM, Windows Event Forwarding o Microsoft Sentinel.

```powershell
$HoneyMonitorScript = "C:\Scripts\Monitor-HoneyObject.ps1"
New-Item -Path (Split-Path $HoneyMonitorScript) -ItemType Directory -Force | Out-Null

@'
$Events = Get-WinEvent -FilterHashtable @{LogName='Security'; Id=4624,4625,4728,4732,4756; StartTime=(Get-Date).AddMinutes(-15)} -ErrorAction SilentlyContinue |
    Where-Object { $_.Message -like "*admin.backup*" }

if ($Events) {
    $Out = "C:\Temp\LAB-HoneyObject-Alert.log"
    New-Item -Path (Split-Path $Out) -ItemType Directory -Force | Out-Null
    $Events | Select-Object TimeCreated, Id, ProviderName, Message | Out-File -FilePath $Out -Append
}
'@ | Set-Content -Path $HoneyMonitorScript -Encoding UTF8

$Action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Bypass -File $HoneyMonitorScript"
$Trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 15) -RepetitionDuration (New-TimeSpan -Days 3650)
Register-ScheduledTask -TaskName "LAB-Monitor-HoneyObject" -Action $Action -Trigger $Trigger -RunLevel Highest -Description "Monitor LAB honey object admin.backup"
```

---

## 15. Verifiche finali

### 15.1 Verifica OU

```powershell
Get-ADOrganizationalUnit -SearchBase $LabDN -Filter * |
    Select-Object Name, DistinguishedName |
    Sort-Object DistinguishedName
```

### 15.2 Verifica gruppi

```powershell
Get-ADGroup -SearchBase $GroupsSecurityDN -Filter * |
    Select-Object Name, GroupScope, GroupCategory |
    Sort-Object Name
```

### 15.3 Verifica utenti

```powershell
Get-ADUser -SearchBase $LabDN -Filter * -Properties Description |
    Select-Object SamAccountName, Enabled, Description |
    Sort-Object SamAccountName
```

### 15.4 Verifica membership AGDLP esempio HR

```powershell
Get-ADGroupMember "GG_HR_Users" | Select-Object Name, SamAccountName
Get-ADGroupMember "DL_FS_HR_Internal_MD" | Select-Object Name, SamAccountName, ObjectClass
```

### 15.5 Verifica ACL da file server

```powershell
Invoke-Command -ComputerName $FileServerName -ScriptBlock {
    Get-Acl "D:\Shares\Departments\HR\Internal" | Select-Object -ExpandProperty Access |
        Select-Object IdentityReference, FileSystemRights, AccessControlType, IsInherited
}
```

### 15.6 Verifica GPO linkate

```powershell
Get-GPInheritance -Target $OU_Computers
Get-GPInheritance -Target $OU_Departments
Get-GPInheritance -Target $OU_Admins
```

### 15.7 Report HTML GPO

```powershell
$ReportDir = "C:\Temp\LAB-GPO-Reports"
New-Item -Path $ReportDir -ItemType Directory -Force | Out-Null

Get-GPO -All | Where-Object { $_.DisplayName -like "GPO-LAB-*" } | ForEach-Object {
    Get-GPOReport -Guid $_.Id -ReportType Html -Path (Join-Path $ReportDir "$($_.DisplayName).html")
}
```

### 15.8 Test accessi attesi

| Test | Utente | Risorsa | Risultato atteso |
|---|---|---|---|
| HR Internal | `hr.user02` | `\\SRV-FS-001\Departments\HR\Internal` | Modify |
| HR Internal da Sales | `sales.user02` | `\\SRV-FS-001\Departments\HR\Internal` | Access denied |
| HR Confidential Director | `hr.user01` | `\\SRV-FS-001\Departments\HR\Confidential` | Modify |
| HR Confidential Board | `board.user01` | `\\SRV-FS-001\Departments\HR\Confidential` | Modify |
| HR Confidential Admin IT | `admin.it.user02` | `\\SRV-FS-001\Departments\HR\Confidential` | Access denied |
| Break-glass | `super.user` | aree recovery previste | Full Control |
| Honey object | `admin.backup` | logon interattivo | Alert/evento |

---

## 16. Rollback controllato

> Usare solo in laboratorio. Prima di eliminare oggetti, esportare report e verificare dipendenze.

### 16.1 Rimozione GPO LAB

```powershell
Get-GPO -All | Where-Object { $_.DisplayName -like "GPO-LAB-*" } | ForEach-Object {
    Remove-GPO -Guid $_.Id -Confirm:$false
}
```

### 16.2 Rimozione share SMB

```powershell
Invoke-Command -ComputerName $FileServerName -ScriptBlock {
    foreach ($Share in @("Departments", "Shared")) {
        if (Get-SmbShare -Name $Share -ErrorAction SilentlyContinue) {
            Remove-SmbShare -Name $Share -Force
        }
    }
}
```

### 16.3 Rimozione cartelle file server

```powershell
Invoke-Command -ComputerName $FileServerName -ScriptBlock {
    Remove-Item -Path "D:\Shares" -Recurse -Force
}
```

### 16.4 Rimozione OU LAB

```powershell
# Rimuove protezione da eliminazione accidentale
Get-ADOrganizationalUnit -SearchBase $LabDN -Filter * | ForEach-Object {
    Set-ADOrganizationalUnit -Identity $_.DistinguishedName -ProtectedFromAccidentalDeletion $false
}
Set-ADOrganizationalUnit -Identity $LabDN -ProtectedFromAccidentalDeletion $false

# Cancella intera OU LAB
Remove-ADOrganizationalUnit -Identity $LabDN -Recursive -Confirm:$false
```

---

## 17. Sequenza consigliata di esecuzione

1. Eseguire sezioni **2–4**: prerequisiti, variabili, funzioni.
2. Eseguire sezione **5**: OU.
3. Eseguire sezione **6**: gruppi.
4. Eseguire sezione **7**: utenti, admin, break-glass, honey object.
5. Eseguire sezioni **8–9**: membership AGDLP.
6. Eseguire sezione **10**: cartelle, ACL e SMB share sul file server.
7. Eseguire sezione **11**: GPO e link.
8. Eseguire sezione **12**: drive mapping.
9. Eseguire sezione **13**: RDP groups sui server membri.
10. Eseguire sezione **14**: auditing honey object.
11. Eseguire sezione **15**: verifiche finali.

---

## 18. Note tecniche importanti

### 18.1 Domain Controller

Non spostare i Domain Controller dentro `OU=LAB\Computers\Servers`. I DC devono restare nella OU predefinita **Domain Controllers**, salvo progettazioni avanzate molto controllate.

### 18.2 Deny espliciti

Per `Confidential`, il modello preferito è **non concedere** accesso agli admin IT standard, invece di usare `Deny` espliciti. I deny espliciti possono creare effetti collaterali difficili da diagnosticare, soprattutto se un account appartiene a più gruppi.

### 18.3 Write-only / drop-box

Il permesso `WO` è implementato come ACL avanzata add-only. Per test didattici semplici, se il comportamento risultasse troppo restrittivo o complesso, sostituire temporaneamente `WO` con `Modify` e documentare la semplificazione.

### 18.4 GPO complesse

Le impostazioni registry-based sono facilmente automatizzabili con `Set-GPRegistryValue`. Impostazioni come:

- User Rights Assignment;
- Security Options complesse;
- Restricted Groups;
- Windows Defender policy complete;
- Advanced Audit Policy;

possono richiedere GPMC, security template, backup/import GPO o strumenti dedicati.

---

## 19. Riferimenti operativi

- Active Directory PowerShell module: `New-ADOrganizationalUnit`, `New-ADGroup`, `New-ADUser`, `Add-ADGroupMember`.
- GroupPolicy PowerShell module: `New-GPO`, `New-GPLink`, `Set-GPRegistryValue`, `Get-GPOReport`.
- SMB PowerShell module: `New-SmbShare`, `Get-SmbShareAccess`.
- NTFS ACL: `Get-Acl`, `Set-Acl`, `FileSystemAccessRule`.

---

## 20. Chiusura transcript

```powershell
Stop-Transcript
```
