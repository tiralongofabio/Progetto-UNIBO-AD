# ============================================================
# LAB Active Directory - 08e-Remediate-Root-Traverse-AGDLP.ps1
#
# Scopo:
# - Eliminare le ACE dirette GG_* dalle root di navigazione del file server
#   senza perdere gli accessi necessari al laboratorio.
# - Sostituire le ACE dirette GG_* con gruppi Domain Local dedicati.
# - Mantenere il modello AGDLP anche sui punti di attraversamento:
#       Utenti -> GG_* -> DL_* -> ACL NTFS
#
# Root corrette:
# - D:\aShares\aDepartments
# - D:\aShares\aGovernance
# - D:\aShares\aGovernance\aBoard
#
# Nota:
# - Non modifica le ACL operative di Public/Internal/Confidential.
# - Non crea reparti Legal/Operations: se il test li segnala mancanti,
#   sono falsi positivi rispetto al modello attuale IT/Finance/HR/Marketing/Sales.
#
# Da eseguire su DC01 come Domain Admin.
# ============================================================

$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "=== 08e - Remediation Root Traverse AGDLP ===" -ForegroundColor Cyan
Write-Host ""

Import-Module ActiveDirectory -ErrorAction Stop

$Domain    = Get-ADDomain
$DomainDN  = $Domain.DistinguishedName
$NetBIOS   = $Domain.NetBIOSName
$LabDN     = "OU=LAB,$DomainDN"
$GroupsOU  = "OU=Security,OU=Groups,$LabDN"

$FileServerName = "SRV-FS-001"

$RootDepartments = "D:\Shares\Departments"
$RootGovernance  = "D:\Shares\Governance"
$RootBoard       = "D:\Shares\Governance\Board"

# DL dedicate alle root di attraversamento/navigazione.
$GroupsToEnsure = @(
    @{ Name = "DL_FS_Departments_ROOT_RX";        Scope = "DomainLocal"; Description = "Read/traverse Departments root" },
    @{ Name = "DL_FS_Departments_ROOT_FC";        Scope = "DomainLocal"; Description = "Full control Departments root" },
    @{ Name = "DL_FS_Governance_ROOT_RX";         Scope = "DomainLocal"; Description = "Read/traverse Governance root" },
    @{ Name = "DL_FS_Governance_ROOT_FC";         Scope = "DomainLocal"; Description = "Full control Governance root" },
    @{ Name = "DL_FS_Governance_Board_ROOT_RX";   Scope = "DomainLocal"; Description = "Read/traverse Governance Board root" },
    @{ Name = "DL_FS_Governance_Board_ROOT_FC";   Scope = "DomainLocal"; Description = "Full control Governance Board root" }
)

function Ensure-ADGroupLocal {
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $Scope,
        [string] $Description
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
        Write-Host "[SKIP] Gruppo già presente: $Name" -ForegroundColor Yellow
    }
}

function Ensure-MemberLocal {
    param(
        [Parameter(Mandatory)] [string] $Group,
        [Parameter(Mandatory)] [string[]] $Members
    )

    foreach ($Member in $Members) {
        $Obj = Get-ADObject -LDAPFilter "(|(sAMAccountName=$Member)(name=$Member))" -ErrorAction SilentlyContinue
        if (-not $Obj) {
            Write-Warning "Oggetto mancante: $Member. Membership saltata su $Group."
            continue
        }

        $Exists = Get-ADGroupMember -Identity $Group -Recursive -ErrorAction Stop | Where-Object {
            $_.DistinguishedName -eq $Obj.DistinguishedName
        }

        if (-not $Exists) {
            Add-ADGroupMember -Identity $Group -Members $Obj.DistinguishedName
            Write-Host "[OK] Aggiunto $Member a $Group" -ForegroundColor Green
        }
        else {
            Write-Host "[SKIP] $Member già membro di $Group" -ForegroundColor Yellow
        }
    }
}

# ------------------------------------------------------------
# 1. Crea/assicura DL root
# ------------------------------------------------------------
foreach ($G in $GroupsToEnsure) {
    Ensure-ADGroupLocal -Name $G.Name -Path $GroupsOU -Scope $G.Scope -Description $G.Description
}

# ------------------------------------------------------------
# 2. Membership AGDLP per root traversal
# ------------------------------------------------------------
# Departments root: serve far attraversare/navigare ai gruppi che possono poi
# accedere a sottocartelle autorizzate. Admin/BreakGlass hanno FC sulla root.
Ensure-MemberLocal -Group "DL_FS_Departments_ROOT_RX" -Members @(
    "GG_LAB_AllUsers",
    "GG_LAB_Directors",
    "GG_Board_Members"
)
Ensure-MemberLocal -Group "DL_FS_Departments_ROOT_FC" -Members @(
    "GG_LAB_Admins",
    "GG_LAB_BreakGlass"
)

# Governance root: solo Board/Directors possono attraversare, Admin/BreakGlass FC.
Ensure-MemberLocal -Group "DL_FS_Governance_ROOT_RX" -Members @(
    "GG_LAB_Directors",
    "GG_Board_Members"
)
Ensure-MemberLocal -Group "DL_FS_Governance_ROOT_FC" -Members @(
    "GG_LAB_Admins",
    "GG_LAB_BreakGlass"
)

# Governance\Board root: Board/Directors attraversano, Admin/BreakGlass FC.
Ensure-MemberLocal -Group "DL_FS_Governance_Board_ROOT_RX" -Members @(
    "GG_LAB_Directors",
    "GG_Board_Members"
)
Ensure-MemberLocal -Group "DL_FS_Governance_Board_ROOT_FC" -Members @(
    "GG_LAB_Admins",
    "GG_LAB_BreakGlass"
)

# ------------------------------------------------------------
# 3. Remediation ACL root su SRV-FS-001
# ------------------------------------------------------------
if (-not (Test-WSMan -ComputerName $FileServerName -ErrorAction SilentlyContinue)) {
    throw "$FileServerName non raggiungibile via WinRM."
}

Invoke-Command -ComputerName $FileServerName -ArgumentList $NetBIOS,$RootDepartments,$RootGovernance,$RootBoard -ScriptBlock {
    param(
        [string] $NetBIOS,
        [string] $RootDepartments,
        [string] $RootGovernance,
        [string] $RootBoard
    )

    $ErrorActionPreference = "Stop"

    function Remove-DirectGGAces {
        param([Parameter(Mandatory)] [string] $Path)

        $Acl = Get-Acl -Path $Path
        $Acl.SetAccessRuleProtection($true, $false)

        foreach ($Ace in @($Acl.Access)) {
            $Identity = $Ace.IdentityReference.Value
            if ($Identity -like "$NetBIOS\GG_*") {
                [void]$Acl.RemoveAccessRule($Ace)
                Write-Host "[OK] Rimossa ACE diretta GG_* da $Path : $Identity" -ForegroundColor Green
            }
        }

        Set-Acl -Path $Path -AclObject $Acl
    }

    function Ensure-Ace {
        param(
            [Parameter(Mandatory)] [string] $Path,
            [Parameter(Mandatory)] [string] $Identity,
            [Parameter(Mandatory)] [System.Security.AccessControl.FileSystemRights] $Rights,
            [System.Security.AccessControl.InheritanceFlags] $InheritanceFlags = "None",
            [System.Security.AccessControl.PropagationFlags] $PropagationFlags = "None"
        )

        $Acl = Get-Acl -Path $Path
        $Existing = $Acl.Access | Where-Object {
            $_.IdentityReference.Value -ieq $Identity -and
            $_.FileSystemRights -eq $Rights -and
            $_.AccessControlType -eq "Allow" -and
            $_.InheritanceFlags -eq $InheritanceFlags -and
            $_.PropagationFlags -eq $PropagationFlags
        }

        if (-not $Existing) {
            $Rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                $Identity,
                $Rights,
                $InheritanceFlags,
                $PropagationFlags,
                "Allow"
            )
            $Acl.AddAccessRule($Rule)
            Set-Acl -Path $Path -AclObject $Acl
            Write-Host "[OK] Aggiunta ACE $Identity $Rights su $Path" -ForegroundColor Green
        }
        else {
            Write-Host "[SKIP] ACE già presente $Identity $Rights su $Path" -ForegroundColor Yellow
        }
    }

    function Ensure-SystemAdminBase {
        param([Parameter(Mandatory)] [string] $Path)
        Ensure-Ace -Path $Path -Identity "NT AUTHORITY\SYSTEM" -Rights FullControl
        Ensure-Ace -Path $Path -Identity "BUILTIN\Administrators" -Rights FullControl
    }

    foreach ($Path in @($RootDepartments, $RootGovernance, $RootBoard)) {
        if (-not (Test-Path $Path)) {
            throw "Path mancante: $Path"
        }
        Remove-DirectGGAces -Path $Path
        Ensure-SystemAdminBase -Path $Path
    }

    # Departments root
    Ensure-Ace -Path $RootDepartments -Identity "$NetBIOS\DL_FS_Departments_ROOT_RX" -Rights ReadAndExecute
    Ensure-Ace -Path $RootDepartments -Identity "$NetBIOS\DL_FS_Departments_ROOT_FC" -Rights FullControl

    # Governance root
    Ensure-Ace -Path $RootGovernance -Identity "$NetBIOS\DL_FS_Governance_ROOT_RX" -Rights ReadAndExecute
    Ensure-Ace -Path $RootGovernance -Identity "$NetBIOS\DL_FS_Governance_ROOT_FC" -Rights FullControl

    # Governance\Board root
    Ensure-Ace -Path $RootBoard -Identity "$NetBIOS\DL_FS_Governance_Board_ROOT_RX" -Rights ReadAndExecute
    Ensure-Ace -Path $RootBoard -Identity "$NetBIOS\DL_FS_Governance_Board_ROOT_FC" -Rights FullControl

    Write-Host "[OK] Remediation ACL root AGDLP completata su $env:COMPUTERNAME" -ForegroundColor Green
}

Write-Host ""
Write-Host "=== Riepilogo 08e ===" -ForegroundColor Cyan
Write-Host "Sostituite ACE dirette GG_* sulle root con DL dedicated root traversal."
Write-Host "Legal/Operations NON creati: trattarli come falsi positivi se non previsti dal modello LAB."
Write-Host "[OK] 08e completato." -ForegroundColor Green
