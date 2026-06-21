# Piano di test del Laboratorio Active Directory 
*Dominio=ad-lab-domain.local*

## Scopo

Questo piano definisce le verifiche eseguite sull'ambiente Active Directory prodotto dal runbook di laboratorio.  

L'obiettivo è quello di verificare, in modo atomico e ripetibile:
 - corretta applicazione delle GPO previste;
 - corretta applicazione delle policy firewall per classe di computer;
 - corretto posizionamento dei computer account;
 - correttezza di ACL NTFS e share SMB secondo modello AGDLP;
 - corretta applicazione delle GPO per classi di utenti;
 - corretto comportamento di service account e honey-object;


<br>

## Pemessa e metodologia applicata

Il piano è strutturato secondo principi compatibili con:

- **ISO/IEC 27001**: controllo operativo, gestione delle evidenze e miglioramento continuo;
- **ISO/IEC 27002**: controlli tecnici e organizzativi per gestione accessi, logging, segregazione dei privilegi e protezione delle informazioni;
- **ISO/IEC 27005**: approccio risk-based ai test di sicurezza;
- **ISO/IEC 27035**: raccolta evidenze e gestione eventi di sicurezza;
- **ISO/IEC 29119**: definizione di test case, condizioni, risultati attesi, evidenze e criteri di accettazione.

Le anomalie rilevate sono immediatamente sanate (nell'ambiente di lavoro, negli script utilizzati e nella relazione/runbook di riferimento) e si passa al test successivo solo se tutti i precedenti sono stati eseguiti con successo.

I test sono strutturati in 3 modalità/sezioni distinte:
 1. Collaudo Operatore
     - test puntuali a validazione delle sigole fasi di deploy
     - utilizzati per correggere script, runbook, ecc.
 2. Test Atomici
     - script elaborati per testare unità o elementi particolati (es. GPO, Policy, Utenti, ecc.)
 3. Test di Sicurezza (honey-object)
     - Simulazioni di attacco sulla base degli esercizi di Laboratorio
     - Kerberoasting e Silver Ticket
 
 <br>

NB: Prima di passare alla sezione successiva, tutti i test della sezione precedente devono aver dato esito positivo

> Per l'esecuzione e la contestuale raccolta e recap di tutti gli script di test è stata predisposta anche una routine di Test Automatici




<br>

---

## 1. Collaudo Operatore
L'operatore impersona uno o più ruoli tra quelli previsti ed esegue le prove definite dal test.  
Gli esiti sono riepilogati in una apposita [tabella](.\Esiti\01.TestOperatore.md) con link al relativo esito, ove previsto.

<br>

---

### T.01 - Verifica Share in SRV-FS-001

Test eseguito come amministratore locale su `SRV-FS-001`

**Target:**
   * `Departments` -> `D:\\Shares\\Departments`
   * `Governance` -> `D:\\Shares\\Governance`
   * `Shared` -> `D:\\Shares\\Shared`


<br>

Risultato atteso:
- le tre share esistono;
- `BoardOnly` e `BoardDirectors` non sono share separate;
- `BoardOnly` e `BoardDirectors` sono cartelle sotto `Governance\Board`.

<br>


Verifica struttura cartelle:
```text
D:\Shares\Departments\IT\Public
D:\Shares\Departments\IT\Internal
D:\Shares\Departments\IT\Confidential
...
D:\Shares\Departments\HR\Public
D:\Shares\Departments\HR\Internal
D:\Shares\Departments\HR\Confidential
D:\Shares\Governance\Board\BoardOnly
D:\Shares\Governance\Board\BoardDirectors
D:\Shares\Shared
```

<br>

Risultato atteso:
+ tutti i dipartimenti hanno `Public`, `Internal`, `Confidential`;
+ Governance contiene `Board\BoardOnly` e `Board\BoardDirectors`;
+ `Shared` esiste.

<br>

---

#### T.01.01 - Verifica Share SMB

Per ogni Share dati prevista si verifica da **Server Manager**
   * path locale;
   * Share Permissions;
   * Access-Based Enumeration, se prevista;
   * eventuali impostazioni offline/caching.

<br>

> il test si considera superato se le share esistono e se i permessi sono coerenti con quanto definito in design

<br>

---

#### T.01.02 - Verifica ACL NTLF

Per ogni Share dati prevista si verifica da **Esplora Risorse** che
   * `SYSTEM` e `Administrators` abbiano `Full Control`;
   * le ACL applicative usino preferibilmente gruppi `DL\_\*`;
   * non siano presenti ACE troppo ampie con scrittura, ad esempio `Domain Users`, `Everyone`, `Authenticated Users`, salvo scelta documentata;
   * i gruppi `GG\_\*` non siano assegnati direttamente alle ACL se il modello atteso e' AGDLP puro.

<br>

Ad Esempio per HR verifico:
* `D:\\Shares\\Departments\\HR` deve permettere attraversamento/lista, non necessariamente modifica alla root;
* `D:\\Shares\\Departments\\HR\\Public` deve avere ACL coerenti con `DL\_FS\_HR\_Public\_\*`;
* `D:\\Shares\\Departments\\HR\\Internal` deve avere ACL coerenti con `DL\_FS\_HR\_Internal\_\*`;
* `D:\\Shares\\Departments\\HR\\Confidential` non deve essere accessibile agli utenti HR base, ma solo a gruppi autorizzati come Director/Admin

<br>

Risultato atteso:
- i permessi operativi sono assegnati a gruppi `DL_FS_*`;
- `GG_*` non sono usati direttamente sulle ACL NTFS delle sottocartelle dati, salvo eventuali ACE di traversal sulle root se esplicitamente documentate;
- il flusso autorizzativo resta `utente -> GG -> DL -> ACL`.


<br>

> il test si considera positivo se tutti i controlli danno un esito conforme alle attese.

<br>

---

### T.02 - Verifica GPO Drive Mapping da DC01

Test eseguito come amministratore di dominio su `DC01` utilizzando **Group Policy Management** (`gpmc.msc`):

+ Individuare le GPO di Drive Mapping, Baseline User o Department Mapping.
+ Aprire **Edit** sulla GPO.
+ Navigare in: User Configuration >> Preferences >> Windows Settings >> Drive Maps


<br>

---

#### T.02.01 - GPO Drive Mapping

Verificare i mapping attesi:
   * `S:` verso `\\SRV-FS-001\Shared`
   * `H:` verso percorso dipartimentale, ad esempio `\\SRV-FS-001\Departments\HR`
   * `O:`/`G:` verso percorsi Governance

<br>

Per ogni mapping verificare:
   * Action: Update/Create/Replace;
   * Location;
   * Drive Letter

<br>

> il test si considera positivo se tutti i controlli danno un esito conforme a quanto definito a livello di design.

<br>

---

### T.03 - ACL, SMB e Mapping da CLI01

Composto da 5 test distinti, uno per ognuno dei Ruoli previsti, questo test è teso a verificare la corretta corrispondenza degli accessi alle relative risorse di rete.

**Percorse di Rete:** `\\SRV-FS-001\`

**Utenti:**
```text
RUOLO       >>      UTENTE      >>      ABILITAZIONI
utente standard     hr.user02           può utilizzare le carelle Share e Local
Director            finance.user01      può utilizzare le carelle Share, Local e la Confidential del suo Dipartimento
membro Board        board.user01        può accedere a tutte le cartelle "Confidential"
admin               admin.it.user03     può accedere a tutte le cartelle tranne quelle "Confidential"
break-glass         super.user          accede con permessi pieni a tutte le cartelle
```

> trattandosi del primo test su workstation, per essere considerato positivo, si dovrà rilevare anche l'applicazione del corretto wallpaper e della presenza dei "Dischi di rete" correttamente mappati


<br>

---

#### T.03.01 - Test utente base dipartimentale

> AD-LAB-DOMAIN\hr.user02

**Mapping drive attesi:**
```text
S: -> \\SRV-FS-001\Shared
H: -> \\SRV-FS-001\Departments\HR\Internal
```

<br>

Risultato atteso:
- `S:` presente;
- `H:` presente;
- `O:` assente;
- `G:` assente.

<br>


---

**Accesso Shared**
> \\\SRV-FS-001\Shared

<br>

TEST:
+ creare una cartella;
+ rinominarla;
+ creare un file;
+ modificarlo;
+ eliminarlo.

<br>

Risultato atteso:
- tutte le operazioni riescono.

<br>

---

**Accesso Cartelle dipatimentali**
```text
\\SRV-FS-001\Departments\HR\Public
\\SRV-FS-001\Departments\HR\Internal
```


<br>

TEST:
+ creare una cartella;
+ rinominarla;
+ creare un file;
+ modificarlo;
+ eliminarlo.

<br>

Risultato atteso:
- tutte le operazioni riescono ,tranne che in `Confidential`
- con Access-Based Enumeration attiva, la cartella `Confidential` non deve essere visibile e, se digitata manualmente, l'accesso deve essere negato
- l'accesso agli altri dipartimenti (es. \\\SRV-FS-001\Departments\Finance\Internal) deve essere negato

<br>

---

#### T.03.02 - Test Director

> AD-LAB-DOMAIN\finance.user01

**Mapping drive attesi:**
```text
S: -> \\SRV-FS-001\Shared
H: -> \\SRV-FS-001\Departments\HR\Internal
G: -> \\SRV-FS-001\Departments\HR\Confidential
O: -> \\SRV-FS-001\Governance\Board\BoardDirectors
```

<br>

Risultato atteso:
- `S:` presente;
- `H:` presente;
- `G:` presente;
- `O:` assente (se non è membro di Board)
- accesso e modifica consentita a \\\SRV-FS-001\Governance\Board\BoardDirectors
- accesso negato a \\\SRV-FS-001\Governance\Board\BoardOnly (se non è membro di Board)

<br>

---

#### T.03.03 - Test Board User

> AD-LAB-DOMAIN\board.user01

**Mapping drive attesi:**
```text
S: -> \\SRV-FS-001\Shared
G: -> \\SRV-FS-001\Governance\Board\BoardDirectors
O: -> \\SRV-FS-001\Governance\Board\BoardOnly
```

<br>

Risultato atteso:
- `S:` presente;
- `G:` accesso e modifica consentita
- `O:` accesso e modifica consentita
- accesso e modifica consentito anche alle varie `\\SRV-FS-001\Departments\<Dept>\Confidential`


<br>

---

#### T.03.04 - Test Utente Admin

> AD-LAB-DOMAIN\admin.it.user03


Risultato atteso:
- `S:` presente;
- può accedere a tutte le aree dati, via UNC per attività amministrative
- può amministrare `DC01` (anche con accesso remoto da `CLI01`)
- può amministrare `SRV-FS-001`
- Verificare in SYSVOL la presenza di:
```text
\\ad-lab-domain.local\SYSVOL\ad-lab-domain.local\Policies\{GUID-GPO}\User\Preferences\Drives\Drives.xml
```

<br>

---

#### T.03.04 - Test Utente break-glass

> AD-LAB-DOMAIN\super.user


Risultato atteso:
- `S:` può non essere presente;
- può accedere a tutte le aree dati, via UNC per attività amministrative
- può amministrare `DC01` (anche con accesso remoto da `CLI01`)
- può amministrare `SRV-FS-001`

<br>

---
---

## 2. Test atomici

Questa sezione, prevede l'esecuzione di una serie di script di test unitari.  
Se uno script restituise esiti difformi, il test si blocca e si procede alla risoluzione del problema, poi si riprende il test a partire dal primo script, aggiornando la documentazione (relazione, script di deploy, ecc.) di conseguenza.

**Lo Scopo** è quello di arrivare alla fine dei test con una piattaforma funzionanate e correttamente documentata.

Gli **Esiti** sono riepilogati in una apposita [tabella](.\Esiti\02.TestAtomici.md) con link al relativo esito, ove previsto.

---

### Convenzioni generali

Salvo diversa indicazione sul singolo test:
* HOST = `DC01`;
* USER = `admin.it.user03`
* interfaccia = `PowerShell` come amministratore (`Set-ExecutionPolicy -Scope Process Bypass -Force`);
* non si utilizzano password in chiaro o salvate negli script;
* tutti gli output `.out` sono archiviati in `./Esiti/`;
* non si modificano manualmente gli oggetti AD durante i test, salvo dove esplicitamente previsto;
* se un test deve usare credenziali applicative, si ricorre a `Get-Credential` e non parametri in chiaro.

<br>

**Percorsi**
|Oggetto|Percorso|
|-|-|
|Script|`./Scripts/`|
|Helper comuni|`./Scripts/Common-Test-Helpers.ps1`|
|Esiti|`./Esiti/`|
|Piano|`./Docs/Piano-Test-LAB-AD.md`|
|Report finale|`./Esiti/Riepilogo-Test-LAB-AD.md`|

<br>

**Exit code**
|Exit code|Significato|
|-:|-|
|`0`|Test superato|
|`1`|Test fallito|
|`2`|Prerequisito mancante, se implementato nello script|
|`3`|Test non applicabile, se implementato nello script|

<br>

---

### T01 - GRUPPI

<br>


#### T01.01 - Dominio, Domain Controller e DNS

**Descrizione:** Verifica che il dominio `ad-lab-domain.local` sia operativo, che `DC01` sia individuabile come Domain Controller e che la risoluzione DNS del dominio funzioni. È il test base per confermare la raggiungibilità dei servizi AD DS.

<br>

**Output Atteso:**
* dominio rilevato `ad-lab-domain.local`;
* Domain Controller individuato;
* risoluzione DNS riuscita;
* raggiungibilità delle porte base `53`, `88`, `389`, `445` verso `DC01`.

<br>

>> Il test è superato se dominio, DC, DNS e porte base risultano disponibili.

<br>

**Cleanup / ripristino:** Nessuno

<br>

---

<br>

#### T01.02 - Struttura OU LAB

> Da rieseguire dopo ogni modifica alla struttura logica AD.

**Descrizione:** Verifica la presenza della struttura OU prevista dal modello LAB. La corretta struttura OU è necessaria per applicare GPO, segregare utenti, posizionare computer e supportare l'automazione futura.

<br>

**Output Atteso:** Esito in `PASS` per le OU principali:
* `OU=LAB`;
* `OU=Departments`;
* `OU=Governance`;
* `OU=Admins`;
* `OU=Groups`;
* `OU=ServiceAccounts`;
* `OU=Computers`;
* `OU=Workstations`;
* `OU=Servers`;
* `OU=FileServers`;
* `OU=AppServers`;
* `OU=DBServers`;
* `OU=Staging`.

<br>

>> Tutte le OU obbligatorie devono essere presenti.

<br>

**Cleanup / ripristino:** Nessuno

<br>

---

<br>

#### T01.03 - Gruppi AGDLP

> Da rieseguire dopo aggiunta di nuovi dipartimenti, ruoli o risorse.


**Descrizione:** Verifica la presenza dei gruppi `GG\_\*` e `DL\_\*` usati per il modello AGDLP. Il test conferma che le identità e le autorizzazioni sulle risorse siano separate.

<br>

**Output Atteso:** deve includere:
* `GG\_LAB\_Admins`;
* `GG\_LAB\_BreakGlass`;
* `GG\_LAB\_ServiceAccounts`;
* `GG\_Board\_Members`;
* `GG\_LAB\_Directors`;
* conteggio gruppi `GG\_\*` maggiore di zero;
* conteggio gruppi `DL\_\*` maggiore di zero.

<br>

>> Il modello AGDLP è considerato valido se sono presenti gruppi globali per identità/ruolo e gruppi domain local per autorizzazioni.

<br>

**Cleanup / ripristino:** Nessuno

<br>

---

<br>

#### T01.04 - Utenti speciali, service account e honey-object

> Da rieseguire dopo aggiunta o modifica di account speciali.  



**Descrizione:** Verifica la presenza dei gruppi `GG\_\*` e `DL\_\*` usati per il modello AGDLP. Il test conferma che le identità e le autorizzazioni sulle risorse siano separate.

<br>

**Output Atteso:** deve riportare i tre account e i relativi attributi principali.
* `super.user`;
* `admin.backup`;
* `svc.securityapp`


<br>

>> Il test passa se tutti gli account obbligatori sono presenti e leggibili.


<br>

**Cleanup / ripristino:** Nessuno

<br>

---

### T02 - MACCHINE

<br>


#### T02.01 - Posizionamento computer account

> Da eseguire ogni volta che viene aggiunta una nuova macchina.


**Descrizione:** Verifica che i computer esistenti siano nelle OU corrette per ricevere le GPO appropriate.

<br>

**Output Atteso:**
* `CLI01` in `OU=Workstations,OU=Computers,OU=LAB,...`;
* `SRV-FS-001` in `OU=FileServers,OU=Servers,OU=Computers,OU=LAB,...`;
* `DC01` in `OU=Domain Controllers,...`.


<br>

>> Tutti i computer devono essere nella OU prevista.

<br>

**Cleanup / ripristino:** Nessuno

<br>

---

<br>

#### T02.02 - Predisposizione classi future

> Utile per validare l'aggiunta automatica di nuove classi o asset alla OU corretta.


**Descrizione:** Verifica che l'ambiente sia pronto per nuove workstation, file server, app server e database server, con OU e GPO già predisposte.

<br>

**Output Atteso:**
* `GPO-LAB-AppServers-Firewall`;
* `GPO-LAB-DBServers-Firewall`;
* `GPO-LAB-FileServers-Firewall`;
* `GPO-LAB-Workstations-Firewall`.


<br>

>> Le "classi future" devono avere OU e link GPO coerenti.


<br>

**Cleanup / ripristino:** Nessuno

<br>

---

### T03 - FIREWALL

<br>


#### T03.01 - Esistenza GPO firewall

> Da eseguire dopo modifiche alle GPO firewall.


**Descrizione:** Verifica che le GPO firewall per classi di computer siano state create.

<br>

**Output Atteso:**
* `GPO-LAB-DomainControllers-Firewall`;
* `GPO-LAB-Workstations-Firewall`;
* `GPO-LAB-FileServers-Firewall`;
* `GPO-LAB-AppServers-Firewall`;
* `GPO-LAB-DBServers-Firewall`;
* `GPO-LAB-Staging-Firewall`.


<br>

>> Tutte le GPO firewall previste devono essere presenti.

<br>

**Cleanup / ripristino:** Nessuno

<br>

---

<br>

#### T03.02 - Firewall risultante su DC01

> Da eseguire dopo modifiche firewall o hardening DC.


**Descrizione:** Verifica lo stato del firewall su `DC01`, raccogliendo profili, regole inbound abilitate e raggiungibilità delle porte base.

<br>

**Output Atteso:**
* Profili firewall abilitati;
* porte `53`, `88`, `389`, `445` raggiungibili;
* elenco regole inbound abilitate.


<br>

>> Firewall attivo e servizi AD/DNS necessari raggiungibili.


<br>

**Cleanup / ripristino:** Nessuno

<br>

---

<br>

#### T03.03 - Firewall risultante su SRV-FS-001

> Da eseguire dopo aggiunta di file server.


**Descrizione:** Verifica firewall su file server, con focus su SMB e gestione remota.  

**Host di esecuzione:**
* Host di lancio: `DC01`
* Target SMB: `SRV-FS-001`
* Protocollo: `WinRM`
* Autenticazione: `Kerberos`

<br>

**Output Atteso:**
* Firewall attivo;
* porta SMB `445` raggiungibile;
* porta WinRM `5985` raggiungibile, se prevista;
* regole inbound documentate.


<br>

>> Il file server deve esporre solo i servizi previsti.


<br>

**Cleanup / ripristino:** Nessuno

<br>

---

<br>

#### T03.04 - Firewall risultante su CLI01

> Da eseguire per ogni nuova workstation.


**Descrizione:** Verifica firewall su workstation di test `CLI01`.  

**Host di esecuzione:**
* Host di lancio: `DC01`
* Target SMB: `CLI01`
* Protocollo: `WinRM`
* Autenticazione: `Kerberos`

<br>

**Output Atteso:**
* Firewall attivo;
* regole inbound coerenti con baseline workstation;
* nessuna esposizione non prevista evidente.


<br>

>> La workstation deve avere profili firewall abilitati.


<br>

**Cleanup / ripristino:** Nessuno

<br>

---


### T04 - RISORSE

<br>


#### T04.01 - Share SMB

> Da eseguire dopo modifiche a share o file server.


**Descrizione:** Verifica la presenza delle share SMB principali su `SRV-FS-001`.

<br>

**Output Atteso:** Devono essere rilevate aree/share coerenti con
* `Departments`;
* `Governance`;
* `Shared`.

<br>

>> Tutte le aree principali devono risultare presenti.


<br>

**Cleanup / ripristino:** Nessuno

---

<br>

#### T04.02 - ACL NTFS modello AGDLP

> Da eseguire dopo modifiche a share, gruppi o dipartimenti.


**Descrizione:** Verifica le ACL NTFS su `D:\\Shares`, controllando che le assegnazioni siano coerenti con il modello AGDLP e che non vi siano assegnazioni dirette anomale.
  


<br>

**Output Atteso:**
* Elenco ACL raccolte;
* uso prevalente di gruppi `DL\_\*` per autorizzazioni;
* assenza di utenti diretti non documentati.


<br>

>> Nessuna ACE anomala critica deve essere presente.


<br>

**Cleanup / ripristino:** Nessuno

<br>

---

<br>

#### T04.03 - Accesso utente dipartimentale

> Get-Credential 'AD-LAB-DOMAIN\hr.user02'



**Descrizione:** Verifica applicativa degli accessi SMB con un utente dipartimentale campione.
  
**Host di esecuzione:**
* Host di lancio: `DC01`
* Host di esecuzione effettiva: `CLI01`
* Target SMB: `SRV-FS-001`


<br>

**Output Atteso:** L'utente dipartimentale deve
* accedere alla propria area dipartimentale, se path e credenziali corrispondono;
* accedere all'area Shared;
* non accedere alle aree Governance riservate.


<br>

>> Gli accessi effettivi devono corrispondere al ruolo dell'utente.



<br>

**Cleanup / ripristino:** Nessuno. Lo script rimuove i PSDrive temporanei creati.

---

<br>

#### T04.04 - Isolamento Governance, Board e Directors

```text
Get-Credential 'AD-LAB-DOMAIN\admin.it.user01'
Get-Credential 'board.user01@ad-lab-domain.local'
Get-Credential 'hr.user01@ad-lab-domain.local'
Get-Credential 'hr.user02@ad-lab-domain.local'
```


**Descrizione:** Verifica che Board, Directors e utenti non autorizzati abbiano accessi coerenti alle aree Governance.
  
**Host di esecuzione:** `DC01`


<br>

**Output Atteso:**
* Board accede alle aree previste;
* Directors accedono solo alle aree condivise con Directors;
* utenti non autorizzati non accedono alle aree Governance riservate.


<br>

>> Gli accessi devono rispettare la separazione Board/Directors/utenti base.


<br>

**Cleanup / ripristino:** Nessuno. Lo script rimuove i PSDrive temporanei.

<br>

---


### T05 - GPO

<br>


#### T05.01 - GPO per classi di utenti

> È possibil definire controlli più puntuali (es. REGEXP), se vengono codificati i nomi dei GPO..


**Descrizione:** Verifica la presenza di GPO candidate per classi utenti: utenti base, Directors, Board, admin, break-glass, honey-object e service account fallback.

<br>

**Output Atteso:** (presenza, intellgibilità)
* GPO con nomi o contenuti riconducibili a utenti, drive mapping, Governance, Admin, BreakGlass, Honey, Service o Baseline.


<br>

>> Devono essere presenti GPO utente coerenti con il modello di classi.


<br>

**Cleanup / ripristino:** Nessuno

---

<br>


#### T05.02 - Drive mapping

> Da aggiornare in caso di defininizione di nuove OU o Share.


**Descrizione:** Verifica la presenza di mapping drive nelle GPO.

<br>

**Output Atteso:** (presenza, intellibilità)
* `S:` area Shared;
* `H:` area dipartimentale;
* `O:` BoardOnly;
* `G:` BoardDirectors.

<br>

>> I mapping devono essere rilevabili nelle GPO.


<br>

**Cleanup / ripristino:** Nessuno

---

<br>


#### T05.03 - Deny logon service account

> Da rieseguire dopo aggiunta di nuovi service account.


**Descrizione:** Verifica che i service account siano soggetti a policy di deny logon interattivo e deny logon RDP.


<br>

**Output Atteso:** (presenza, intellibilità)
* `GG\_LAB\_ServiceAccounts` presente;
* policy `SeDenyInteractiveLogonRight` o `SeDenyRemoteInteractiveLogonRight` rilevata nei report GPO..

<br>

>> Service account non utilizzabili per logon interattivo/RDP.
.


<br>

**Cleanup / ripristino:** Nessuno

---

<br>


#### T05.04 - RDP locale sui server

> Da rieseguire all'aggiunta di un nuovo server.


**Descrizione:** Verifica la membership del gruppo locale `Remote Desktop Users` su `SRV-FS-001`.

<br>

**Output Atteso:**
* Almeno un gruppo coerente con pattern `DL\_\*RDP` o `GG\_\*Admin`.

<br>

>> Solo gruppi amministrativi previsti devono avere accesso RDP.



<br>

**Cleanup / ripristino:** Nessuno

<br>

---


### T06 - Auditing

<br>


#### T06.01_1 - Honey-object

> Da rieseguire dopo avere eseguito i test ad hoc previsti.


**Descrizione:** Verifica che l'honey-object `admin.backup` sia presente e che la piattaforma sia in grado di raccogliere evidenze di uso anomalo.

<br>

**Output Atteso:**
* Account `admin.backup` presente;
* audit policy leggibile;
* eventuali eventi Security rilevati, se l'account è stato usato.

<br>

>> Il test passa se l'honey-object è presente e l'auditing è ispezionabile. L'assenza di eventi può essere un warning, non necessariamente un fallimento.


<br>

**Cleanup / ripristino:** Nessuno

<br>

---

<br>


#### T06.01_2 - Honey-object parte 2

**Descrizione:** Questa procedura prepara un setup difensivo per verificare che l'honey-object `admin.backup` generi evidenze rilevabili quando viene coinvolto in attivita' sospette.  

> Il test può essere ripetuto dopo gli altri test di laboratorio (es. Kerberoasting o Silver Ticket)

**Eventi rilevati:**
- `4625` failed logon;
- `4771` Kerberos pre-authentication failed;
- `4776` credential validation failed;
- `4740` account locked out;
- `4662` directory service access, se auditing/SACL sono configurati;
- `6601`/`6602` eventi custom `LAB-AD-HoneyTrap`.

<br>

> Azione preliminare: Test-06.01-SetupDetection.ps1 e alcuni tentativi di accesso con password errata


Gli script di test generano eventi controllati e poi la detection su eventi Windows reali.

<br>

**Setup minimo:**
```powershell
.\Scripts\Test-06.01-SetupDetection.ps1 `
  -HoneyUser 'admin.backup' `
  -EmitTrapEvent
```

<br>

**Output Atteso:**
- Account `admin.backup` presente;
- genera un evento custom `6601` in Application;
- esporta lo stato corrente di `auditpol` in `C:\LAB-AD\Alerts\auditpol-current.txt`.

<br>

**Test Specifici:**

Setup + (almeno qualche login fallita) + `Test-06.01.ps1` correttamente parametrizzato:

```powershell
.\Scripts\Test-06.01.ps1 `
  -HoneyUser 'admin.backup' `
  -LookBackHours 24 `
  -RequireEvents
```

Esito atteso:

- `Honey-object presente`: PASS;
- `Audit policy ispezionata`: PASS;
- almeno un evento rilevante trovato: PASS;
- se non trova eventi con `-RequireEvents`, il test termina in FAIL.


##### Setup con monitor e alert file

```powershell
.\Scripts\Test-06.01-SetupDetection.ps1 `
  -HoneyUser 'admin.backup' `
  -CreateScheduledMonitor `
  -MonitorIntervalMinutes 5 `
  -EmitTrapEvent
```

Il monitor schedulato cerca eventi negli ultimi minuti e scrive alert in:

```text
C:\LAB-AD\Alerts\HoneyTrap-Alerts-yyyyMMdd.log
```

##### Setup con email

Usare solo se e' disponibile un SMTP server nel laboratorio:

```powershell
.\Scripts\Setup-Test-06.01-Detection.ps1 `
  -HoneyUser 'admin.backup' `
  -CreateScheduledMonitor `
  -MonitorIntervalMinutes 5 `
  -SmtpServer 'smtp.lab.local' `
  -MailFrom 'lab-alerts@ad-lab-domain.local' `
  -MailTo 'admin.it.user03@ad-lab-domain.local' `
  -EmitTrapEvent
```

<br> 


>> Il test passa se l'honey-object è presente e l'auditing è ispezionabile.


<br>

**Cleanup / ripristino:** Nessuno

---

<br>







## 3. Test di Sicurezza

**La descrizione puntuale** dei test e delle simulazioni previste è rinviata in un [documento ad hoc](./Test-di-Sicurezza.md).  

**L'obiettivo** è quello di descrivere, setup, esecuzione e evidenze prodotte negli scenari di:

- honey-object e rilevazione di uso improprio dell'account `admin.backup`;
- Kerberoasting;
- Silver Ticket;
- logging, alerting, conservazione delle evidenze e cleanup.

<br>

**Gli Esiti dei Test** sono dettagliati in un'apposita [tabella](./Esiti/03.TestSicurezza.md)


## Test automatici

Esecuzione completa opzionale

Il runner è solo una comodità operativa:

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
.\\Scripts\\Run-All-Tests.ps1
```
