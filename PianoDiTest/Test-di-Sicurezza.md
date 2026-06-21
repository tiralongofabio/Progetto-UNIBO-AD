# Piano integrato dei test di sicurezza Active Directory

**Documento:** `Piano-Integrato-Test-Sicurezza-AD.md`  
**Progetto:** Laboratorio Active Directory `ad-lab-domain.local`  
**Ambiente di riferimento:** `DC01`, `CLI01`, `SRV-FS-001`  

---

## 1. Scopo del documento

Il presente documento integra il Piano di Test principale, dal relaivo §6 con una sezione dedicata ai test di sicurezza previsti dal laboratorio.

L'obiettivo è quello di descrivere, setup, esecuzione e evidenze prodotte negli scenari di:

- honey-object e rilevazione di uso improprio dell'account `admin.backup`;
- Kerberoasting;
- Silver Ticket;
- logging, alerting, conservazione delle evidenze e cleanup.

Le procedure offensive operative restano nel materiale didattico fornito dal docente e non vengono riportate integralmente nel repository del progetto.

---


## 2. Ambito e delimitazioni

Sono già previste dal progetto:

- configurazione del setup difensivo per `admin.backup`;
- verifica dell'esistenza dell'honey-object;
- ispezione delle audit policy;
- generazione di eventi custom di trap;
- ricerca di eventi Security e Application correlati;
- produzione di output `.out` in `./Esiti`;
- generazione di un riepilogo security detection;
- compilazione di template evidenze.


### 2.1 Attività escluse dal repository

Non sono inseriti nel repository:

- dizionari password;
- password reali o simulate;
- hash;
- ticket Kerberos esportati;
- file `.kirbi`;
- dump di memoria;
- comandi per cracking;
- comandi per ticket forging;
- output contenenti segreti riutilizzabili;
- procedure offensive automatizzate.

Gli step offensivi richiesti sono eseguiti manualmente, secondo il materiale didattico fornito.

---

## 3. Composizione del Piano di test (integrazione)

La presente sezione si applica ed estende il capitolo "Test di sicurezza" con i seguenti:

| Test | Titolo | Finalita' |
|---|---|---|
| `Test-06.01` | Honey-object auditing & detection | Verifica eventi associati a `admin.backup` |
| `Test-07.01` | Kerberoasting detection | Verifica eventi Kerberos TGS e SPN |
| `Test-07.02` | Silver/Golden Ticket detection | Verifica eventi Kerberos/logon e trap |
| `Test-08.01` | Report finale | Aggregazione evidenze |

La modalità primaria prevista resta l'esecuzione dei singoli test in modo separato. Rimane e si inegra l'opzione del runner globale per l'esecuzione completa di un giro di test e la racolta delle relative evidenze.

---

## 4. Prerequisiti comuni

### 4.1 Host richiesti

| Host | Ruolo | Uso nei test |
|---|---|---|
| `DC01` | Domain Controller | Security log, audit Kerberos, esecuzione script |
| `CLI01` | Client Windows | Simulazioni lato utente e verifica accessi |
| `SRV-FS-001` | File server | Eventuali target SMB e contesto operativo |

### 4.2 Account rilevanti

| Account | Ruolo nel laboratorio |
|---|---|
| `admin.it.user03` | Operatore amministrativo |
| `admin.backup` | Honey-object |
| `board.user01` | Utente Board |
| `hr.user01` | Utente Director HR |
| `hr.user02` | Utente HR base |


### 4.3 Directory operative

```powershell
New-Item -ItemType Directory -Path C:\LAB-AD\TEST\Esiti -Force
New-Item -ItemType Directory -Path C:\LAB-AD\Alerts -Force
New-Item -ItemType Directory -Path C:\LAB-AD\Evidenze-Sicurezza -Force
```

### 4.4 Audit policy necessarie

- Logon;
- Account Logon;
- Credential Validation;
- Kerberos Authentication Service;
- Kerberos Service Ticket Operations;
- Account Lockout;
- Directory Service Access, se si vuole tracciare accessi ad oggetti AD specifici.

Verificare da `DC01` con

```powershell
auditpol /get /category:*
```


---

## 5. Gestione delle evidenze

### 5.1 Evidenze Raccolte

- output `.out` degli script;
- export filtrati di Event Viewer;
- screenshot di eventi Security/Application;
- timestamp di inizio/fine simulazione;
- host sorgente;
- host target;
- account coinvolto;
- Event ID;
- risultato del test;
- file di alert generati dal monitor;
- template evidenze compilato.


### 5.2 Percorsi di test

| Evidenza | Percorso consigliato |
|---|---|
| Output script | `C:\LAB-AD\TEST\Esiti\` |
| Alert trap | `C:\LAB-AD\Alerts\` |
| Screenshot/Event export | `C:\LAB-AD\Evidenze-Sicurezza\` |
| Report riepilogo | `C:\LAB-AD\TEST\Esiti\Riepilogo-Security-Detection.md` |

---

# 6. Test-06.01 - Honey-object auditing e trap detection


## 6.1 Descrizione e motivazione
L'honey-object e' un account esca: non viene normalmente usato da utenti o per processi legittimi. Qualsiasi evento associato ad esso deve essere considerato anomalo e meritevole di analisi.

Il test verifica che l'honey-object `admin.backup` sia presente nel dominio e che eventuali attivita' sospette ad esso correlate generino evidenze rilevabili nei log Windows o negli eventi del laboratorio.  

Il test può essere ripetuto per la raccolta di nuove evidenze ed esiti delle attività eseguite in paralelo.


## 6.2 Prerequisiti

- Account `admin.backup` presente in Active Directory.
- Accesso amministrativo a `DC01`.
- Modulo PowerShell `ActiveDirectory` disponibile.
- Security log accessibile.
- Audit policy configurata per logon/account logon/Kerberos.

## 6.3 Host di esecuzione

| Fase | Host |
|---|---|
| Setup | `DC01` |
| Detection | `DC01` |
| Raccolta evidenze | `DC01` |

## 6.4 Credenziali necessarie

- Account amministrativo `AD-LAB-DOMAIN\admin.it.user03`.

## 6.5 Setup difensivo

```powershell
cd C:\LAB-AD\TEST

.\Scripts\Setup-Test-06.01-Detection.ps1 `
  -HoneyUser 'admin.backup' `
  -CreateScheduledMonitor `
  -MonitorIntervalMinutes 5 `
  -EmitTrapEvent
```

Scopo:

- verificare l'esistenza dell'account `admin.backup`;
- creare o verificare la sorgente eventi `LAB-AD-HoneyTrap`;
- produrre un evento custom di trap;
- produrre alert periodico in `C:\LAB-AD\Alerts`;
- esportare lo stato corrente di `auditpol`.

## 6.6 Setup email opzionale

Se e' disponibile un relay SMTP:

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

## 6.7 Esecuzione del test

```powershell
.\Scripts\Test-06.01.ps1 `
  -HoneyUser 'admin.backup' `
  -LookBackHours 24 `
  -RequireEvents
```

## 6.8 Eventi attesi

| Event ID | Descrizione |
|---:|---|
| `4625` | Logon fallito |
| `4771` | Kerberos pre-authentication failed |
| `4776` | Credential validation failed |
| `4740` | Account lockout |
| `4662` | Directory Service Access, se configurato |
| `6601` | Evento custom trap |
| `6602` | Evento custom alert |


## 6.9 Test manuali

Si ripete l'estrazione dati a valle di ogni altro test di sicurezza che coinvolge l'utente `admin.backup`.



## 6.10 Output atteso

File:

```text
C:\LAB-AD\TEST\Esiti\Test-06.01.out
```

Esito atteso:

```text
Result=PASS
```

## 6.11 Criteri di accettazione

Il test e' superato se:

1. l'account `admin.backup` esiste;
2. la policy di audit e' ispezionabile;
3. viene rilevato almeno un evento associato all'honey-object;
4. l'evidenza e' archiviata;
5. non vengono conservati segreti.

---

# 7. Kerberoasting

## 7.1 Descrizione e motivazione

Il test integra lo scenario Kerberoasting.  
Il materiale didattico descrive la simulazione Kerberoasting basata su SPN, richiesta di ticket Kerberos per un servizio e successiva analisi offline.  
Il focus è sulla capacità di rilevare eventi Kerberos prodotti dal test.


## 7.2 Prerequisiti

- Domain Controller `DC01` operativo.
- Audit Kerberos Service Ticket Operations abilitato.
- Account target definito.
- Event Viewer/Security log accessibile.

## 7.3 Host di esecuzione

| Fase | Host |
|---|---|
| Preparazione detection | `DC01` |
| Simulazione manuale | Secondo materiale didattico |
| Rilevazione | `DC01` |

## 7.4 Credenziali necessarie

- Account amministrativo di laboratorio.

## 7.5 Script coinvolto

```powershell
.\Scripts\Test-07.01-DetectionOnly.ps1
```

## 7.6 Esecuzione detection

```powershell
.\Scripts\Test-07.01-DetectionOnly.ps1 `
  -TargetAccount 'admin.backup' `
  -LookBackHours 24
```

Se l'evento deve essere obbligatorio:

```powershell
.\Scripts\Test-07.01-DetectionOnly.ps1 `
  -TargetAccount 'admin.backup' `
  -LookBackHours 24 `
  -RequireEvents
```

## 7.7 Eventi attesi

| Event ID | Descrizione |
|---:|---|
| `4769` | Kerberos Service Ticket requested |

## 7.8 Evidenze prodotte

| Evidenza | Percorso |
|---|---|
| Output test | `C:\LAB-AD\TEST\Esiti\Test-07.01.out` |
| Export eventi `4769` | `C:\LAB-AD\Evidenze-Sicurezza\` |
| Screenshot Event Viewer | `C:\LAB-AD\Evidenze-Sicurezza\` |
| Template evidenze compilato | `Docs\Security-Testing-Evidence-Template.md` |

## 7.9 Criteri di accettazione

Il test e' superato se:

1. l'account target e' leggibile;
2. l'audit Kerberos e' ispezionabile;
3. dopo la simulazione autorizzata viene rilevato almeno un evento `4769` coerente;
4. non vengono archiviati ticket, hash o password;
5. il cleanup e' documentato.

---

# 8. Test-07.02 - Silver/Golden Ticket

## 8.1 Descrizione e motivazione

Il test integra gli scenari Silver Ticket e Golden Ticket.  
Il materiale didattico descrive la generazione di ticket Kerberos artefatti.  
L'obiettivo è quello di rilevare indicatori Kerberos/logon correlati allo scenario di test.


## 8.2 Prerequisiti

- `DC01` operativo.
- Security log accessibile.
- Audit Kerberos e logon abilitato.
- Honey-object `admin.backup` presente.

## 8.3 Esecuzione e detection

Procedere secondo le istruzioni fornite dal docente e quindi eseguire lo script

```powershell
.\Scripts\Test-07.02-DetectionOnly.ps1 `
  -HoneyUser 'admin.backup' `
  -LookBackHours 24
```

oppure, con eventi obbligatori:

```powershell
.\Scripts\Test-07.02-DetectionOnly.ps1 `
  -HoneyUser 'admin.backup' `
  -LookBackHours 24 `
  -RequireEvents
```

## 8.4 Eventi cercati

| Event ID | Descrizione |
|---:|---|
| `4624` | Logon riuscito |
| `4672` | Special privileges assigned |
| `4768` | TGT requested |
| `4769` | TGS requested |
| `4770` | TGS renewed |
| `4771` | Kerberos pre-authentication failed |
| `4776` | Credential validation |
| `6601/6602` | Eventi custom honey trap |
| `6701/6702` | Eventi custom Kerberos trap, se usati |

## 8.5 Evidenze attese

| Evidenza | Percorso |
|---|---|
| Output test | `C:\LAB-AD\TEST\Esiti\Test-07.02.out` |
| Output `klist` | Incluso nel file `.out` |
| Export eventi Security | `C:\LAB-AD\Evidenze-Sicurezza\` |
| Alert custom | `C:\LAB-AD\Alerts\` |
| Template evidenze | `Docs\Security-Testing-Evidence-Template.md` |

## 8.6 Criteri di accettazione

Il test e' superato se:

1. honey-object leggibile;
2. SID dominio documentato;
3. cache Kerberos ispezionata;
4. eventi Kerberos/logon/custom rilevati dopo scenario autorizzato;
5. nessun ticket/hash/password viene conservato.