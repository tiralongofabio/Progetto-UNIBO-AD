$ErrorActionPreference="Stop"; $p="C:\Scripts\Monitor-HoneyObject.ps1"; New-Item (Split-Path $p) -ItemType Directory -Force|Out-Null
@'
$Events=Get-WinEvent -FilterHashtable @{LogName='Security'; Id=4624,4625,4728,4732,4756; StartTime=(Get-Date).AddMinutes(-15)} -ErrorAction SilentlyContinue|?{$_.Message -like '*admin.backup*'}
if($Events){New-Item C:\Temp -ItemType Directory -Force|Out-Null; $Events|Select TimeCreated,Id,Message|Out-File C:\Temp\LAB-HoneyObject-Alert.log -Append}
'@|Set-Content $p -Encoding UTF8
if(-not(Get-ScheduledTask -TaskName "LAB-Monitor-HoneyObject" -ErrorAction SilentlyContinue)){$a=New-ScheduledTaskAction powershell.exe "-ExecutionPolicy Bypass -File $p"; $t=New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 15) -RepetitionDuration (New-TimeSpan -Days 3650); Register-ScheduledTask -TaskName "LAB-Monitor-HoneyObject" -Action $a -Trigger $t -RunLevel Highest|Out-Null}
Write-Host "[OK] Honey object auditing configured" -ForegroundColor Green
