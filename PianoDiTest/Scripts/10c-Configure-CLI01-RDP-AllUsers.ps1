# ============================================================
# LAB Active Directory - 10c-Configure-CLI01-RDP-AllUsers.ps1
#
# Scopo:
# - Abilitare l'accesso RDP/Hyper-V Enhanced Session a CLI01
#   per tutti gli utenti standard del laboratorio.
# - Consentire i test interattivi con utenti dipartimentali, Board,
#   admin separati e altri account previsti, senza dover modificare
#   manualmente il gruppo locale "Remote Desktop Users".
#
# Cosa configura su CLI01:
# - Abilita Remote Desktop.
# - Abilita NLA.
# - Avvia e rende automatico il servizio TermService.
# - Aggiunge AD-LAB-DOMAIN\GG_LAB_AllUsers al gruppo locale
#   "Remote Desktop Users" usando il SID locale del gruppo, così
#   funziona anche su sistemi Windows in italiano.
# - Crea una regola firewall locale per consentire TCP/3389 dalla subnet lab.
#
# Cosa NON fa:
# - Non modifica i Domain Controllers.
# - Non rende gli utenti amministratori locali di CLI01.
# - Non modifica le GPO firewall di classe.
# - Non concede privilegi extra oltre al diritto di accesso RDP alla workstation.
#
# Da eseguire su DC01 come Domain Admin.
# Idempotente / rieseguibile.
# ============================================================

$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "=== 10c - Configurazione RDP su CLI01 per utenti LAB ===" -ForegroundColor Cyan
Write-Host ""

# ------------------------------------------------------------
# 0. Moduli e variabili base
# ------------------------------------------------------------
Import-Module ActiveDirectory -ErrorAction Stop

$Domain    = Get-ADDomain
$DomainDNS = $Domain.DNSRoot
$NetBIOS   = $Domain.NetBIOSName

$ClientName = "CLI01"
$LabSubnet  = "10.0.0.0/24"
$AllUsersGroup = "GG_LAB_AllUsers"
$DomainGroupToAdd = "$NetBIOS\$AllUsersGroup"

# SID built-in del gruppo locale "Remote Desktop Users".
# Usare il SID evita problemi di localizzazione, es. "Utenti desktop remoto".
$RemoteDesktopUsersSid = "S-1-5-32-555"

# ------------------------------------------------------------
# 1. Verifiche preliminari
# ------------------------------------------------------------
if (-not (Get-ADComputer -Identity $ClientName -ErrorAction SilentlyContinue)) {
    throw "Computer account non trovato in AD: $ClientName"
}

if (-not (Get-ADGroup -Identity $AllUsersGroup -ErrorAction SilentlyContinue)) {
    throw "Gruppo non trovato: $AllUsersGroup. Esegui prima 03-Create-LAB-Groups.ps1 e 05-Set-LAB-Memberships.ps1"
}

$WsmanOk = Test-WSMan -ComputerName $ClientName -ErrorAction SilentlyContinue
if (-not $WsmanOk) {
    throw "$ClientName non raggiungibile via WinRM. Accedi localmente a CLI01 e abilita WinRM con: Enable-PSRemoting -Force"
}

# ------------------------------------------------------------
# 2. Configurazione remota di CLI01
# ------------------------------------------------------------
Invoke-Command -ComputerName $ClientName -ArgumentList $DomainGroupToAdd, $RemoteDesktopUsersSid, $LabSubnet -ScriptBlock {
    param(
        [string] $DomainGroupToAdd,
        [string] $RemoteDesktopUsersSid,
        [string] $LabSubnet
    )

    $ErrorActionPreference = "Stop"

    Write-Host ""
    Write-Host "=== Configurazione locale RDP su $env:COMPUTERNAME ===" -ForegroundColor Cyan

    # Abilita Desktop Remoto.
    Set-ItemProperty `
        -Path "HKLM:\System\CurrentControlSet\Control\Terminal Server" `
        -Name "fDenyTSConnections" `
        -Value 0

    # Abilita Network Level Authentication.
    Set-ItemProperty `
        -Path "HKLM:\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" `
        -Name "UserAuthentication" `
        -Value 1

    # Avvia e rende automatico il servizio RDP.
    Set-Service -Name TermService -StartupType Automatic
    Start-Service -Name TermService -ErrorAction SilentlyContinue

    # Recupera il gruppo locale Remote Desktop Users tramite SID, indipendente dalla lingua OS.
    $RdpLocalGroup = Get-LocalGroup -SID $RemoteDesktopUsersSid -ErrorAction Stop

    $ExistingMembers = @(Get-LocalGroupMember -Group $RdpLocalGroup.Name -ErrorAction SilentlyContinue)
    $AlreadyPresent = $ExistingMembers | Where-Object {
        $_.Name -ieq $DomainGroupToAdd
    }

    if (-not $AlreadyPresent) {
        Add-LocalGroupMember -Group $RdpLocalGroup.Name -Member $DomainGroupToAdd
        Write-Host "[OK] Aggiunto $DomainGroupToAdd al gruppo locale $($RdpLocalGroup.Name)." -ForegroundColor Green
    }
    else {
        Write-Host "[SKIP] $DomainGroupToAdd già presente nel gruppo locale $($RdpLocalGroup.Name)." -ForegroundColor Yellow
    }

    # Regola firewall locale per RDP da rete lab.
    $RuleName = "LAB-CLI-Allow-RDP-3389-From-Lab"
    $ExistingRule = Get-NetFirewallRule -DisplayName $RuleName -ErrorAction SilentlyContinue

    if ($ExistingRule) {
        $ExistingRule | Remove-NetFirewallRule
        Write-Host "[UPDATE] Rimossa vecchia regola firewall: $RuleName" -ForegroundColor Yellow
    }

    New-NetFirewallRule `
        -DisplayName $RuleName `
        -Direction Inbound `
        -Action Allow `
        -Protocol TCP `
        -LocalPort 3389 `
        -RemoteAddress $LabSubnet `
        -Profile Any `
        -Description "Consente RDP/Hyper-V Enhanced Session verso CLI01 dalla subnet LAB" | Out-Null

    Write-Host "[OK] Regola firewall RDP creata: $RuleName" -ForegroundColor Green

    # Verifiche locali.
    Write-Host ""
    Write-Host "=== Verifiche locali ===" -ForegroundColor Cyan
    Get-Service TermService | Select-Object Name, Status, StartType | Format-Table -AutoSize
    Get-LocalGroupMember -Group $RdpLocalGroup.Name | Select-Object Name, ObjectClass, PrincipalSource | Format-Table -AutoSize
    Get-NetFirewallRule -DisplayName $RuleName | Select-Object DisplayName, Enabled, Direction, Action, Profile | Format-Table -AutoSize
}

# ------------------------------------------------------------
# 3. Verifiche da DC01
# ------------------------------------------------------------
Write-Host ""
Write-Host "=== Verifiche da DC01 ===" -ForegroundColor Cyan

Test-NetConnection -ComputerName $ClientName -Port 3389

Write-Host ""
Write-Host "[OK] 10c completato." -ForegroundColor Green
Write-Host ""
Write-Host "Prossimi test consigliati:" -ForegroundColor Cyan
Write-Host "1. Apri la console Hyper-V di CLI01 in Enhanced Session."
Write-Host "2. Prova login con AD-LAB-DOMAIN\hr.user01 oppure hr.user01@ad-lab-domain.local."
Write-Host "3. Se l'utente era appena stato modificato nei gruppi, usa una nuova sessione di logon."
