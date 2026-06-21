<#
.SYNOPSIS
  Test-05.04 - Verifica membership del gruppo locale Remote Desktop Users / Utenti desktop remoto su un server.

.DESCRIPTION
  Versione corretta per sistemi localizzati.
  Non usa il nome localizzato del gruppo, ma il SID well-known S-1-5-32-555.
  Evita inoltre errori StrictMode quando la query remota fallisce o non ritorna oggetti validi.

  Esecuzione tipica da DC01:
    .\Scripts\Test-05.04.ps1 -Server 'SRV-FS-001'

.PARAMETER Server
  Server target da interrogare. Default: SRV-FS-001.

.PARAMETER ExpectedGroupPattern
  Pattern regex per identificare membership amministrativa attesa.
  Default: DL_.*RDP|GG_.*Admin|GG_LAB_Admins|GG_LAB_BreakGlass

.PARAMETER AllowEmpty
  Se specificato, non considera FAIL il gruppo RDP vuoto. Utile se RDP non deve essere abilitato.
#>

[CmdletBinding()]
param(
    [string]$Server = 'SRV-FS-001',
    [string]$ExpectedGroupPattern = 'DL_.*RDP|GG_.*Admin|GG_LAB_Admins|GG_LAB_BreakGlass',
    [switch]$AllowEmpty,
    [string]$OutputDir = '.\Esiti'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

$TestId = 'Test-05.04'
$ResolvedOutputDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDir)
if (-not (Test-Path -LiteralPath $ResolvedOutputDir)) {
    New-Item -ItemType Directory -Path $ResolvedOutputDir -Force | Out-Null
}

$OutFile = Join-Path $ResolvedOutputDir "$TestId.out"
Set-Content -Path $OutFile -Encoding UTF8 -Value @(
    "TestId=$TestId",
    "Started=$(Get-Date -Format o)",
    "LauncherComputer=$env:COMPUTERNAME",
    "LauncherUser=$env:USERDOMAIN\$env:USERNAME",
    "TargetServer=$Server",
    "ExpectedGroupPattern=$ExpectedGroupPattern",
    "AllowEmpty=$($AllowEmpty.IsPresent)",
    "---"
)

$script:Failed = $false
$script:Warnings = 0

function Write-TestLog {
    param(
        [string]$Message,
        [ValidateSet('INFO','PASS','WARN','FAIL','DATA')]
        [string]$Level = 'INFO'
    )

    $line = "{0} [{1}] {2}" -f (Get-Date -Format o), $Level, $Message
    Add-Content -Path $OutFile -Encoding UTF8 -Value $line
    Write-Host $line

    if ($Level -eq 'FAIL') { $script:Failed = $true }
    if ($Level -eq 'WARN') { $script:Warnings++ }
}

function Finish-Test {
    Add-Content -Path $OutFile -Encoding UTF8 -Value @(
        "---",
        "Warnings=$script:Warnings",
        "Completed=$(Get-Date -Format o)",
        "Result=$(if ($script:Failed) { 'FAIL' } else { 'PASS' })"
    )

    if ($script:Failed) { exit 1 } else { exit 0 }
}

$remoteBlock = {
    $rdpSid = 'S-1-5-32-555'
    $result = [ordered]@{
        ComputerName = $env:COMPUTERNAME
        User         = "$env:USERDOMAIN\$env:USERNAME"
        GroupSid     = $rdpSid
        GroupName    = $null
        Members      = @()
        Error        = $null
    }

    try {
        $group = Get-LocalGroup -SID $rdpSid -ErrorAction Stop
        $result.GroupName = $group.Name

        $members = @(Get-LocalGroupMember -SID $rdpSid -ErrorAction Stop |
            Select-Object Name,ObjectClass,PrincipalSource,SID)

        $result.Members = $members
    }
    catch {
        $result.Error = $_.Exception.Message
    }

    [pscustomobject]$result
}

try {
    Write-TestLog "Verifica gruppo locale RDP via SID S-1-5-32-555 su $Server" 'INFO'

    if ($Server -ieq $env:COMPUTERNAME -or $Server -ieq 'localhost' -or $Server -ieq '.') {
        $remoteResult = & $remoteBlock
    }
    else {
        $remoteResult = Invoke-Command -ComputerName $Server -ScriptBlock $remoteBlock -ErrorAction Stop
    }

    if ($null -eq $remoteResult) {
        Write-TestLog "Nessun risultato ottenuto da $Server" 'FAIL'
        Finish-Test
    }

    Write-TestLog "RemoteInspection=True" 'PASS'
    Write-TestLog "RemoteComputerName=$($remoteResult.ComputerName)" 'DATA'
    Write-TestLog "RemoteUser=$($remoteResult.User)" 'DATA'
    Write-TestLog "RdpGroupSid=$($remoteResult.GroupSid)" 'DATA'
    Write-TestLog "RdpGroupName=$($remoteResult.GroupName)" 'DATA'

    if ($remoteResult.Error) {
        Write-TestLog "Errore lettura gruppo RDP locale: $($remoteResult.Error)" 'FAIL'
        Finish-Test
    }

    $members = @($remoteResult.Members)

    if ($members.Count -eq 0) {
        if ($AllowEmpty) {
            Write-TestLog "Gruppo RDP locale vuoto; accettato per parametro -AllowEmpty" 'PASS'
        }
        else {
            Write-TestLog "Gruppo RDP locale vuoto: nessun gruppo amministrativo rilevato" 'FAIL'
        }
        Finish-Test
    }

    foreach ($m in $members) {
        $name = if ($m.PSObject.Properties['Name']) { $m.Name } else { '<Name non disponibile>' }
        $class = if ($m.PSObject.Properties['ObjectClass']) { $m.ObjectClass } else { '<ObjectClass non disponibile>' }
        $source = if ($m.PSObject.Properties['PrincipalSource']) { $m.PrincipalSource } else { '<PrincipalSource non disponibile>' }
        $sid = if ($m.PSObject.Properties['SID']) { $m.SID } else { '<SID non disponibile>' }

        Write-TestLog "RDPMember=$name; Class=$class; Source=$source; SID=$sid" 'DATA'
    }

    $expected = @($members | Where-Object {
        $_.PSObject.Properties['Name'] -and
        $_.Name -match $ExpectedGroupPattern
    })

    if ($expected.Count -gt 0) {
        foreach ($e in $expected) {
            Write-TestLog "Gruppo RDP atteso rilevato: $($e.Name)" 'PASS'
        }
    }
    else {
        Write-TestLog "Nessun membro RDP corrisponde al pattern atteso: $ExpectedGroupPattern" 'FAIL'
    }
}
catch {
    Write-TestLog "Errore generale Test-05.04 su $Server : $($_.Exception.Message)" 'FAIL'
}

Finish-Test
