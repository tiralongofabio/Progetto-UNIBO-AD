Import-Module ActiveDirectory

$BaseDN = "DC=ad-lab-domain,DC=local"
$RootOU = "OU=Departments,$BaseDN"
$RootPath = "C:\Shares"

Write-Host "=== INIZIO PULIZIA ===" -ForegroundColor Yellow

# -----------------------------
# 1. RIMOZIONE OU Departments
# -----------------------------
try {
    $ou = Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$RootOU'" -ErrorAction Stop

    if ($ou) {
        Write-Host "Trovata OU Departments"

        # Rimuove protezione da eliminazione (anche su figli)
        Write-Host "Rimuovo protezione da cancellazione..."

        Get-ADOrganizationalUnit -Filter * -SearchBase $RootOU -ErrorAction SilentlyContinue |
            ForEach-Object {
                try {
                    Set-ADOrganizationalUnit $_ -ProtectedFromAccidentalDeletion $false -ErrorAction SilentlyContinue
                } catch {}
            }

        # anche sulla root
        Set-ADOrganizationalUnit -Identity $ou -ProtectedFromAccidentalDeletion $false

        Write-Host "Elimino OU Departments e tutto il contenuto..."
        Remove-ADOrganizationalUnit -Identity $ou -Recursive -Confirm:$false

        Write-Host "OU Departments rimossa correttamente ✅" -ForegroundColor Green
    }
}
catch {
    Write-Host "OU Departments NON trovata (ok)" -ForegroundColor DarkYellow
}

# -----------------------------
# 2. RIMOZIONE SHARE SMB
# -----------------------------
Write-Host "Pulizia share SMB..."

$shares = Get-SmbShare | Where-Object { $_.Name -like "*_Share" }

if ($shares) {
    foreach ($s in $shares) {
        try {
            Write-Host "Rimuovo share $($s.Name)"
            Remove-SmbShare -Name $s.Name -Force -ErrorAction Stop
        }
        catch {
            Write-Host "Errore rimozione share $($s.Name)" -ForegroundColor Red
        }
    }
} else {
    Write-Host "Nessuna share da rimuovere (ok)"
}

# -----------------------------
# 3. RIMOZIONE CARTELLE
# -----------------------------
Write-Host "Pulizia filesystem..."

if (Test-Path $RootPath) {
    try {
        Remove-Item $RootPath -Recurse -Force -ErrorAction Stop
        Write-Host "Cartella $RootPath rimossa ✅" -ForegroundColor Green
    }
    catch {
        Write-Host "Errore rimozione cartelle" -ForegroundColor Red
    }
}
else {
    Write-Host "Cartella $RootPath non esiste (ok)"
}

Write-Host "=== PULIZIA COMPLETATA ===" -ForegroundColor Yellow