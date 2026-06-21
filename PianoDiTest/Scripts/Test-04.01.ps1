[CmdletBinding()]
param(
    [string]$FileServer = 'SRV-FS-001',
    [string[]]$ExpectedShares = @('Departments','Governance','Shared'),
    [string]$OutputDir = '.\Esiti'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'
$TestId = 'Test-04.01'
$ResolvedOutputDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDir)
if (-not (Test-Path -LiteralPath $ResolvedOutputDir)) { New-Item -ItemType Directory -Path $ResolvedOutputDir -Force | Out-Null }
$OutFile = Join-Path $ResolvedOutputDir "$TestId.out"
Set-Content -Path $OutFile -Encoding UTF8 -Value @("TestId=$TestId","Started=$(Get-Date -Format o)","Computer=$env:COMPUTERNAME","User=$env:USERDOMAIN\$env:USERNAME","FileServer=$FileServer","---")
$script:Failed = $false; $script:Warnings = 0
function Write-TestLog { param([string]$Message,[ValidateSet('INFO','PASS','WARN','FAIL','DATA')][string]$Level='INFO') $line="{0} [{1}] {2}" -f (Get-Date -Format o),$Level,$Message; Add-Content -Path $OutFile -Encoding UTF8 -Value $line; Write-Host $line; if($Level -eq 'FAIL'){$script:Failed=$true}; if($Level -eq 'WARN'){$script:Warnings++} }
function Finish-Test { Add-Content -Path $OutFile -Encoding UTF8 -Value @("---","Warnings=$script:Warnings","Completed=$(Get-Date -Format o)","Result=$(if($script:Failed){'FAIL'}else{'PASS'})"); if($script:Failed){exit 1}else{exit 0} }

try {
    $data = Invoke-Command -ComputerName $FileServer -ScriptBlock {
        $shares = Get-SmbShare | Select-Object Name,Path,Description,FolderEnumerationMode
        $access = foreach($s in $shares){ try { Get-SmbShareAccess -Name $s.Name | Select-Object @{n='Share';e={$s.Name}},AccountName,AccessControlType,AccessRight } catch {} }
        [pscustomobject]@{ Shares=$shares; Access=$access }
    } -ErrorAction Stop

    foreach($s in $data.Shares){ Write-TestLog "Share=$($s.Name); Path=$($s.Path); ABE=$($s.FolderEnumerationMode)" 'DATA' }
    foreach($a in $data.Access){ Write-TestLog "ShareAccess Share=$($a.Share); Account=$($a.AccountName); Type=$($a.AccessControlType); Right=$($a.AccessRight)" 'DATA' }

    foreach($expected in $ExpectedShares){
        $found = @($data.Shares | Where-Object { $_.Name -eq $expected })
        if($found.Count -eq 1){
            Write-TestLog "Share attesa presente: $expected -> $($found[0].Path)" 'PASS'
            if(-not ($found[0].Path -like 'D:\Shares\*')){ Write-TestLog "Share $expected non punta a D:\Shares: $($found[0].Path)" 'FAIL' }
        } else { Write-TestLog "Share attesa mancante: $expected" 'FAIL' }
    }

    foreach($expected in $ExpectedShares){
        $acc = @($data.Access | Where-Object { $_.Share -eq $expected })
        if($acc.Count -eq 0){ Write-TestLog "Nessuna share permission leggibile per $expected" 'FAIL' }
        elseif(@($acc | Where-Object { $_.AccountName -notmatch 'Administrators|SYSTEM' }).Count -eq 0){ Write-TestLog "Share $expected accessibile solo ad amministratori/SYSTEM: utenti applicativi probabilmente bloccati" 'FAIL' }
        else { Write-TestLog "Share $expected ha almeno una permission non amministrativa" 'PASS' }
    }
} catch {
    Write-TestLog "Errore verifica share su $FileServer : $($_.Exception.Message)" 'FAIL'
}
Finish-Test
