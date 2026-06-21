# Script definitivi LAB AD

Pacchetto definitivo degli script da allegare al runbook `LAB-AD-Runbook-Deploy-Corretto.md`.

Sequenza consigliata:

1. `00-Init-LAB-Session.ps1`
2. `01-Load-LAB-Helpers.ps1` con dot sourcing
3. `02-Create-LAB-OUs.ps1`
4. `03-Create-LAB-Groups.ps1`
5. `04-Create-LAB-Users.ps1`
6. `05-Set-LAB-Memberships.ps1`
7. `06-Place-Computer-Accounts.ps1`
8. `07-Configure-LAB-Firewall-v2.1.ps1`
9. `07b-Create-Firewall-GPOs.ps1`
10. `08-Configure-FileServer.ps1`
11. `09-Configure-GPO-And-DriveMapping.ps1`
12. `09b-Configure-UserClass-GPOs.ps1`
13. `09c-Configure-ServiceAccount-Logon-Deny-GPO.ps1`
14. `10-Configure-Server-Local-RDP.ps1`
15. `11-Configure-HoneyObject-Auditing.ps1`
16. `12-Run-Basic-Checks.ps1`
