# Runbook aggiornato - Deploy e remediation LAB Active Directory

Dominio: `ad-lab-domain.local`  
Macchine principali:

- `DC01`: Domain Controller / DNS
- `CLI01`: workstation client di test
- `SRV-FS-001`: file server SMB con dati in `D:\Shares`

Questo runbook descrive il deploy corretto del laboratorio e integra le correzioni emerse durante i test:

- separazione OU `Departments` / `Governance`;
- modello AGDLP per file server;
- service account senza logon interattivo/RDP;
- admin separati come Domain Admins nel lab;
- RDP/Enhanced Session per utenti su `CLI01`;
- remediation definitiva di ACL/share/mapping drive;
- fix della GPO Drive Mapping considerata inizialmente “vuota”.

---

## Sequenza consigliata

Eseguire gli script da `DC01` come Domain Admin, da `C:\LAB-AD\Scripts`.

```text
.\Scripts\00-Init-LAB-Session.ps1
.\Scripts\01-Load-LAB-Helpers.ps1
.\Scripts\02-Create-LAB-OUs.ps1
.\Scripts\03-Create-LAB-Groups.ps1
.\Scripts\04-Create-LAB-Users.ps1
.\Scripts\05-Set-LAB-Memberships.ps1
.\Scripts\06-Place-Computer-Accounts.ps1
.\Scripts\07-Configure-LAB-Firewall-v2.1.ps1
.\Scripts\07b-Create-Firewall-GPOs.ps1
.\Scripts\08-Configure-FileServer.ps1
.\Scripts\08b-Remediate-FileServer-ACL-And-DriveMapping.ps1
.\Scripts\08c-Repair-DriveMapping-GPP-Metadata.ps1
.\Scripts\09-Configure-GPO-And-DriveMapping.ps1
.\Scripts\09b-Configure-UserClass-GPOs.ps1
.\Scripts\09c-Configure-ServiceAccount-Logon-Deny-GPO.ps1
.\Scripts\09d-Configure-DC-Admin-LocalLogon.ps1
.\Scripts\10-Configure-Server-Local-RDP.ps1
.\Scripts\10c-Configure-CLI01-RDP-AllUsers.ps1
.\Scripts\11-Configure-HoneyObject-Auditing.ps1
.\Scripts\12-Run-Basic-Checks.ps1
```

`08d-Configure-CLI01-DirectDriveMapping-LogonTask.ps1` è incluso solo come **fallback operativo** e non va eseguito nel deploy standard, perché il mapping corretto avviene tramite GPO Preferences.

---

## File server e modello AGDLP

Le share dati definitive sono:

```text
\\SRV-FS-001\Departments  -> D:\Shares\Departments
\\SRV-FS-001\Governance   -> D:\Shares\Governance
\\SRV-FS-001\Shared       -> D:\Shares\Shared
```

Non devono esistere share separate per `BoardOnly` e `BoardDirectors`; esse sono cartelle sotto:

```text
D:\Shares\Governance\Board\BoardOnly
D:\Shares\Governance\Board\BoardDirectors
```

Modello autorizzativo:

```text
Utenti -> GG_* -> DL_FS_* -> ACL NTFS
```

Lo script di remediation autoritativa è:

```text
.\Scripts\08b-Remediate-FileServer-ACL-And-DriveMapping.ps1
```

Corregge:

- struttura `D:\Shares`;
- share SMB;
- Access-Based Enumeration;
- ACL NTFS sulle root e sottocartelle;
- rimozione di drift/ACE dirette operative `GG_*` sulle aree dati;
- membership `GG_* -> DL_FS_*`;
- cartelle Governance `BoardOnly` / `BoardDirectors`;
- GPO Drive Mapping GPP.

---

## Drive mapping definitivo

La GPO ufficiale è:

```text
GPO-LAB-DriveMapping-GPP
```

linkata a:

```text
OU=LAB,DC=ad-lab-domain,DC=local
```

Mapping previsti:

```text
S: -> \\SRV-FS-001\Shared
H: -> \\SRV-FS-001\Departments\<Dipartimento>\Internal
O: -> \\SRV-FS-001\Governance\Board\BoardOnly
G: -> \\SRV-FS-001\Governance\Board\BoardDirectors
```

La remediation `08b` genera `Drives.xml` e aggiunge anche un marker registry innocuo:

```text
HKCU\Software\LAB-AD\DriveMappingGPP\Enabled = 1
```

Questo marker è importante: evita che Windows consideri la GPO `GPO-LAB-DriveMapping-GPP` come “Non applicato (vuoto)”. Durante il troubleshooting era esattamente la causa per cui i drive non venivano mappati pur essendo presente `Drives.xml`.

Se serve riallineare solo i metadati GPO, usare:

```text
.\Scripts\08c-Repair-DriveMapping-GPP-Metadata.ps1
```

---

## Test post-remediation

Dopo `08b` e `08c`:

1. su `CLI01` eseguire `gpupdate /force` con un admin;
2. fare logout;
3. rientrare come utente base, ad esempio `AD-LAB-DOMAIN\hr.user02`;
4. attendere 30-60 secondi;
5. verificare in “Questo PC”:

```text
S:
H:
```

Per `hr.user02` non devono comparire:

```text
O:
G:
```

Accessi attesi per `hr.user02`:

- può lavorare in `\\SRV-FS-001\Shared`;
- può lavorare in `\\SRV-FS-001\Departments\HR\Public`;
- può lavorare in `\\SRV-FS-001\Departments\HR\Internal`;
- non può accedere a `\\SRV-FS-001\Departments\HR\Confidential`.

---

## Service account

Lo script corretto è:

```text
.\Scripts\09c-Configure-ServiceAccount-Logon-Deny-GPO.ps1
```

Crea/assicura `GG_LAB_ServiceAccounts` e una GPO computer che nega ai service account:

```text
Deny log on locally
Deny log on through Remote Desktop Services
```

Non nega `Log on as a service`.

---

## Admin su Domain Controller

Lo script corretto è:

```text
.\Scripts\09d-Configure-DC-Admin-LocalLogon.ps1
```

Nel lab aggiunge:

```text
GG_LAB_Admins -> Domain Admins
```

e consente il logon locale/RDP ai DC.

---

## CLI01 e Hyper-V Enhanced Session

Per permettere i test interattivi con utenti non admin su `CLI01` usare:

```text
.\Scripts\10c-Configure-CLI01-RDP-AllUsers.ps1
```

Aggiunge `GG_LAB_AllUsers` al gruppo locale Remote Desktop Users di `CLI01` e abilita RDP/NLA.

---

## Diagnostica utile

Se i mapping non compaiono:

- verificare evento `5313` nel log `Microsoft-Windows-GroupPolicy/Operational`;
- se compare `GPO-LAB-DriveMapping-GPP - Non applicato (vuoto)`, rieseguire `08c` o verificare il marker registry nella GPO;
- verificare `Drives.xml` in SYSVOL;
- verificare che `Authenticated Users` abbia `GpoApply` sulla GPO;
- verificare che il client legga `Drives.xml` da `CLI01`.

Script fallback, non standard:

```text
.\Scripts\08d-Configure-CLI01-DirectDriveMapping-LogonTask.ps1
```

Usarlo solo se si vuole mappare localmente su `CLI01` tramite Scheduled Task al logon, bypassando temporaneamente GPP.
