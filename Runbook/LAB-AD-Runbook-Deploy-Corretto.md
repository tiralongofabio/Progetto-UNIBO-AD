# Runbook operativo corretto - Deploy LAB Active Directory

## 1. Scopo del runbook

Questo runbook descrive il deploy corretto del laboratorio Active Directory `ad-lab-domain.local`, senza riportare al suo interno i comandi implementati dagli script PowerShell.

Per ogni fase operativa viene indicato lo script di riferimento da eseguire o consultare.

Il laboratorio è progettato per gestire:

- Domain Controller;
- workstation client;
- file server;
- futuri application server;
- futuri database server;
- utenti dipartimentali;
- utenti Board/Governance;
- account amministrativi separati;
- account break-glass;
- honey-object;
- service account;
- GPO per classi di computer e classi di utenti;
- ACL e share SMB secondo modello AGDLP.

---

## 2. Topologia di riferimento

Macchine attualmente previste:

| Nome | Ruolo | IP previsto | Note |
|---|---|---:|---|
| `DC01` | Domain Controller / DNS | `10.0.0.1` | Controller del dominio `ad-lab-domain.local` |
| `CLI01` | Workstation di test | `10.0.0.100` | Client per test utenti, GPO, share e accessi |
| `SRV-FS-001` | File Server | `10.0.0.30` | File server SMB del laboratorio |

Macchine future già predisposte nel modello AD:

| Nome previsto | Classe | OU di destinazione |
|---|---|---|
| `SRV-APP-001` | Application Server | `OU=AppServers,OU=Servers,OU=Computers,OU=LAB,...` |
| `SRV-DB-001` | Database Server | `OU=DBServers,OU=Servers,OU=Computers,OU=LAB,...` |
| nuovi file server | File Server | `OU=FileServers,OU=Servers,OU=Computers,OU=LAB,...` |
| nuove workstation | Workstation | `OU=Workstations,OU=Computers,OU=LAB,...` |

---

## 3. Prerequisiti infrastrutturali

Prima di avviare il deploy logico Active Directory, verificare che:

- `DC01`, `CLI01` e `SRV-FS-001` siano collegate allo stesso virtual switch Hyper-V del laboratorio;
- `DC01` sia operativo come Domain Controller e DNS;
- `CLI01` e `SRV-FS-001` siano joined al dominio;
- `SRV-FS-001` abbia il disco dati `D:` disponibile;
- su `SRV-FS-001` sia possibile raggiungere WinRM e SMB dopo il bootstrap firewall;
- gli script siano copiati su `DC01`, preferibilmente in `C:\LAB-AD\Scripts`.

La copia degli script dall'host Hyper-V alla VM può essere effettuata con PowerShell Direct, Enhanced Session o copia manuale, a seconda dello stato della rete e delle Integration Services.

---

## 4. Convenzioni del runbook

Gli script sono progettati per essere **idempotenti**: possono essere rieseguiti senza duplicare oggetti già esistenti.

Il runbook separa:

- configurazione Active Directory;
- configurazione firewall locale/bootstrap;
- configurazione firewall via GPO;
- configurazione file server;
- configurazione GPO utente;
- configurazione service account;
- verifiche finali.

Quando un server futuro non esiste ancora, le relative istruzioni rimangono predisposte negli script ma commentate o non operative fino alla creazione del computer account.

---

## 5. Sequenza generale di deploy

La sequenza corretta di deploy è la seguente:

1. inizializzazione ambiente PowerShell;
2. caricamento funzioni helper;
3. creazione OU;
4. creazione gruppi;
5. creazione utenti, admin, break-glass, honey-object e service account;
6. assegnazione membership;
7. posizionamento computer account nelle OU corrette;
8. bootstrap firewall sulle macchine esistenti;
9. creazione GPO firewall per classi di computer;
10. configurazione file server, share e ACL;
11. configurazione GPO generali e drive mapping;
12. configurazione RDP locale sui server;
13. configurazione GPO utente per classi di utenti;
14. configurazione deny logon per service account;
15. configurazione honey-object auditing;
16. verifiche finali.

---

## 6. Inizializzazione ambiente

La sessione PowerShell su `DC01` deve caricare variabili globali del laboratorio, riferimenti al dominio, percorsi, password di laboratorio e moduli necessari.

Script:

[.\Scripts\00-Init-LAB-Session.ps1](./Scripts/00-Init-LAB-Session.ps1)

Questo script inizializza il contesto operativo usato dagli script successivi.

---

## 7. Caricamento funzioni helper

Le funzioni helper sono usate per rendere idempotenti le operazioni di creazione di OU, gruppi, utenti, membership, GPO e ACL.

Script:

[.\Scripts\01-Load-LAB-Helpers.ps1](./Scripts/01-Load-LAB-Helpers.ps1)

Le funzioni helper devono essere disponibili nella sessione quando si eseguono gli script che le richiedono.

---

## 8. Creazione struttura OU

La struttura OU crea il perimetro logico del laboratorio:

- `OU=LAB`;
- `OU=Departments`;
- `OU=Governance`;
- `OU=Admins`;
- `OU=Groups`;
- `OU=ServiceAccounts`;
- `OU=Computers`;
- OU per dipartimenti;
- OU per Board;
- OU per admin separati, break-glass e honey-object;
- OU per workstation, staging e classi server.

Script:

[.\Scripts\02-Create-LAB-OUs.ps1](./Scripts/02-Create-LAB-OUs.ps1)

Questa fase è necessaria prima della creazione di gruppi, utenti, GPO e posizionamento dei computer account.

---

## 9. Creazione gruppi AD

La fase gruppi implementa il modello AGDLP del laboratorio.

Sono creati gruppi per:

- utenti globali del laboratorio;
- Directors;
- Board;
- admin separati;
- break-glass;
- honey-object;
- service account;
- utenti e Director di ogni dipartimento;
- ACL file server;
- RDP amministrativo;
- classi server future.

Script:

[.\Scripts\03-Create-LAB-Groups.ps1](./Scripts/03-Create-LAB-Groups.ps1)

Il modello distingue gruppi `GG_*` per identità/ruolo e gruppi `DL_*` per autorizzazioni sulle risorse.

---

## 10. Creazione utenti, admin, break-glass, honey-object e service account

La fase utenti crea:

- 4 utenti per ogni dipartimento operativo;
- 4 utenti Board;
- 4 account admin separati;
- account break-glass `super.user`;
- honey-object `admin.backup`;
- service account `svc.securityapp`.

Script:

[.\Scripts\04-Create-LAB-Users.ps1](./Scripts/04-Create-LAB-Users.ps1)

Gli account amministrativi sono separati dagli account utente standard. Il break-glass è pensato per scenari di recovery. L'honey-object è un account esca da monitorare. I service account non sono destinati a logon interattivo.

---

## 11. Membership AD

La fase membership collega utenti e gruppi secondo il modello AGDLP.

Esempi logici:

- utenti dipartimentali nei relativi `GG_<Dept>_Users`;
- Director nei gruppi `GG_<Dept>_Director` e `GG_LAB_Directors`;
- Board in `GG_Board_Members`;
- admin separati in `GG_LAB_Admins`;
- break-glass in `GG_LAB_BreakGlass`;
- service account nei gruppi dedicati;
- gruppi globali inseriti nei gruppi domain local per ACL file server e RDP.

Script:

[.\Scripts\05-Set-LAB-Memberships.ps1](./Scripts/05-Set-LAB-Memberships.ps1)

Questa fase deve essere rilanciata dopo eventuali aggiunte di utenti, service account o gruppi.

---

## 12. Posizionamento computer account

I computer account devono essere collocati nelle OU corrette per ricevere le GPO di classe.

Destinazioni principali:

- `CLI01` in `OU=Workstations`;
- `SRV-FS-001` in `OU=FileServers`;
- futuri `SRV-APP-*` in `OU=AppServers`;
- futuri `SRV-DB-*` in `OU=DBServers`.

Script:

[.\Scripts\06-Place-Computer-Accounts.ps1](./Scripts/06-Place-Computer-Accounts.ps1)

`DC01` resta nella OU predefinita `Domain Controllers`.

---

## 13. Bootstrap firewall sulle macchine esistenti

Questa fase applica regole firewall locali alle macchine già esistenti, in particolare `DC01` e `SRV-FS-001`, per garantire:

- DNS e servizi AD minimi su `DC01`;
- SMB, WinRM e RDP controllato su `SRV-FS-001`;
- inbound default bloccato;
- RDP limitato a sorgenti amministrative.

Script finale corretto:

[.\Scripts\07-Configure-LAB-Firewall-v2.1.ps1](./Scripts/07-Configure-LAB-Firewall-v2.1.ps1)

Questa fase è di bootstrap operativo e non sostituisce le GPO firewall di classe.

---

## 14. GPO firewall per classi di computer

Le regole firewall definitive e scalabili sono definite tramite GPO collegate alle OU di classe.

GPO previste:

- `GPO-LAB-DomainControllers-Firewall`;
- `GPO-LAB-Workstations-Firewall`;
- `GPO-LAB-FileServers-Firewall`;
- `GPO-LAB-AppServers-Firewall`;
- `GPO-LAB-DBServers-Firewall`;
- `GPO-LAB-Staging-Firewall`.

Script:

[.\Scripts\07b-Create-Firewall-GPOs.ps1](./Scripts/07b-Create-Firewall-GPOs.ps1)

Le nuove macchine erediteranno automaticamente la baseline firewall della propria classe dopo essere state spostate nella OU corretta.

Documentazione di riferimento:

[.\Docs\Descrizione-Regole-Firewall-LAB-AD.md](./Docs/Descrizione-Regole-Firewall-LAB-AD.md)

---

## 15. Configurazione file server, share e ACL

Questa fase configura `SRV-FS-001` come file server del laboratorio.

Vengono create:

- struttura `D:\Shares`;
- area `Departments`;
- area `Governance`;
- area `Shared`;
- share SMB;
- ACL NTFS secondo modello AGDLP.

Script:

[.\Scripts\08-Configure-FileServer.ps1](./Scripts/08-Configure-FileServer.ps1)

Documentazione di riferimento:

[.\Docs\Sintesi-ACL-Condivisioni-Rete-LAB-AD.md](./Docs/Sintesi-ACL-Condivisioni-Rete-LAB-AD.md)

---

## 16. GPO generali e drive mapping

Questa fase crea e collega GPO generali per:

- baseline computer;
- baseline utenti;
- hardening workstation;
- hardening server;
- hardening file server;
- predisposizione app server e DB server;
- drive mapping dipartimentale;
- drive mapping Governance.

Script:

[.\Scripts\09-Configure-GPO-And-DriveMapping.ps1](./Scripts/09-Configure-GPO-And-DriveMapping.ps1)

I mapping principali previsti sono:

- `S:` per area `Shared`;
- `H:` per area dipartimentale;
- `O:` per BoardOnly;
- `G:` per BoardDirectors.

---

## 17. GPO per classi di utenti

Questa fase differenzia l'ambiente utente in base a dipartimento, ruolo e tipo account.

Sono previste policy per:

- utenti base di ogni dipartimento;
- Director di ogni dipartimento;
- Governance/Board;
- admin separati;
- break-glass;
- honey-object;
- service account, solo come fallback dimostrativo.

Funzionalità principali:

- wallpaper diversi per dipartimento e ruolo;
- USB disabilitata per utenti base e non admin;
- USB attiva per admin e break-glass;
- blocco software non autorizzato per non admin;
- password più complesse per admin e Board tramite FGPP.

Script:

[.\Scripts\09b-Configure-UserClass-GPOs.ps1](./Scripts/09b-Configure-UserClass-GPOs.ps1)

Documentazione di riferimento:

[.\Docs\Descrizione-GPO-Classi-Utenti-LAB-AD.md](./Docs/Descrizione-GPO-Classi-Utenti-LAB-AD.md)

---

## 18. Deny logon per service account

I service account non devono essere utilizzati per logon interattivo.

Questa fase crea o assicura:

- gruppo `GG_LAB_ServiceAccounts`;
- membership dei service account;
- GPO computer dedicata per negare:
  - logon interattivo locale;
  - logon tramite Remote Desktop Services.

Script:

[.\Scripts\09c-Configure-ServiceAccount-Logon-Deny-GPO.ps1](./Scripts/09c-Configure-ServiceAccount-Logon-Deny-GPO.ps1)

La GPO viene linkata alla OU `Computers` del laboratorio, così si applica a workstation, server e classi future sotto `OU=LAB`.

Non viene negato `Log on as a service`, perché alcuni service account potrebbero dover essere usati da servizi Windows.

---

## 19. Configurazione RDP locale sui server

Questa fase aggiunge i gruppi domain local RDP ai gruppi locali `Remote Desktop Users` dei server membri.

Macchine attualmente operative:

- `SRV-FS-001`.

Macchine future predisposte:

- `SRV-APP-001`;
- `SRV-DB-001`.

Script:

[.\Scripts\10-Configure-Server-Local-RDP.ps1](./Scripts/10-Configure-Server-Local-RDP.ps1)

Le istruzioni per server futuri restano predisposte ma non operative finché le macchine non sono create e joined al dominio.

---

## 20. Honey-object auditing

Questa fase configura un monitoraggio base per l'honey-object.

Account interessato:

- `admin.backup`.

Script:

[.\Scripts\11-Configure-HoneyObject-Auditing.ps1](./Scripts/11-Configure-HoneyObject-Auditing.ps1)

Lo scopo è predisporre un controllo dimostrativo sugli eventi di uso anomalo dell'account esca.

---

## 21. Verifiche finali

La fase finale esegue controlli sintetici su:

- dominio;
- DNS;
- OU;
- gruppi;
- utenti;
- file server;
- share SMB;
- GPO.

Script:

[.\Scripts\12-Run-Basic-Checks.ps1](./Scripts/12-Run-Basic-Checks.ps1)

Le verifiche puntuali di sicurezza, ACL, GPO risultanti, logon negato e accessi effettivi possono essere eseguite successivamente con account campione.

---

## 22. Documentazione prodotta

La documentazione di supporto del laboratorio include:

- regole firewall locali e GPO firewall;
- ACL e share SMB;
- GPO per classi di utenti.

Documenti:

[.\Docs\Descrizione-Regole-Firewall-LAB-AD.md](./Docs/Descrizione-Regole-Firewall-LAB-AD.md)

[.\Docs\Sintesi-ACL-Condivisioni-Rete-LAB-AD.md](./Docs/Sintesi-ACL-Condivisioni-Rete-LAB-AD.md)

[.\Docs\Descrizione-GPO-Classi-Utenti-LAB-AD.md](./Docs/Descrizione-GPO-Classi-Utenti-LAB-AD.md)

---

## 23. Gestione di nuove macchine

Quando viene aggiunta una nuova macchina al dominio:

1. assegnare IP e DNS coerenti con il laboratorio;
2. effettuare join al dominio;
3. spostare il computer account nella OU corretta;
4. rilanciare lo script di posizionamento se necessario;
5. applicare GPO;
6. verificare firewall, logon, accessi e mapping.

Script di riferimento per il posizionamento:

[.\Scripts\06-Place-Computer-Accounts.ps1](./Scripts/06-Place-Computer-Accounts.ps1)

Script di riferimento per GPO firewall:

[.\Scripts\07b-Create-Firewall-GPOs.ps1](./Scripts/07b-Create-Firewall-GPOs.ps1)

Script di riferimento per RDP locale server:

[.\Scripts\10-Configure-Server-Local-RDP.ps1](./Scripts/10-Configure-Server-Local-RDP.ps1)

---

## 24. Gestione di nuovi utenti o service account

Quando vengono aggiunti nuovi utenti:

1. crearli nella OU corretta;
2. inserirli nei gruppi globali appropriati;
3. verificare membership AGDLP;
4. verificare applicazione GPO utente;
5. testare accessi SMB e drive mapping.

Script di riferimento:

[.\Scripts\04-Create-LAB-Users.ps1](./Scripts/04-Create-LAB-Users.ps1)

[.\Scripts\05-Set-LAB-Memberships.ps1](./Scripts/05-Set-LAB-Memberships.ps1)

Per nuovi service account, aggiornare la lista gestita in:

[.\Scripts\09c-Configure-ServiceAccount-Logon-Deny-GPO.ps1](./Scripts/09c-Configure-ServiceAccount-Logon-Deny-GPO.ps1)

---

## 25. Note operative finali

Il deploy corretto prevede due livelli di configurazione:

- script locali o bootstrap per rendere operative le macchine esistenti;
- GPO per rendere il modello scalabile e coerente nel tempo.

La configurazione finale non dipende da interventi manuali permanenti. Gli interventi manuali sono limitati a prerequisiti infrastrutturali, come rete Hyper-V, dischi virtuali e disponibilità delle VM.

Ogni modifica successiva al modello dovrebbe essere riportata negli script di fondazione, non solo applicata manualmente nell'ambiente.
