param(
  [string]$OutputDir='.\Esiti',
  [string]$ComputerName,
  [string]$FileServer='SRV-FS-001',
  [pscredential]$TestCredential,
  [pscredential]$BoardCredential,
  [pscredential]$DirectorCredential,
  [pscredential]$UnauthorizedCredential,
  [string]$AdminUser='Administrator',
  [string]$TemporarySpn='SERVICE/lab-kerberoast-test',
  [switch]$SkipTgsRequest,
  [string]$HoneyUser='admin.backup',
  [int]$LookBackHours=24,
  [int]$LookBackMinutes=60,
  [switch]$PurgeKerberosCacheAtEnd
)
. "$PSScriptRoot\Common-Test-Helpers.ps1"
Invoke-LabTest -TestId 'Test-06.01' -OutputDir $OutputDir -ComputerName $ComputerName -FileServer $FileServer -TestCredential $TestCredential -BoardCredential $BoardCredential -DirectorCredential $DirectorCredential -UnauthorizedCredential $UnauthorizedCredential -AdminUser $AdminUser -TemporarySpn $TemporarySpn -SkipTgsRequest:$SkipTgsRequest -HoneyUser $HoneyUser -LookBackHours $LookBackHours -LookBackMinutes $LookBackMinutes -PurgeKerberosCacheAtEnd:$PurgeKerberosCacheAtEnd
