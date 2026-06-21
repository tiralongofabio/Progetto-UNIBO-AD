# ============================================================
# LAB Active Directory - 08b-Remediate-FileServer-ACL-And-DriveMapping.ps1
# Versione corretta e completa
#
# Scopo:
# - Correggere in modo idempotente struttura D:\Shares, share SMB, ACL NTFS,
#   membership AGDLP e drive mapping GPP.
# - Rimuovere drift e ACE dirette GG_* operative sulle aree dati gestite.
# - Ripristinare il modello:
#       Utenti -> GG_* -> DL_FS_* -> ACL NTFS
# - Creare mapping drive tramite Group Policy Preferences / Drives.xml.
#
# Correzioni incluse:
# - Fix definitivo $Letter: -> ${Letter}: nella generazione Drives.xml.
# - Import esplicito e robusto del modulo SmbShare nel blocco remoto.
# - Bootstrap del servizio LanmanServer prima di Get/New/Remove-SmbShare.
# - GPO Drive Mapping GPP con Drives.xml e CSE corretta.
#
# Da eseguire su DC01 come Domain Admin.
# Requisiti:
# - SRV-FS-001 acceso, joined al dominio, raggiungibile via WinRM.
# - OU, utenti e gruppi principali giÃ  creati.
# ============================================================

$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "=== 08b - Remediation File Server ACL + Drive Mapping ===" -ForegroundColor Cyan
Write-Host ""

Import-Module ActiveDirectory -ErrorAction Stop
Import-Module GroupPolicy -ErrorAction Stop

# ------------------------------------------------------------
# 0. Variabili lab
# ------------------------------------------------------------
$Domain    = Get-ADDomain
$DomainDN  = $Domain.DistinguishedName
$DomainDNS = $Domain.DNSRoot
$NetBIOS   = $Domain.NetBIOSName
$LabDN     = "OU=LAB,$DomainDN"

$Departments = @("IT", "Finance", "HR", "Marketing", "Sales")
$FileServerName = "SRV-FS-001"

$ShareRoot      = "D:\Shares"
$DeptRoot       = "$ShareRoot\Departments"
$GovernanceRoot = "$ShareRoot\Governance"
$BoardRoot      = "$GovernanceRoot\Board"
$BoardOnlyPath  = "$BoardRoot\BoardOnly"
$BoardDirPath   = "$BoardRoot\BoardDirectors"
$SharedRoot     = "$ShareRoot\Shared"

$DriveMapGpoName = "GPO-LAB-DriveMapping-GPP"

# ------------------------------------------------------------
# 1. Helper AD / GPO
# ------------------------------------------------------------
function Ensure-ADGroupMemberSafe {
    param(
        [Parameter(Mandatory)] [string] $Group,
        [Parameter(Mandatory)] [string[]] $Members
    )

    foreach ($Member in $Members) {
        $GroupObj = Get-ADGroup -Identity $Group -ErrorAction SilentlyContinue
        if (-not $GroupObj) {
            Write-Warning "Gruppo mancante: $Group. Membership saltata."
            continue
        }

        $Obj = Get-ADObject -LDAPFilter "(|(sAMAccountName=$Member)(name=$Member))" -ErrorAction SilentlyContinue
        if (-not $Obj) {
            Write-Warning "Oggetto mancante: $Member. Membership $Member -> $Group saltata."
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
            Write-Host "[SKIP] $Member giÃ  membro di $Group" -ForegroundColor Yellow
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
        Write-Host "[SKIP] GPO giÃ  presente: $Name" -ForegroundColor Yellow
    }

    $Link = (Get-GPInheritance -Target $TargetDN).GpoLinks | Where-Object DisplayName -eq $Name
    if (-not $Link) {
        New-GPLink -Name $Name -Target $TargetDN -LinkEnabled Yes | Out-Null
        Write-Host "[OK] Link GPO: $Name -> $TargetDN" -ForegroundColor Green
    }
    else {
        Set-GPLink -Name $Name -Target $TargetDN -LinkEnabled Yes | Out-Null
        Write-Host "[SKIP/UPDATE] Link GPO giÃ  presente: $Name -> $TargetDN" -ForegroundColor Yellow
    }

    return Get-GPO -Name $Name
}

function Get-GroupSidString {
    param([Parameter(Mandatory)] [string] $SamAccountName)
    $Group = Get-ADGroup -Identity $SamAccountName -ErrorAction Stop
    return $Group.SID.Value
}

function ConvertTo-XmlAttributeValue {
    param([Parameter(Mandatory)] [string] $Value)
    return [System.Security.SecurityElement]::Escape($Value)
}

function New-DriveXmlItem {
    param(
        [Parameter(Mandatory)] [string] $Letter,
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $Label,
        [string] $TargetGroupSam
    )

    $Guid = ([guid]::NewGuid()).ToString("B").ToUpper()
    $Changed = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")

    $EscPath  = ConvertTo-XmlAttributeValue -Value $Path
    $EscLabel = ConvertTo-XmlAttributeValue -Value $Label

    if ([string]::IsNullOrWhiteSpace($TargetGroupSam)) {
        return @"
  <Drive clsid="{935D1B74-9CB8-4e3c-9914-7DD559B7A417}" name="${Letter}:" status="${Letter}:" image="2" changed="$Changed" uid="$Guid">
    <Properties action="U" thisDrive="SHOW" allDrives="NOCHANGE" userName="" path="$EscPath" label="$EscLabel" persistent="1" useLetter="1" letter="$Letter" />
  </Drive>
"@
    }
    else {
        $Sid = Get-GroupSidString -SamAccountName $TargetGroupSam
        $GroupName = ConvertTo-XmlAttributeValue -Value "$NetBIOS\$TargetGroupSam"
        return @"
  <Drive clsid="{935D1B74-9CB8-4e3c-9914-7DD559B7A417}" name="${Letter}:" status="${Letter}:" image="2" changed="$Changed" uid="$Guid">
    <Properties action="U" thisDrive="SHOW" allDrives="NOCHANGE" userName="" path="$EscPath" label="$EscLabel" persistent="1" useLetter="1" letter="$Letter" />
    <Filters>
      <FilterGroup bool="AND" not="0" name="$GroupName" sid="$Sid" userContext="1" primaryGroup="0" localGroup="0" />
    </Filters>
  </Drive>
"@
    }
}

function Set-GpoPreferencesDriveCse {
    param(
        [Parameter(Mandatory)] [Guid] $GpoGuid,
        [Parameter(Mandatory)] [string] $DomainDN
    )

    # Group Policy Preferences Drive Maps CSE + Preferences snap-in/tool GUID.
    $Extension = "[{5794DAFD-BE60-433F-88A2-1A31939AC01F}{F3CCC681-B74C-4060-9F26-CD84525DCA2A}]"
    $GpoGuidString = $GpoGuid.ToString("B").ToUpper()
    $GpoAdPath = "CN=$GpoGuidString,CN=Policies,CN=System,$DomainDN"

    $Obj = Get-ADObject -Identity $GpoAdPath -Properties gPCUserExtensionNames
    $Current = [string]$Obj.gPCUserExtensionNames

    if ([string]::IsNullOrWhiteSpace($Current)) {
        Set-ADObject -Identity $GpoAdPath -Replace @{ gPCUserExtensionNames = $Extension }
        Write-Host "[OK] gPCUserExtensionNames impostato per GPP Drive Maps." -ForegroundColor Green
    }
    elseif ($Current -notlike "*5794DAFD-BE60-433F-88A2-1A31939AC01F*") {
        Set-ADObject -Identity $GpoAdPath -Replace @{ gPCUserExtensionNames = ($Current + $Extension) }
        Write-Host "[OK] GPP Drive Maps CSE aggiunta a gPCUserExtensionNames." -ForegroundColor Green
    }
    else {
        Write-Host "[SKIP] GPP Drive Maps CSE giÃ  presente." -ForegroundColor Yellow
    }
}

function Update-GptIniUserVersion {
    param([Parameter(Mandatory)] [string] $GptIniPath)

    if (-not (Test-Path $GptIniPath)) {
        @"
[General]
Version=0
"@ | Set-Content -Path $GptIniPath -Encoding ASCII
    }

    $Content = Get-Content -Path $GptIniPath -ErrorAction Stop
    $Line = $Content | Where-Object { $_ -match '^Version=' } | Select-Object -First 1
    if (-not $Line) {
        Add-Content -Path $GptIniPath -Value "Version=1"
        return
    }

    $Version = [int]($Line -replace '^Version=', '')
    $ComputerVersion = ($Version -shr 16) -band 0xFFFF
    $UserVersion = $Version -band 0xFFFF
    $UserVersion++
    $NewVersion = ($ComputerVersion -shl 16) -bor $UserVersion

    $NewContent = $Content | ForEach-Object {
        if ($_ -match '^Version=') { "Version=$NewVersion" } else { $_ }
    }
    Set-Content -Path $GptIniPath -Value $NewContent -Encoding ASCII
    Write-Host "[OK] gpt.ini aggiornato: UserVersion=$UserVersion, ComputerVersion=$ComputerVersion" -ForegroundColor Green
}

# ------------------------------------------------------------
# 2. Remediation membership AGDLP
# ------------------------------------------------------------
Write-Host ""
Write-Host "=== Remediation membership AGDLP ===" -ForegroundColor Cyan

# Shared collaborativa: gli utenti standard devono poter creare/modificare.
Ensure-ADGroupMemberSafe -Group "DL_FS_Shared_MD" -Members @("GG_LAB_AllUsers", "GG_Board_Members", "GG_LAB_Directors")
Ensure-ADGroupMemberSafe -Group "DL_FS_Shared_FC" -Members @("GG_LAB_Admins", "GG_LAB_BreakGlass")

foreach ($Dept in $Departments) {
    # Public e Internal collaborative per gli utenti del dipartimento.
    Ensure-ADGroupMemberSafe -Group "DL_FS_${Dept}_Public_MD" -Members @("GG_${Dept}_Users", "GG_${Dept}_Director")
    Ensure-ADGroupMemberSafe -Group "DL_FS_${Dept}_Internal_MD" -Members @("GG_${Dept}_Users", "GG_${Dept}_Director")

    # Confidential solo Director + Board + service account autorizzato, FC break-glass.
    Ensure-ADGroupMemberSafe -Group "DL_FS_${Dept}_Confidential_MD" -Members @("GG_${Dept}_Director", "GG_Board_Members", "GG_SecurityApp")
    Ensure-ADGroupMemberSafe -Group "DL_FS_${Dept}_Confidential_FC" -Members @("GG_LAB_BreakGlass")
}

Ensure-ADGroupMemberSafe -Group "DL_FS_Governance_BoardOnly_MD" -Members @("GG_Board_Members", "GG_SecurityApp")
Ensure-ADGroupMemberSafe -Group "DL_FS_Governance_BoardOnly_FC" -Members @("GG_LAB_BreakGlass")
Ensure-ADGroupMemberSafe -Group "DL_FS_Governance_BoardDirectors_MD" -Members @("GG_Board_Members", "GG_LAB_Directors", "GG_SecurityApp")
Ensure-ADGroupMemberSafe -Group "DL_FS_Governance_BoardDirectors_FC" -Members @("GG_LAB_BreakGlass")

# ------------------------------------------------------------
# 3. Remediation file server ACL e share SMB
# ------------------------------------------------------------
Write-Host ""
Write-Host "=== Remediation ACL e share SMB su $FileServerName ===" -ForegroundColor Cyan

$WsmanOk = Test-WSMan -ComputerName $FileServerName -ErrorAction SilentlyContinue
if (-not $WsmanOk) {
    throw "$FileServerName non raggiungibile via WinRM. Verificare che sia acceso e che WinRM sia abilitato."
}

Invoke-Command -ComputerName $FileServerName -ArgumentList `
    $ShareRoot, $DeptRoot, $GovernanceRoot, $BoardRoot, $BoardOnlyPath, $BoardDirPath, $SharedRoot, $Departments, $NetBIOS `
    -ScriptBlock {
        param($ShareRoot, $DeptRoot, $GovernanceRoot, $BoardRoot, $BoardOnlyPath, $BoardDirPath, $SharedRoot, $Departments, $NetBIOS)

        $ErrorActionPreference = "Stop"

        # Bootstrap modulo SMB su Windows Server / sessione remota.
        $MachinePsModulePath = [Environment]::GetEnvironmentVariable("PSModulePath", "Machine")
        $UserPsModulePath    = [Environment]::GetEnvironmentVariable("PSModulePath", "User")
        $env:PSModulePath = @($MachinePsModulePath, $UserPsModulePath, $env:PSModulePath) -join ";"

        Install-WindowsFeature FS-FileServer -IncludeManagementTools | Out-Null
        Set-Service -Name LanmanServer -StartupType Automatic
        Start-Service -Name LanmanServer -ErrorAction SilentlyContinue

        # BEGIN 08B SMB CULTURE FIX
        # Il modulo SmbShare puÃ² avere solo risorse en-US. Se la sessione remota
        # usa it-IT come CurrentUICulture, Import-LocalizedData cerca
        # SmbShare\it-IT\SmbLocalization.psd1 e fallisce.
        $EnUsCulture = [System.Globalization.CultureInfo]::GetCultureInfo("en-US")
        [System.Threading.Thread]::CurrentThread.CurrentCulture = $EnUsCulture
        [System.Threading.Thread]::CurrentThread.CurrentUICulture = $EnUsCulture
        # END 08B SMB CULTURE FIX
        $SmbShareModulePath = Join-Path $env:windir "System32\WindowsPowerShell\v1.0\Modules\SmbShare\SmbShare.psd1"
        if (Test-Path $SmbShareModulePath) {
            Import-Module $SmbShareModulePath -Force -ErrorAction Stop
        }
        else {
            Import-Module SmbShare -Force -ErrorAction Stop
        }

        if (-not (Get-Command Get-SmbShare -ErrorAction SilentlyContinue)) {
            throw "Get-SmbShare non disponibile dopo Import-Module SmbShare su $env:COMPUTERNAME."
        }

        function Reset-FolderAclLocal {
            param([Parameter(Mandatory)] [string] $Path)
            $Acl = Get-Acl -Path $Path
            $Acl.SetAccessRuleProtection($true, $false)
            foreach ($Ace in @($Acl.Access)) {
                [void]$Acl.RemoveAccessRule($Ace)
            }
            Set-Acl -Path $Path -AclObject $Acl
        }

        function Add-FolderAceLocal {
            param(
                [Parameter(Mandatory)] [string] $Path,
                [Parameter(Mandatory)] [string] $Identity,
                [Parameter(Mandatory)] [System.Security.AccessControl.FileSystemRights] $Rights,
                [System.Security.AccessControl.InheritanceFlags] $InheritanceFlags = "ContainerInherit, ObjectInherit",
                [System.Security.AccessControl.PropagationFlags] $PropagationFlags = "None"
            )
            $Acl = Get-Acl -Path $Path
            $Rule = New-Object System.Security.AccessControl.FileSystemAccessRule($Identity, $Rights, $InheritanceFlags, $PropagationFlags, "Allow")
            $Acl.AddAccessRule($Rule)
            Set-Acl -Path $Path -AclObject $Acl
        }

        function Set-BaseAclLocal {
            param([Parameter(Mandatory)] [string] $Path)
            Reset-FolderAclLocal -Path $Path
            Add-FolderAceLocal -Path $Path -Identity "BUILTIN\Administrators" -Rights FullControl
            Add-FolderAceLocal -Path $Path -Identity "NT AUTHORITY\SYSTEM" -Rights FullControl
        }

        foreach ($Folder in @($ShareRoot, $DeptRoot, $GovernanceRoot, $BoardRoot, $BoardOnlyPath, $BoardDirPath, $SharedRoot)) {
            New-Item -Path $Folder -ItemType Directory -Force | Out-Null
        }

        foreach ($Dept in $Departments) {
            foreach ($Sub in @("", "Public", "Internal", "Confidential")) {
                $Path = if ($Sub) { Join-Path (Join-Path $DeptRoot $Dept) $Sub } else { Join-Path $DeptRoot $Dept }
                New-Item -Path $Path -ItemType Directory -Force | Out-Null
            }
        }

        # Root tecniche.
        foreach ($Path in @($ShareRoot, $DeptRoot, $GovernanceRoot, $BoardRoot)) {
            Set-BaseAclLocal -Path $Path
        }

        # Traversal/listing controllato sulle root share.
        # Queste ACE GG_* sono limitate alle root e non ereditano: servono per arrivare
        # ai punti di ingresso e far lavorare ABE. I permessi operativi restano sui DL_FS_*.
        Add-FolderAceLocal -Path $DeptRoot -Identity "$NetBIOS\GG_LAB_AllUsers" -Rights ReadAndExecute -InheritanceFlags None -PropagationFlags None
        Add-FolderAceLocal -Path $DeptRoot -Identity "$NetBIOS\GG_Board_Members" -Rights ReadAndExecute -InheritanceFlags None -PropagationFlags None
        Add-FolderAceLocal -Path $DeptRoot -Identity "$NetBIOS\GG_LAB_Directors" -Rights ReadAndExecute -InheritanceFlags None -PropagationFlags None
        Add-FolderAceLocal -Path $DeptRoot -Identity "$NetBIOS\GG_LAB_Admins" -Rights FullControl -InheritanceFlags None -PropagationFlags None
        Add-FolderAceLocal -Path $DeptRoot -Identity "$NetBIOS\GG_LAB_BreakGlass" -Rights FullControl -InheritanceFlags None -PropagationFlags None

        Add-FolderAceLocal -Path $GovernanceRoot -Identity "$NetBIOS\GG_Board_Members" -Rights ReadAndExecute -InheritanceFlags None -PropagationFlags None
        Add-FolderAceLocal -Path $GovernanceRoot -Identity "$NetBIOS\GG_LAB_Directors" -Rights ReadAndExecute -InheritanceFlags None -PropagationFlags None
        Add-FolderAceLocal -Path $GovernanceRoot -Identity "$NetBIOS\GG_LAB_BreakGlass" -Rights FullControl -InheritanceFlags None -PropagationFlags None
        Add-FolderAceLocal -Path $BoardRoot -Identity "$NetBIOS\GG_Board_Members" -Rights ReadAndExecute -InheritanceFlags None -PropagationFlags None
        Add-FolderAceLocal -Path $BoardRoot -Identity "$NetBIOS\GG_LAB_Directors" -Rights ReadAndExecute -InheritanceFlags None -PropagationFlags None
        Add-FolderAceLocal -Path $BoardRoot -Identity "$NetBIOS\GG_LAB_BreakGlass" -Rights FullControl -InheritanceFlags None -PropagationFlags None

        # Shared collaborativa.
        Set-BaseAclLocal -Path $SharedRoot
        Add-FolderAceLocal -Path $SharedRoot -Identity "$NetBIOS\DL_FS_Shared_MD" -Rights Modify
        Add-FolderAceLocal -Path $SharedRoot -Identity "$NetBIOS\DL_FS_Shared_FC" -Rights FullControl

        foreach ($Dept in $Departments) {
            $DeptPath = Join-Path $DeptRoot $Dept
            $PublicPath = Join-Path $DeptPath "Public"
            $InternalPath = Join-Path $DeptPath "Internal"
            $ConfidentialPath = Join-Path $DeptPath "Confidential"

            Set-BaseAclLocal -Path $DeptPath
            Add-FolderAceLocal -Path $DeptPath -Identity "$NetBIOS\DL_FS_${Dept}_Public_MD" -Rights ReadAndExecute -InheritanceFlags None -PropagationFlags None
            Add-FolderAceLocal -Path $DeptPath -Identity "$NetBIOS\DL_FS_${Dept}_Public_RO" -Rights ReadAndExecute -InheritanceFlags None -PropagationFlags None
            Add-FolderAceLocal -Path $DeptPath -Identity "$NetBIOS\DL_FS_${Dept}_Internal_MD" -Rights ReadAndExecute -InheritanceFlags None -PropagationFlags None
            Add-FolderAceLocal -Path $DeptPath -Identity "$NetBIOS\DL_FS_${Dept}_Confidential_MD" -Rights ReadAndExecute -InheritanceFlags None -PropagationFlags None
            Add-FolderAceLocal -Path $DeptPath -Identity "$NetBIOS\DL_FS_${Dept}_Public_FC" -Rights FullControl -InheritanceFlags None -PropagationFlags None
            Add-FolderAceLocal -Path $DeptPath -Identity "$NetBIOS\DL_FS_${Dept}_Internal_FC" -Rights FullControl -InheritanceFlags None -PropagationFlags None
            Add-FolderAceLocal -Path $DeptPath -Identity "$NetBIOS\DL_FS_${Dept}_Confidential_FC" -Rights FullControl -InheritanceFlags None -PropagationFlags None

            Set-BaseAclLocal -Path $PublicPath
            Add-FolderAceLocal -Path $PublicPath -Identity "$NetBIOS\DL_FS_${Dept}_Public_MD" -Rights Modify
            Add-FolderAceLocal -Path $PublicPath -Identity "$NetBIOS\DL_FS_${Dept}_Public_RO" -Rights ReadAndExecute
            Add-FolderAceLocal -Path $PublicPath -Identity "$NetBIOS\DL_FS_${Dept}_Public_WO" -Rights "CreateFiles, AppendData, ReadAttributes, ReadPermissions, Synchronize" -InheritanceFlags None -PropagationFlags None
            Add-FolderAceLocal -Path $PublicPath -Identity "$NetBIOS\DL_FS_${Dept}_Public_FC" -Rights FullControl

            Set-BaseAclLocal -Path $InternalPath
            Add-FolderAceLocal -Path $InternalPath -Identity "$NetBIOS\DL_FS_${Dept}_Internal_MD" -Rights Modify
            Add-FolderAceLocal -Path $InternalPath -Identity "$NetBIOS\DL_FS_${Dept}_Internal_FC" -Rights FullControl

            Set-BaseAclLocal -Path $ConfidentialPath
            Add-FolderAceLocal -Path $ConfidentialPath -Identity "$NetBIOS\DL_FS_${Dept}_Confidential_MD" -Rights Modify
            Add-FolderAceLocal -Path $ConfidentialPath -Identity "$NetBIOS\DL_FS_${Dept}_Confidential_FC" -Rights FullControl
        }

        # Governance / Board.
        Set-BaseAclLocal -Path $BoardOnlyPath
        Add-FolderAceLocal -Path $BoardOnlyPath -Identity "$NetBIOS\DL_FS_Governance_BoardOnly_MD" -Rights Modify
        Add-FolderAceLocal -Path $BoardOnlyPath -Identity "$NetBIOS\DL_FS_Governance_BoardOnly_FC" -Rights FullControl

        Set-BaseAclLocal -Path $BoardDirPath
        Add-FolderAceLocal -Path $BoardDirPath -Identity "$NetBIOS\DL_FS_Governance_BoardDirectors_MD" -Rights Modify
        Add-FolderAceLocal -Path $BoardDirPath -Identity "$NetBIOS\DL_FS_Governance_BoardDirectors_FC" -Rights FullControl

        # Share SMB: ampie abbastanza per arrivare alla share, granularitÃ  su NTFS.
        foreach ($Share in @("Departments", "Governance", "Shared")) {
            if (Get-SmbShare -Name $Share -ErrorAction SilentlyContinue) {
                Remove-SmbShare -Name $Share -Force
            }
        }

        New-SmbShare -Name "Departments" -Path $DeptRoot `
            -FullAccess "BUILTIN\Administrators", "$NetBIOS\GG_LAB_BreakGlass", "$NetBIOS\GG_LAB_Admins" `
            -ChangeAccess "$NetBIOS\GG_LAB_AllUsers", "$NetBIOS\GG_Board_Members", "$NetBIOS\GG_LAB_Directors" `
            -FolderEnumerationMode AccessBased `
            -CachingMode None | Out-Null

        New-SmbShare -Name "Governance" -Path $GovernanceRoot `
            -FullAccess "BUILTIN\Administrators", "$NetBIOS\GG_LAB_BreakGlass", "$NetBIOS\GG_LAB_Admins" `
            -ChangeAccess "$NetBIOS\GG_Board_Members", "$NetBIOS\GG_LAB_Directors" `
            -FolderEnumerationMode AccessBased `
            -CachingMode None | Out-Null

        New-SmbShare -Name "Shared" -Path $SharedRoot `
            -FullAccess "BUILTIN\Administrators", "$NetBIOS\GG_LAB_BreakGlass", "$NetBIOS\GG_LAB_Admins" `
            -ChangeAccess "$NetBIOS\GG_LAB_AllUsers", "$NetBIOS\GG_Board_Members", "$NetBIOS\GG_LAB_Directors" `
            -FolderEnumerationMode AccessBased `
            -CachingMode None | Out-Null

        Write-Host "[OK] ACL e share SMB corrette su $env:COMPUTERNAME" -ForegroundColor Green
    }

# ------------------------------------------------------------
# 4. Remediation Drive Mapping: GPP Drives.xml
# ------------------------------------------------------------
Write-Host ""
Write-Host "=== Remediation GPO Drive Mapping GPP ===" -ForegroundColor Cyan

$DriveMapGpo = Ensure-GPOWithLinkLocal -Name $DriveMapGpoName -TargetDN $LabDN -Comment "GPP drive mappings for LAB users"

$Items = @()

# S: Shared per tutti gli utenti sotto OU=LAB.
$Items += New-DriveXmlItem -Letter "S" -Path "\\SRV-FS-001\Shared" -Label "LAB Shared"

# H: Department Internal, target per gruppo dipartimentale.
foreach ($Dept in $Departments) {
    $Items += New-DriveXmlItem -Letter "H" -Path "\\SRV-FS-001\Departments\$Dept\Internal" -Label "$Dept Internal" -TargetGroupSam "GG_${Dept}_Users"
}

# O: BoardOnly per Board.
$Items += New-DriveXmlItem -Letter "O" -Path "\\SRV-FS-001\Governance\Board\BoardOnly" -Label "Board Only" -TargetGroupSam "GG_Board_Members"

# G: BoardDirectors per Board e Directors.
$Items += New-DriveXmlItem -Letter "G" -Path "\\SRV-FS-001\Governance\Board\BoardDirectors" -Label "Board Directors" -TargetGroupSam "GG_Board_Members"
$Items += New-DriveXmlItem -Letter "G" -Path "\\SRV-FS-001\Governance\Board\BoardDirectors" -Label "Board Directors" -TargetGroupSam "GG_LAB_Directors"

$GpoGuid = $DriveMapGpo.Id
$GpoGuidString = $GpoGuid.ToString("B").ToUpper()
$GpoSysvolPath = "\\$DomainDNS\SYSVOL\$DomainDNS\Policies\$GpoGuidString"
$DrivesDir = Join-Path $GpoSysvolPath "User\Preferences\Drives"
$DrivesXmlPath = Join-Path $DrivesDir "Drives.xml"
$GptIniPath = Join-Path $GpoSysvolPath "gpt.ini"

New-Item -Path $DrivesDir -ItemType Directory -Force | Out-Null

$Xml = @"
<?xml version="1.0" encoding="utf-8"?>
<Drives clsid="{8FDDCC1A-0C3C-43cd-A6B4-71A6DF20DA8C}">
$($Items -join "`r`n")
</Drives>
"@

Set-Content -Path $DrivesXmlPath -Value $Xml -Encoding UTF8
Write-Host "[OK] Drives.xml scritto: $DrivesXmlPath" -ForegroundColor Green

Set-GpoPreferencesDriveCse -GpoGuid $GpoGuid -DomainDN $DomainDN
Update-GptIniUserVersion -GptIniPath $GptIniPath

# Disabilita i vecchi mapping via Run registry, se presenti, per evitare conflitti.
foreach ($OldGpo in @("GPO-LAB-DriveMapping", "GPO-LAB-Governance-DriveMapping")) {
    if (Get-GPO -Name $OldGpo -ErrorAction SilentlyContinue) {
        Remove-GPRegistryValue -Name $OldGpo -Key "HKCU\Software\Microsoft\Windows\CurrentVersion\Run" -ValueName "LABDriveMapping" -ErrorAction SilentlyContinue
        Remove-GPRegistryValue -Name $OldGpo -Key "HKCU\Software\Microsoft\Windows\CurrentVersion\Run" -ValueName "LABGovernanceDriveMapping" -ErrorAction SilentlyContinue
        Write-Host "[OK] Rimossi eventuali vecchi Run mapping da $OldGpo" -ForegroundColor Green
    }
}

# ------------------------------------------------------------
# 5. Riepilogo e quick checks
# ------------------------------------------------------------
Write-Host ""
Write-Host "=== Riepilogo remediation ===" -ForegroundColor Cyan
Write-Host "Share corrette su SRV-FS-001: Departments, Governance, Shared"
Write-Host "Cartelle Governance corrette: BoardOnly, BoardDirectors"
Write-Host "Modello AGDLP ripristinato su ACL NTFS"
Write-Host "Drive mapping GPP creato in: $DrivesXmlPath"
Write-Host ""
Write-Host "[OK] 08b remediation completata." -ForegroundColor Green
Write-Host ""
Write-Host "Prossimi step consigliati:" -ForegroundColor Cyan
Write-Host "1. gpupdate /force su CLI01."
Write-Host "2. Logout/login dell'utente di test, oppure nuova sessione RDP/Enhanced Session."
Write-Host "3. Verifica gpresult /h C:\Temp\gpresult-drivemaps.html."

