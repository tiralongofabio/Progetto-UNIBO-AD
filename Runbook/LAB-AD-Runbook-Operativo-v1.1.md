# Runbook operativo LAB Active Directory v1.1
## OU Departments/Governance, gruppi AGDLP, utenti, ACL, share SMB e GPO con PowerShell

**Dominio:** `ad-lab-domain`  
**Perimetro logico:** `OU=LAB`  
**Versione:** 1.1  
**Aggiornamento principale:** separazione tra `OU=Departments` e `OU=Governance`; introduzione delle risorse Board `BoardOnly` e `BoardDirectors`.  
**Formato:** Markdown

> **Nota di sicurezza:** questo runbook è pensato per un laboratorio didattico. Prima di usarlo in ambienti reali, validare naming, privilegi, GPO, ACL e procedure di recovery. Eseguire prima in snapshot/lab pulito e mantenere log di esecuzione.

---

## 0. Obiettivo del runbook

Questo runbook automatizza la creazione del laboratorio Active Directory **LAB** con il seguente modello:

1. struttura OU separata tra **Departments** e **Governance**;
2. gruppi di sicurezza secondo modello **AGDLP**;
3. utenti standard, Director, Board, admin separati, break-glass e honey object;
4. membership utenti → Global Group → Domain Local Group;
5. struttura file server con aree dipartimentali e aree governance;
6. ACL NTFS e share SMB;
7. GPO di base e collegamenti alle OU;
8. drive mapping;
9. auditing dell'honey object;
10. verifiche finali;
11. rollback controllato.

---

## 1. Architettura logica aggiornata

### 1.1 OU principali

```text
OU=LAB
├── OU=Departments
│   ├── OU=IT
│   ├── OU=Finance
│   ├── OU=HR
│   ├── OU=Marketing
│   └── OU=Sales
├── OU=Governance
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

### 1.2 File server

```text
D:\Shares
├── Departments
│   ├── IT
│   │   ├── Public
│   │   ├── Internal
│   │   └── Confidential
│   ├── Finance
│   ├── HR
│   ├── Marketing
│   └── Sales
├── Governance
│   └── Board
│       ├── BoardOnly
│       └── BoardDirectors
└── Shared
```

### 1.3 Share SMB previste

```text
\\SRV-FS-001\Departments
\\SRV-FS-001\Governance
\\SRV-FS-001\Shared
```

### 1.4 Logica Board

Il **Board** non è trattato come dipartimento operativo. È collocato in `OU=Governance` e dispone di due aree documentali:

- `BoardOnly`: documenti riservati ai soli membri Board;
- `BoardDirectors`: documenti condivisi tra membri Board e Directors dei dipartimenti.

---

## 2. Prerequisiti

Eseguire da un Domain Controller oppure da una macchina amministrativa con RSAT installato.

```powershell
Import-Module ActiveDirectory
Import-Module GroupPolicy
Import-Module SmbShare
```

Verifica privilegi:

```powershell
whoami /groups | findstr /i "Domain Admins Enterprise Admins"
```

Avvio transcript:

```powershell
$TranscriptPath = "C:\Temp\LAB-AD-Runbook-v11-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
New-Item -Path (Split-Path $TranscriptPath) -ItemType Directory -Force | Out-Null
Start-Transcript -Path $TranscriptPath
```

---

## 3. Variabili globali

```powershell
Import-Module ActiveDirectory
Import-Module GroupPolicy

$Domain      = Get-ADDomain
$DomainDN    = $Domain.DistinguishedName
$DomainDNS   = $Domain.DNSRoot
$NetBIOS     = $Domain.NetBIOSName

$LabOUName   = "LAB"
$LabDN       = "OU=$LabOUName,$DomainDN"

$Departments     = @("IT", "Finance", "HR", "Marketing", "Sales")
$GovernanceUnits = @("Board")

$FileServerName = "SRV-FS-001"
$ShareRoot      = "D:\Shares"
$DeptRoot       = Join-Path $ShareRoot "Departments"
$GovernanceRoot = Join-Path $ShareRoot "Governance"
$BoardRoot      = Join-Path $GovernanceRoot "Board"
$BoardOnlyPath  = Join-Path $BoardRoot "BoardOnly"
$BoardDirPath   = Join-Path $BoardRoot "BoardDirectors"
$SharedRoot     = Join-Path $ShareRoot "Shared"

$DefaultUserPassword = ConvertTo-SecureString "P@ssw0rd-LAB-ChangeMe!2026" -AsPlainText -Force
$AdminPassword       = ConvertTo-SecureString "Adm1n-LAB-ChangeMe!2026" -AsPlainText -Force
$BreakGlassPassword  = ConvertTo-SecureString "BreakGlass-LAB-ChangeMe!2026" -AsPlainText -Force
$HoneyPassword       = ConvertTo-SecureString "Honey-LAB-ChangeMe!2026" -AsPlainText -Force
```

> In un laboratorio la password può essere fissa per semplicità. In un ambiente reale usare password uniche, robuste e archiviate in modo sicuro.

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

### 4.6 Helper ACL NTFS

```powershell
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
```

---

## 5. Creazione struttura OU

```powershell
# Root LAB
Ensure-ADOU -Name "LAB" -Path $DomainDN -Description "LAB root OU"

# Primo livello
Ensure-ADOU -Name "Departments"     -Path $LabDN -Description "LAB operational departments"
Ensure-ADOU -Name "Governance"      -Path $LabDN -Description "LAB governance units"
Ensure-ADOU -Name "Admins"          -Path $LabDN -Description "LAB admin accounts"
Ensure-ADOU -Name "Groups"          -Path $LabDN -Description "LAB groups"
Ensure-ADOU -Name "ServiceAccounts" -Path $LabDN -Description "LAB service accounts"
Ensure-ADOU -Name "Computers"       -Path $LabDN -Description "LAB computers"

# Dipartimenti operativi
foreach ($Dept in $Departments) {
    Ensure-ADOU -Name $Dept -Path "OU=Departments,$LabDN" -Description "LAB department: $Dept"
}

# Governance
foreach ($GovUnit in $GovernanceUnits) {
    Ensure-ADOU -Name $GovUnit -Path "OU=Governance,$LabDN" -Description "LAB governance unit: $GovUnit"
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

```powershell
redirusr "OU=Departments,$LabDN"
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
Ensure-ADGroup -Name "GG_LAB_AllUsers"    -Path $GroupsSecurityDN -Scope Global -Description "All standard LAB users"
Ensure-ADGroup -Name "GG_LAB_Directors"   -Path $GroupsSecurityDN -Scope Global -Description "All LAB directors"
Ensure-ADGroup -Name "GG_LAB_Admins"      -Path $GroupsSecurityDN -Scope Global -Description "LAB separated admin accounts"
Ensure-ADGroup -Name "GG_LAB_BreakGlass"  -Path $GroupsSecurityDN -Scope Global -Description "LAB emergency access account(s)"
Ensure-ADGroup -Name "GG_Board_Members"   -Path $GroupsSecurityDN -Scope Global -Description "LAB Board members"
Ensure-ADGroup -Name "GG_SecurityApp"     -Path $GroupsSecurityDN -Scope Global -Description "LAB security application/service accounts"

foreach ($Dept in $Departments) {
    Ensure-ADGroup -Name "GG_${Dept}_Users"    -Path $GroupsSecurityDN -Scope Global -Description "$Dept standard users"
    Ensure-ADGroup -Name "GG_${Dept}_Director" -Path $GroupsSecurityDN -Scope Global -Description "$Dept director"
}
```

### 6.3 Domain Local Group per aree dipartimentali

```powershell
Ensure-ADGroup -Name "DL_FS_Shared_RO" -Path $GroupsSecurityDN -Scope DomainLocal -Description "RO on global Shared share"
Ensure-ADGroup -Name "DL_FS_Shared_MD" -Path $GroupsSecurityDN -Scope DomainLocal -Description "MD on global Shared share"
Ensure-ADGroup -Name "DL_FS_Shared_FC" -Path $GroupsSecurityDN -Scope DomainLocal -Description "FC on global Shared share"

foreach ($Dept in $Departments) {
    foreach ($Area in @("Public", "Internal", "Confidential")) {
        switch ($Area) {
            "Public" {
                Ensure-ADGroup -Name "DL_FS_${Dept}_${Area}_WO" -Path $GroupsSecurityDN -Scope DomainLocal -Description "$Dept $Area add-only/drop-box"
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

### 6.4 Domain Local Group per Governance/Board

```powershell
Ensure-ADGroup -Name "DL_FS_Governance_BoardOnly_MD" `
    -Path $GroupsSecurityDN `
    -Scope DomainLocal `
    -Description "Modify access to Board-only governance documents"

Ensure-ADGroup -Name "DL_FS_Governance_BoardOnly_FC" `
    -Path $GroupsSecurityDN `
    -Scope DomainLocal `
    -Description "Full control on Board-only governance documents"

Ensure-ADGroup -Name "DL_FS_Governance_BoardDirectors_MD" `
    -Path $GroupsSecurityDN `
    -Scope DomainLocal `
    -Description "Modify access to Board and Directors shared governance documents"

Ensure-ADGroup -Name "DL_FS_Governance_BoardDirectors_FC" `
    -Path $GroupsSecurityDN `
    -Scope DomainLocal `
    -Description "Full control on Board and Directors shared governance documents"
```

### 6.5 Domain Local Group per RDP amministrativo

```powershell
Ensure-ADGroup -Name "DL_RDP_SRV-FS-001_Admins"  -Path $GroupsSecurityDN -Scope DomainLocal -Description "RDP admins on SRV-FS-001"
Ensure-ADGroup -Name "DL_RDP_SRV-APP-001_Admins" -Path $GroupsSecurityDN -Scope DomainLocal -Description "RDP admins on SRV-APP-001"
Ensure-ADGroup -Name "DL_RDP_SRV-DB-001_Admins"  -Path $GroupsSecurityDN -Scope DomainLocal -Description "RDP admins on SRV-DB-001"
```

---

## 7. Creazione utenti LAB

### 7.1 Dataset utenti standard

```powershell
$LabUsers = @(
    # IT
    @{Sam="it.user01";        Given="IT";        Surname="User01"; Unit="IT";        Type="Department"; Director=$true;  Board=$false},
    @{Sam="it.user02";        Given="IT";        Surname="User02"; Unit="IT";        Type="Department"; Director=$false; Board=$false},
    @{Sam="it.user03";        Given="IT";        Surname="User03"; Unit="IT";        Type="Department"; Director=$false; Board=$false},
    @{Sam="it.user04";        Given="IT";        Surname="User04"; Unit="IT";        Type="Department"; Director=$false; Board=$false},

    # Finance
    @{Sam="finance.user01";   Given="Finance";   Surname="User01"; Unit="Finance";   Type="Department"; Director=$true;  Board=$false},
    @{Sam="finance.user02";   Given="Finance";   Surname="User02"; Unit="Finance";   Type="Department"; Director=$false; Board=$false},
    @{Sam="finance.user03";   Given="Finance";   Surname="User03"; Unit="Finance";   Type="Department"; Director=$false; Board=$false},
    @{Sam="finance.user04";   Given="Finance";   Surname="User04"; Unit="Finance";   Type="Department"; Director=$false; Board=$false},

    # HR
    @{Sam="hr.user01";        Given="HR";        Surname="User01"; Unit="HR";        Type="Department"; Director=$true;  Board=$false},
    @{Sam="hr.user02";        Given="HR";        Surname="User02"; Unit="HR";        Type="Department"; Director=$false; Board=$false},
    @{Sam="hr.user03";        Given="HR";        Surname="User03"; Unit="HR";        Type="Department"; Director=$false; Board=$false},
    @{Sam="hr.user04";        Given="HR";        Surname="User04"; Unit="HR";        Type="Department"; Director=$false; Board=$false},

    # Marketing
    @{Sam="marketing.user01"; Given="Marketing"; Surname="User01"; Unit="Marketing"; Type="Department"; Director=$true;  Board=$false},
    @{Sam="marketing.user02"; Given="Marketing"; Surname="User02"; Unit="Marketing"; Type="Department"; Director=$false; Board=$false},
    @{Sam="marketing.user03"; Given="Marketing"; Surname="User03"; Unit="Marketing"; Type="Department"; Director=$false; Board=$false},
    @{Sam="marketing.user04"; Given="Marketing"; Surname="User04"; Unit="Marketing"; Type="Department"; Director=$false; Board=$false},

    # Sales
    @{Sam="sales.user01";     Given="Sales";     Surname="User01"; Unit="Sales";     Type="Department"; Director=$true;  Board=$false},
    @{Sam="sales.user02";     Given="Sales";     Surname="User02"; Unit="Sales";     Type="Department"; Director=$false; Board=$false},
    @{Sam="sales.user03";     Given="Sales";     Surname="User03"; Unit="Sales";     Type="Department"; Director=$false; Board=$false},
    @{Sam="sales.user04";     Given="Sales";     Surname="User04"; Unit="Sales";     Type="Department"; Director=$false; Board=$false},

    # Board / Governance
    @{Sam="board.user01";     Given="Board";     Surname="User01"; Unit="Board";     Type="Governance"; Director=$false; Board=$true},
    @{Sam="board.user02";     Given="Board";     Surname="User02"; Unit="Board";     Type="Governance"; Director=$false; Board=$true},
    @{Sam="board.user03";     Given="Board";     Surname="User03"; Unit="Board";     Type="Governance"; Director=$false; Board=$true},
    @{Sam="board.user04";     Given="Board";     Surname="User04"; Unit="Board";     Type="Governance"; Director=$false; Board=$true}
)
```

> I membri Board vengono gestiti tramite `GG_Board_Members`. I Director dei dipartimenti sono i primi utenti di ogni dipartimento operativo.

### 7.2 Creazione utenti standard

```powershell
foreach ($User in $LabUsers) {
    if ($User.Type -eq "Governance") {
        $UserOU = "OU=$($User.Unit),OU=Governance,$LabDN"
    }
    else {
        $UserOU = "OU=$($User.Unit),OU=Departments,$LabDN"
    }

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

Set-ADUser -Identity "super.user" -PasswordNeverExpires $true -AccountNotDelegated $true
Ensure-ADGroupMember -Group "GG_LAB_BreakGlass" -Members @("super.user")
Ensure-ADGroupMember -Group "Domain Admins" -Members @("super.user")
```

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

---

## 8. Membership Account → Global Group

```powershell
foreach ($User in $LabUsers) {
    Ensure-ADGroupMember -Group "GG_LAB_AllUsers" -Members @($User.Sam)

    if ($User.Type -eq "Department") {
        Ensure-ADGroupMember -Group "GG_$($User.Unit)_Users" -Members @($User.Sam)
    }

    if ($User.Director -eq $true) {
        Ensure-ADGroupMember -Group "GG_LAB_Directors" -Members @($User.Sam)
        Ensure-ADGroupMember -Group "GG_$($User.Unit)_Director" -Members @($User.Sam)
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

### 9.2 Aree dipartimentali

```powershell
foreach ($Dept in $Departments) {
    # Public
    Ensure-ADGroupMember -Group "DL_FS_${Dept}_Public_WO" -Members @("GG_${Dept}_Users")
    Ensure-ADGroupMember -Group "DL_FS_${Dept}_Public_MD" -Members @("GG_${Dept}_Director", "GG_SecurityApp")
    Ensure-ADGroupMember -Group "DL_FS_${Dept}_Public_FC" -Members @("GG_LAB_Admins", "GG_LAB_BreakGlass")

    # Internal
    Ensure-ADGroupMember -Group "DL_FS_${Dept}_Internal_MD" -Members @("GG_${Dept}_Users", "GG_${Dept}_Director", "GG_SecurityApp")
    Ensure-ADGroupMember -Group "DL_FS_${Dept}_Internal_FC" -Members @("GG_LAB_Admins", "GG_LAB_BreakGlass")

    # Confidential: admin IT non inclusi per default
    Ensure-ADGroupMember -Group "DL_FS_${Dept}_Confidential_MD" -Members @("GG_${Dept}_Director", "GG_Board_Members", "GG_SecurityApp")
    Ensure-ADGroupMember -Group "DL_FS_${Dept}_Confidential_FC" -Members @("GG_LAB_BreakGlass")
}
```

### 9.3 Governance / Board

```powershell
# BoardOnly: solo Board + eventuale SecurityApp + break-glass
Ensure-ADGroupMember -Group "DL_FS_Governance_BoardOnly_MD" -Members @("GG_Board_Members", "GG_SecurityApp")
Ensure-ADGroupMember -Group "DL_FS_Governance_BoardOnly_FC" -Members @("GG_LAB_BreakGlass")

# BoardDirectors: Board + Directors + eventuale SecurityApp + break-glass
Ensure-ADGroupMember -Group "DL_FS_Governance_BoardDirectors_MD" -Members @("GG_Board_Members", "GG_LAB_Directors", "GG_SecurityApp")
Ensure-ADGroupMember -Group "DL_FS_Governance_BoardDirectors_FC" -Members @("GG_LAB_BreakGlass")
```

> Nota: `GG_LAB_Admins` non viene inserito nei gruppi `Governance_*`, per mantenere la logica di riservatezza alta già applicata a `Confidential`.

### 9.4 RDP amministrativo su server membri

```powershell
Ensure-ADGroupMember -Group "DL_RDP_SRV-FS-001_Admins"  -Members @("GG_LAB_Admins", "GG_LAB_BreakGlass")
Ensure-ADGroupMember -Group "DL_RDP_SRV-APP-001_Admins" -Members @("GG_LAB_Admins", "GG_LAB_BreakGlass")
Ensure-ADGroupMember -Group "DL_RDP_SRV-DB-001_Admins"  -Members @("GG_LAB_Admins", "GG_LAB_BreakGlass")
```

---

## 10. File server: cartelle, ACL NTFS e share SMB

> Questa sezione va eseguita sul file server `SRV-FS-001`. Se si esegue da un DC, usare `Invoke-Command`.

### 10.1 Creazione cartelle

```powershell
Invoke-Command -ComputerName $FileServerName -ScriptBlock {
    param($ShareRoot, $DeptRoot, $GovernanceRoot, $BoardRoot, $BoardOnlyPath, $BoardDirPath, $SharedRoot, $Departments)

    New-Item -Path $ShareRoot      -ItemType Directory -Force | Out-Null
    New-Item -Path $DeptRoot       -ItemType Directory -Force | Out-Null
    New-Item -Path $GovernanceRoot -ItemType Directory -Force | Out-Null
    New-Item -Path $BoardRoot      -ItemType Directory -Force | Out-Null
    New-Item -Path $BoardOnlyPath  -ItemType Directory -Force | Out-Null
    New-Item -Path $BoardDirPath   -ItemType Directory -Force | Out-Null
    New-Item -Path $SharedRoot     -ItemType Directory -Force | Out-Null

    foreach ($Dept in $Departments) {
        New-Item -Path (Join-Path $DeptRoot $Dept) -ItemType Directory -Force | Out-Null
        New-Item -Path (Join-Path $DeptRoot "$Dept\Public") -ItemType Directory -Force | Out-Null
        New-Item -Path (Join-Path $DeptRoot "$Dept\Internal") -ItemType Directory -Force | Out-Null
        New-Item -Path (Join-Path $DeptRoot "$Dept\Confidential") -ItemType Directory -Force | Out-Null
    }
} -ArgumentList $ShareRoot, $DeptRoot, $GovernanceRoot, $BoardRoot, $BoardOnlyPath, $BoardDirPath, $SharedRoot, $Departments
```

### 10.2 Applicazione ACL NTFS

```powershell
Invoke-Command -ComputerName $FileServerName -ScriptBlock {
    param($ShareRoot, $DeptRoot, $GovernanceRoot, $BoardRoot, $BoardOnlyPath, $BoardDirPath, $SharedRoot, $Departments, $NetBIOS)

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
        $Rule = New-Object System.Security.AccessControl.FileSystemAccessRule($Identity, $Rights, $InheritanceFlags, $PropagationFlags, $Type)
        $Acl.AddAccessRule($Rule)
        Set-Acl -Path $Path -AclObject $Acl
    }

    # Root principali
    foreach ($Path in @($ShareRoot, $DeptRoot, $GovernanceRoot, $BoardRoot, $SharedRoot)) {
        Reset-FolderAcl -Path $Path
        Add-FolderAce -Path $Path -Identity "BUILTIN\Administrators" -Rights FullControl
        Add-FolderAce -Path $Path -Identity "NT AUTHORITY\SYSTEM" -Rights FullControl
    }

    # Shared globale
    Add-FolderAce -Path $SharedRoot -Identity "$NetBIOS\DL_FS_Shared_RO" -Rights ReadAndExecute
    Add-FolderAce -Path $SharedRoot -Identity "$NetBIOS\DL_FS_Shared_MD" -Rights Modify
    Add-FolderAce -Path $SharedRoot -Identity "$NetBIOS\DL_FS_Shared_FC" -Rights FullControl

    # Aree dipartimentali
    foreach ($Dept in $Departments) {
        $DeptPath         = Join-Path $DeptRoot $Dept
        $PublicPath       = Join-Path $DeptPath "Public"
        $InternalPath     = Join-Path $DeptPath "Internal"
        $ConfidentialPath = Join-Path $DeptPath "Confidential"

        foreach ($Path in @($DeptPath, $PublicPath, $InternalPath, $ConfidentialPath)) {
            Reset-FolderAcl -Path $Path
            Add-FolderAce -Path $Path -Identity "BUILTIN\Administrators" -Rights FullControl
            Add-FolderAce -Path $Path -Identity "NT AUTHORITY\SYSTEM" -Rights FullControl
        }

        # Public: add-only/drop-box + MD + RO + FC
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

        # Confidential
        Add-FolderAce -Path $ConfidentialPath -Identity "$NetBIOS\DL_FS_${Dept}_Confidential_MD" -Rights Modify
        Add-FolderAce -Path $ConfidentialPath -Identity "$NetBIOS\DL_FS_${Dept}_Confidential_FC" -Rights FullControl
    }

    # Governance / Board
    foreach ($Path in @($BoardOnlyPath, $BoardDirPath)) {
        Reset-FolderAcl -Path $Path
        Add-FolderAce -Path $Path -Identity "BUILTIN\Administrators" -Rights FullControl
        Add-FolderAce -Path $Path -Identity "NT AUTHORITY\SYSTEM" -Rights FullControl
    }

    Add-FolderAce -Path $BoardOnlyPath -Identity "$NetBIOS\DL_FS_Governance_BoardOnly_MD" -Rights Modify
    Add-FolderAce -Path $BoardOnlyPath -Identity "$NetBIOS\DL_FS_Governance_BoardOnly_FC" -Rights FullControl

    Add-FolderAce -Path $BoardDirPath -Identity "$NetBIOS\DL_FS_Governance_BoardDirectors_MD" -Rights Modify
    Add-FolderAce -Path $BoardDirPath -Identity "$NetBIOS\DL_FS_Governance_BoardDirectors_FC" -Rights FullControl

} -ArgumentList $ShareRoot, $DeptRoot, $GovernanceRoot, $BoardRoot, $BoardOnlyPath, $BoardDirPath, $SharedRoot, $Departments, $NetBIOS
```

### 10.3 Creazione share SMB

```powershell
Invoke-Command -ComputerName $FileServerName -ScriptBlock {
    param($DeptRoot, $GovernanceRoot, $SharedRoot, $NetBIOS)

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

    if (-not (Get-SmbShare -Name "Governance" -ErrorAction SilentlyContinue)) {
        New-SmbShare `
            -Name "Governance" `
            -Path $GovernanceRoot `
            -FullAccess "BUILTIN\Administrators", "$NetBIOS\GG_LAB_BreakGlass" `
            -ChangeAccess "$NetBIOS\GG_Board_Members", "$NetBIOS\GG_LAB_Directors" `
            -FolderEnumerationMode AccessBased `
            -CachingMode None `
            -Description "LAB governance shares"
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
} -ArgumentList $DeptRoot, $GovernanceRoot, $SharedRoot, $NetBIOS
```

### 10.4 Verifica share SMB

```powershell
Invoke-Command -ComputerName $FileServerName -ScriptBlock {
    Get-SmbShare -Name "Departments", "Governance", "Shared" | Select-Object Name, Path, Description
    Get-SmbShareAccess -Name "Departments"
    Get-SmbShareAccess -Name "Governance"
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
$OU_Governance   = "OU=Governance,$LabDN"
$OU_Staging      = "OU=Staging,OU=Computers,$LabDN"
```

### 11.2 Creazione e link GPO

```powershell
Ensure-GPOWithLink -Name "GPO-LAB-Baseline-Computers"       -TargetDN $OU_Computers    -Comment "LAB computer baseline"
Ensure-GPOWithLink -Name "GPO-LAB-Baseline-Users"           -TargetDN $OU_Departments  -Comment "LAB department user baseline"
Ensure-GPOWithLink -Name "GPO-LAB-Governance-Users"         -TargetDN $OU_Governance   -Comment "LAB governance user baseline"
Ensure-GPOWithLink -Name "GPO-LAB-Workstations-Hardening"   -TargetDN $OU_Workstations -Comment "LAB workstation hardening"
Ensure-GPOWithLink -Name "GPO-LAB-Servers-Hardening"        -TargetDN $OU_Servers      -Comment "LAB server hardening"
Ensure-GPOWithLink -Name "GPO-LAB-Admins-Restrictions"      -TargetDN $OU_Admins       -Comment "LAB admin account restrictions"
Ensure-GPOWithLink -Name "GPO-LAB-Staging-Quarantine"       -TargetDN $OU_Staging      -Comment "LAB staging quarantine policy"
Ensure-GPOWithLink -Name "GPO-LAB-DriveMapping"             -TargetDN $OU_Departments  -Comment "LAB department drive mapping"
Ensure-GPOWithLink -Name "GPO-LAB-Governance-DriveMapping"  -TargetDN $OU_Governance   -Comment "LAB governance drive mapping"
```

### 11.3 Esempi impostazioni registry-based

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

#### Timeout screen saver utenti Departments

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

#### Timeout screen saver utenti Governance

```powershell
Set-GPRegistryValue `
    -Name "GPO-LAB-Governance-Users" `
    -Key "HKCU\Software\Policies\Microsoft\Windows\Control Panel\Desktop" `
    -ValueName "ScreenSaveTimeOut" `
    -Type String `
    -Value "600"

Set-GPRegistryValue `
    -Name "GPO-LAB-Governance-Users" `
    -Key "HKCU\Software\Policies\Microsoft\Windows\Control Panel\Desktop" `
    -ValueName "ScreenSaverIsSecure" `
    -Type String `
    -Value "1"
```

---

## 12. Drive mapping via script PowerShell

### 12.1 Script Departments

```powershell
$ScriptsPath = "\\$DomainDNS\SYSVOL\$DomainDNS\scripts"
$MapScriptPath = Join-Path $ScriptsPath "Map-LABDrives.ps1"

$MapScript = @'
$Domain = $env:USERDOMAIN

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

# Share globale
New-PSDrive -Name "S" -PSProvider FileSystem -Root "\\SRV-FS-001\Shared" -Persist -ErrorAction SilentlyContinue | Out-Null

# Mappa reparto operativo
$DeptGroups = @("IT", "Finance", "HR", "Marketing", "Sales")
foreach ($Dept in $DeptGroups) {
    if (Test-GroupMembership -GroupName "GG_${Dept}_Users") {
        New-PSDrive -Name "H" -PSProvider FileSystem -Root "\\SRV-FS-001\Departments\$Dept\Internal" -Persist -ErrorAction SilentlyContinue | Out-Null
    }
}
'@

Set-Content -Path $MapScriptPath -Value $MapScript -Encoding UTF8
```

Collegamento tramite GPO:

```powershell
Set-GPRegistryValue `
    -Name "GPO-LAB-DriveMapping" `
    -Key "HKCU\Software\Microsoft\Windows\CurrentVersion\Run" `
    -ValueName "LABDriveMapping" `
    -Type String `
    -Value "powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -File `"\\$DomainDNS\SYSVOL\$DomainDNS\scripts\Map-LABDrives.ps1`""
```

### 12.2 Script Governance / Board

```powershell
$GovMapScriptPath = Join-Path $ScriptsPath "Map-LABGovernanceDrives.ps1"

$GovMapScript = @'
$Domain = $env:USERDOMAIN

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

# O: BoardOnly, solo membri Board
if (Test-GroupMembership -GroupName "GG_Board_Members") {
    New-PSDrive -Name "O" -PSProvider FileSystem -Root "\\SRV-FS-001\Governance\Board\BoardOnly" -Persist -ErrorAction SilentlyContinue | Out-Null
}

# G: BoardDirectors, Board + Directors
if ((Test-GroupMembership -GroupName "GG_Board_Members") -or (Test-GroupMembership -GroupName "GG_LAB_Directors")) {
    New-PSDrive -Name "G" -PSProvider FileSystem -Root "\\SRV-FS-001\Governance\Board\BoardDirectors" -Persist -ErrorAction SilentlyContinue | Out-Null
}
'@

Set-Content -Path $GovMapScriptPath -Value $GovMapScript -Encoding UTF8
```

Collegamento tramite GPO Governance:

```powershell
Set-GPRegistryValue `
    -Name "GPO-LAB-Governance-DriveMapping" `
    -Key "HKCU\Software\Microsoft\Windows\CurrentVersion\Run" `
    -ValueName "LABGovernanceDriveMapping" `
    -Type String `
    -Value "powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -File `"\\$DomainDNS\SYSVOL\$DomainDNS\scripts\Map-LABGovernanceDrives.ps1`""
```

---

## 13. Policy locali sui server: RDP group

```powershell
Invoke-Command -ComputerName "SRV-FS-001" -ScriptBlock {
    param($NetBIOS)
    Add-LocalGroupMember -Group "Remote Desktop Users" -Member "$NetBIOS\DL_RDP_SRV-FS-001_Admins" -ErrorAction SilentlyContinue
} -ArgumentList $NetBIOS

Invoke-Command -ComputerName "SRV-APP-001" -ScriptBlock {
    param($NetBIOS)
    Add-LocalGroupMember -Group "Remote Desktop Users" -Member "$NetBIOS\DL_RDP_SRV-APP-001_Admins" -ErrorAction SilentlyContinue
} -ArgumentList $NetBIOS

Invoke-Command -ComputerName "SRV-DB-001" -ScriptBlock {
    param($NetBIOS)
    Add-LocalGroupMember -Group "Remote Desktop Users" -Member "$NetBIOS\DL_RDP_SRV-DB-001_Admins" -ErrorAction SilentlyContinue
} -ArgumentList $NetBIOS
```

---

## 14. Auditing honey object

Monitorare almeno:

- logon riusciti/falliti di `admin.backup`;
- modifiche membership;
- reset password;
- abilitazione/disabilitazione account.

### 14.1 Verifica eventi recenti

```powershell
Get-WinEvent -FilterHashtable @{LogName='Security'; Id=4625; StartTime=(Get-Date).AddDays(-1)} |
    Where-Object { $_.Properties.Value -contains "admin.backup" } |
    Select-Object TimeCreated, Id, ProviderName, Message

Get-WinEvent -FilterHashtable @{LogName='Security'; Id=4624; StartTime=(Get-Date).AddDays(-1)} |
    Where-Object { $_.Properties.Value -contains "admin.backup" } |
    Select-Object TimeCreated, Id, ProviderName, Message

Get-WinEvent -FilterHashtable @{LogName='Security'; Id=4728,4732,4756; StartTime=(Get-Date).AddDays(-1)} |
    Where-Object { $_.Message -like "*admin.backup*" } |
    Select-Object TimeCreated, Id, ProviderName, Message
```

### 14.2 Scheduled task di alert locale semplificato

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
    Select-Object SamAccountName, Enabled, Description, DistinguishedName |
    Sort-Object SamAccountName
```

### 15.4 Verifica membership Governance

```powershell
Get-ADGroupMember "GG_Board_Members" | Select-Object Name, SamAccountName
Get-ADGroupMember "GG_LAB_Directors" | Select-Object Name, SamAccountName
Get-ADGroupMember "DL_FS_Governance_BoardOnly_MD" | Select-Object Name, SamAccountName, ObjectClass
Get-ADGroupMember "DL_FS_Governance_BoardDirectors_MD" | Select-Object Name, SamAccountName, ObjectClass
```

### 15.5 Verifica ACL Governance

```powershell
Invoke-Command -ComputerName $FileServerName -ScriptBlock {
    Get-Acl "D:\Shares\Governance\Board\BoardOnly" | Select-Object -ExpandProperty Access |
        Select-Object IdentityReference, FileSystemRights, AccessControlType, IsInherited

    Get-Acl "D:\Shares\Governance\Board\BoardDirectors" | Select-Object -ExpandProperty Access |
        Select-Object IdentityReference, FileSystemRights, AccessControlType, IsInherited
}
```

### 15.6 Verifica GPO linkate

```powershell
Get-GPInheritance -Target $OU_Computers
Get-GPInheritance -Target $OU_Departments
Get-GPInheritance -Target $OU_Governance
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
| BoardOnly da Board | `board.user01` | `\\SRV-FS-001\Governance\Board\BoardOnly` | Modify |
| BoardOnly da Director HR | `hr.user01` | `\\SRV-FS-001\Governance\Board\BoardOnly` | Access denied |
| BoardDirectors da Board | `board.user01` | `\\SRV-FS-001\Governance\Board\BoardDirectors` | Modify |
| BoardDirectors da Director HR | `hr.user01` | `\\SRV-FS-001\Governance\Board\BoardDirectors` | Modify |
| BoardDirectors da utente HR standard | `hr.user02` | `\\SRV-FS-001\Governance\Board\BoardDirectors` | Access denied |
| Governance da admin IT standard | `admin.it.user02` | `\\SRV-FS-001\Governance\Board\BoardOnly` | Access denied |
| Governance da break-glass | `super.user` | `\\SRV-FS-001\Governance\Board\BoardOnly` | Full Control |
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
    foreach ($Share in @("Departments", "Governance", "Shared")) {
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
Get-ADOrganizationalUnit -SearchBase $LabDN -Filter * | ForEach-Object {
    Set-ADOrganizationalUnit -Identity $_.DistinguishedName -ProtectedFromAccidentalDeletion $false
}
Set-ADOrganizationalUnit -Identity $LabDN -ProtectedFromAccidentalDeletion $false

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

### 18.2 Admin IT e aree riservate

Per `Confidential` e `Governance`, il modello preferito è **non concedere** accesso agli admin IT standard, invece di usare deny espliciti. I deny espliciti possono creare effetti collaterali difficili da diagnosticare.

### 18.3 Board e Directors

- `BoardOnly` è riservata a `GG_Board_Members`.
- `BoardDirectors` è condivisa tra `GG_Board_Members` e `GG_LAB_Directors`.
- `GG_LAB_Admins` non viene incluso per default nelle aree Governance.
- `GG_LAB_BreakGlass` mantiene Full Control per recovery.

### 18.4 Write-only / drop-box

Il permesso `WO` è implementato come ACL avanzata add-only. Per test didattici semplici, se il comportamento risultasse troppo restrittivo, sostituire temporaneamente `WO` con `Modify` e documentare la semplificazione.

### 18.5 GPO complesse

Le impostazioni registry-based sono automatizzabili con `Set-GPRegistryValue`. Alcune impostazioni, come User Rights Assignment, Restricted Groups o Advanced Audit Policy, possono richiedere GPMC, security template, backup/import GPO o strumenti dedicati.

---

## 19. Chiusura transcript

```powershell
Stop-Transcript
```
