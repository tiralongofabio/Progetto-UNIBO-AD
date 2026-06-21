<# Test-04.03 - Verifica accessi dipartimentali da CLI01 con credenziale utente target. #>
[CmdletBinding()]
param(
    [string]$RunOnComputer = 'CLI01',
    [pscredential]$RemoteAdminCredential,
    [Parameter(Mandatory=$true)][pscredential]$DepartmentCredential,
    [string]$Department = 'HR',
    [string]$FileServer = 'SRV-FS-001',
    [string[]]$ExpectedAllow,
    [string[]]$ExpectedDeny,
    [switch]$WriteTest,
    [string]$OutputDir = '.\Esiti'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'
$TestId='Test-04.03'
if(-not $ExpectedAllow){ $ExpectedAllow = @("\\$FileServer\Shared", "\\$FileServer\Departments\$Department", "\\$FileServer\Departments\$Department\Public", "\\$FileServer\Departments\$Department\Internal") }
if(-not $ExpectedDeny){ $ExpectedDeny = @("\\$FileServer\Departments\$Department\Confidential", "\\$FileServer\Governance") }
$DoWriteTest=[bool]$WriteTest.IsPresent
$ResolvedOutputDir=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDir); if(!(Test-Path $ResolvedOutputDir)){New-Item -ItemType Directory -Path $ResolvedOutputDir -Force|Out-Null}
$OutFile=Join-Path $ResolvedOutputDir "$TestId.out"
Set-Content -Path $OutFile -Encoding UTF8 -Value @("TestId=$TestId","Started=$(Get-Date -Format o)","Launcher=$env:COMPUTERNAME","LauncherUser=$env:USERDOMAIN\$env:USERNAME","RunOnComputer=$RunOnComputer","Department=$Department","DepartmentUser=$($DepartmentCredential.UserName)","WriteTest=$DoWriteTest","---")
$script:Failed=$false; $script:Warnings=0
function Write-TestLog{param([string]$Message,[ValidateSet('INFO','PASS','WARN','FAIL','DATA')][string]$Level='INFO')$line="{0} [{1}] {2}" -f (Get-Date -Format o),$Level,$Message;Add-Content $OutFile $line -Encoding UTF8;Write-Host $line;if($Level-eq'FAIL'){$script:Failed=$true};if($Level-eq'WARN'){$script:Warnings++}}
function Finish-Test{Add-Content $OutFile @("---","Warnings=$script:Warnings","Completed=$(Get-Date -Format o)","Result=$(if($script:Failed){'FAIL'}else{'PASS'})") -Encoding UTF8;if($script:Failed){exit 1}else{exit 0}}

$matrix=New-Object System.Collections.Generic.List[object]
foreach($p in $ExpectedAllow){$matrix.Add([pscustomobject]@{Path=$p;ShouldAllow='True'})}
foreach($p in $ExpectedDeny){$matrix.Add([pscustomobject]@{Path=$p;ShouldAllow='False'})}
$matrixCsv=($matrix|ConvertTo-Csv -NoTypeInformation)-join "`n"
Write-TestLog "ExpectedAllow=$($ExpectedAllow -join '; ')" DATA
Write-TestLog "ExpectedDeny=$($ExpectedDeny -join '; ')" DATA

$RemoteBlock={
 param([string]$MatrixCsv,[pscredential]$Cred,[bool]$DoWrite)
 $m=@($MatrixCsv -split "`n" | ConvertFrom-Csv)
 function Test-One{param([string]$Path,[bool]$ShouldAllow,[pscredential]$Cred,[bool]$DoWrite)
   $drive='T'+[guid]::NewGuid().ToString('N').Substring(0,5);$access=$false;$read=$false;$write=$null;$err=$null
   try{New-PSDrive -Name $drive -PSProvider FileSystem -Root $Path -Credential $Cred -ErrorAction Stop|Out-Null;$root="$drive`:";$read=Test-Path $root -ErrorAction Stop;if($read){$access=$true};if($DoWrite -and $ShouldAllow){try{$f=Join-Path $root ("_test_{0}.txt" -f [guid]::NewGuid().ToString('N'));Set-Content $f 'write-test' -ErrorAction Stop;Add-Content $f 'modify-test' -ErrorAction Stop;$new=Join-Path $root ("_test_ren_{0}.txt" -f [guid]::NewGuid().ToString('N'));Rename-Item $f $new -ErrorAction Stop;Remove-Item $new -Force -ErrorAction Stop;$write=$true}catch{$write=$false;$err="WRITE/MODIFY: $($_.Exception.Message)"}}}
   catch{$err=$_.Exception.Message}
   finally{if(Get-PSDrive $drive -ErrorAction SilentlyContinue){Remove-PSDrive $drive -Force -ErrorAction SilentlyContinue}}
   [pscustomobject]@{Computer=$env:COMPUTERNAME;Path=$Path;ShouldAllow=$ShouldAllow;AccessOk=$access;ReadOk=$read;WriteModifyOk=$write;Error=$err;User=$Cred.UserName}
 }
 $res=@();foreach($i in $m){$res+=Test-One -Path ([string]$i.Path) -ShouldAllow ([System.Convert]::ToBoolean($i.ShouldAllow)) -Cred $Cred -DoWrite $DoWrite};$res
}
try{
 if($RunOnComputer -in @($env:COMPUTERNAME,'localhost','.')){$results=& $RemoteBlock -MatrixCsv $matrixCsv -Cred $DepartmentCredential -DoWrite $DoWriteTest}
 else{$args=@($matrixCsv,$DepartmentCredential,$DoWriteTest); if($RemoteAdminCredential){$results=Invoke-Command -ComputerName $RunOnComputer -Credential $RemoteAdminCredential -ScriptBlock $RemoteBlock -ArgumentList $args -ErrorAction Stop}else{$results=Invoke-Command -ComputerName $RunOnComputer -ScriptBlock $RemoteBlock -ArgumentList $args -ErrorAction Stop}}
 foreach($r in $results){Write-TestLog "Path=$($r.Path); User=$($r.User); ShouldAllow=$($r.ShouldAllow); AccessOk=$($r.AccessOk); ReadOk=$($r.ReadOk); WriteModifyOk=$($r.WriteModifyOk); Error=$($r.Error)" DATA; if($r.ShouldAllow -and $r.AccessOk){ if($DoWriteTest -and $null -ne $r.WriteModifyOk -and -not $r.WriteModifyOk){Write-TestLog "Accesso consentito ma modifica/rinomina fallita: $($r.Path)" FAIL}else{Write-TestLog "Accesso consentito correttamente: $($r.Path)" PASS}} elseif($r.ShouldAllow -and -not $r.AccessOk){Write-TestLog "Accesso atteso ma NON riuscito: $($r.Path)" FAIL} elseif(-not $r.ShouldAllow -and -not $r.AccessOk){Write-TestLog "Accesso negato correttamente: $($r.Path)" PASS} else{Write-TestLog "Accesso NON atteso ma riuscito: $($r.Path)" FAIL}}
}catch{Write-TestLog "Errore generale: $($_.Exception.Message)" FAIL}
Finish-Test
