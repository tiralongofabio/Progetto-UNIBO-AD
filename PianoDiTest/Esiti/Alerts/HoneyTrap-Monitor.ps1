param(
    [string]$HoneyUser = 'admin.backup',
    [string]$AlertRoot = 'C:\LAB-AD\Alerts',
    [int]$LookBackMinutes = 10,
    [string]$SmtpServer = '',
    [string]$MailFrom = '',
    [string]$MailTo = ''
)

$ErrorActionPreference = 'Continue'
New-Item -ItemType Directory -Path $AlertRoot -Force | Out-Null
$now = Get-Date
$start = $now.AddMinutes(-1 * $LookBackMinutes)
$alertFile = Join-Path $AlertRoot ('HoneyTrap-Alerts-{0}.log' -f $now.ToString('yyyyMMdd'))
$events = @()

try {
    $sec = Get-WinEvent -FilterHashtable @{ LogName='Security'; Id=4625,4771,4776,4740,4662,4768,4769,4624,4672; StartTime=$start } -ErrorAction SilentlyContinue |
        Where-Object { $_.Message -match [regex]::Escape($HoneyUser) }
    $events += $sec
} catch {}

try {
    $custom = Get-WinEvent -FilterHashtable @{ LogName='Application'; ProviderName='LAB-AD-HoneyTrap'; Id=6601,6602,6701,6702; StartTime=$start } -ErrorAction SilentlyContinue |
        Where-Object { $_.Message -match [regex]::Escape($HoneyUser) }
    $events += $custom
} catch {}

if ($events.Count -gt 0) {
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('==== HONEY/KERBEROS TRAP ALERT ' + $now.ToString('o') + ' ====')
    $lines.Add('Subject=' + $HoneyUser)
    foreach ($e in $events | Sort-Object TimeCreated) {
        $lines.Add(('Time={0}; Id={1}; Provider={2}; Machine={3}' -f $e.TimeCreated.ToString('o'), $e.Id, $e.ProviderName, $e.MachineName))
        $msg = ($e.Message -replace "|
", ' ')
        if ($msg.Length -gt 1200) { $msg = $msg.Substring(0,1200) + '...' }
        $lines.Add('Message=' + $msg)
    }
    Add-Content -Path $alertFile -Value $lines -Encoding UTF8

    if ($SmtpServer -and $MailFrom -and $MailTo) {
        try {
            Send-MailMessage -SmtpServer $SmtpServer -From $MailFrom -To $MailTo -Subject "LAB Security Trap alert: $HoneyUser" -Body ($lines -join "
")
        } catch {
            Add-Content -Path $alertFile -Value ('MAIL_SEND_ERROR=' + $_.Exception.Message) -Encoding UTF8
        }
    }
}
