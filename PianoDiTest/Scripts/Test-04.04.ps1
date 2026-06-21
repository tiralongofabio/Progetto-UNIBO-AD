<# Test-04.04 - Verifica accessi Governance/Board/Director da CLI01. #>
[CmdletBinding()]
param(
    [string]$RunOnComputer='CLI01',
    [pscredential]$RemoteAdminCredential,
    [Parameter(Mandatory=$true)][pscredential]$BoardCredential,
    [Parameter(Mandatory=$true)][pscredential]$DirectorCredential,
    [Parameter(Mandatory=$true)][pscredential]$UnauthorizedCredential,
    [string[]]$BoardExpectedAllow=@('\\SRV-FS-001\Governance','\\SRV-FS-001\Governance\Board'),
    [string[]]$BoardExpectedDeny=@(),
    [string[]]$DirectorExpectedAllow=@('\\SRV-FS-001\Governance\Board'),
    [string[]]$DirectorExpectedDeny=@(),
    [string[]]$UnauthorizedExpectedAllow=@(),
    [string[]]$UnauthorizedExpectedDeny=@('\\SRV-FS-001\Governance','\\SRV-FS-001\Governance\Board'),
    [switch]$WriteTest,
    [string]$OutputDir='.\Esiti'
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Continue';$TestId='Test-04.04';$DoWriteTest=[bool]$WriteTest.IsPresent
$ResolvedOutputDir=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDir);if(!(Test-Path $ResolvedOutputDir)){New-Item -ItemType Directory -Path $ResolvedOutputDir -Force|Out-Null}
$OutFile=Join-Path $ResolvedOutputDir "$TestId.out";Set-Content $OutFile @("TestId=$TestId","Started=$(Get-Date -Format o)","Launcher=$env:COMPUTERNAME","LauncherUser=$env:USERDOMAIN\$env:USERNAME","RunOnComputer=$RunOnComputer","WriteTest=$DoWriteTest","---") -Encoding UTF8
$script:Failed=$false;$script:Warnings=0
function Write-TestLog{param([string]$Message,[ValidateSet('INFO','PASS','WARN','FAIL','DATA')][string]$Level='INFO')$line="{0} [{1}] {2}" -f (Get-Date -Format o),$Level,$Message;Add-Content $OutFile $line -Encoding UTF8;Write-Host $line;if($Level-eq'FAIL'){$script:Failed=$true};if($Level-eq'WARN'){$script:Warnings++}}
function Finish-Test{Add-Content $OutFile @("---","Warnings=$script:Warnings","Completed=$(Get-Date -Format o)","Result=$(if($script:Failed){'FAIL'}else{'PASS'})") -Encoding UTF8;if($script:Failed){exit 1}else{exit 0}}
$m=New-Object System.Collections.Generic.List[object]
foreach($p in $BoardExpectedAllow){$m.Add([pscustomobject]@{Role='Board';Path=$p;ShouldAllow='True';Key='Board'})};foreach($p in $BoardExpectedDeny){$m.Add([pscustomobject]@{Role='Board';Path=$p;ShouldAllow='False';Key='Board'})}
foreach($p in $DirectorExpectedAllow){$m.Add([pscustomobject]@{Role='Director';Path=$p;ShouldAllow='True';Key='Director'})};foreach($p in $DirectorExpectedDeny){$m.Add([pscustomobject]@{Role='Director';Path=$p;ShouldAllow='False';Key='Director'})}
foreach($p in $UnauthorizedExpectedAllow){$m.Add([pscustomobject]@{Role='Unauthorized';Path=$p;ShouldAllow='True';Key='Unauthorized'})};foreach($p in $UnauthorizedExpectedDeny){$m.Add([pscustomobject]@{Role='Unauthorized';Path=$p;ShouldAllow='False';Key='Unauthorized'})}
$csv=($m|ConvertTo-Csv -NoTypeInformation)-join "`n";Write-TestLog "TestMatrixCount=$($m.Count)" DATA
$RemoteBlock={param([string]$Csv,[pscredential]$Board,[pscredential]$Director,[pscredential]$Unauthorized,[bool]$DoWrite)
 $matrix=@($Csv -split "`n"|ConvertFrom-Csv)
 function Get-Cred($key){switch($key){'Board'{$Board}'Director'{$Director}'Unauthorized'{$Unauthorized}default{throw "CredentialKey non riconosciuta: $key"}}}
 function Test-One($role,$path,[bool]$should,$cred,[bool]$write){$drive='G'+[guid]::NewGuid().ToString('N').Substring(0,5);$access=$false;$read=$false;$writeOk=$null;$err=$null;try{New-PSDrive -Name $drive -PSProvider FileSystem -Root $path -Credential $cred -ErrorAction Stop|Out-Null;$root="$drive`:";$read=Test-Path $root -ErrorAction Stop;if($read){$access=$true};if($write -and $should){try{$f=Join-Path $root ("_gov_{0}.txt" -f [guid]::NewGuid().ToString('N'));Set-Content $f 'write-test' -ErrorAction Stop;Add-Content $f 'modify-test' -ErrorAction Stop;$new=Join-Path $root ("_gov_ren_{0}.txt" -f [guid]::NewGuid().ToString('N'));Rename-Item $f $new -ErrorAction Stop;Remove-Item $new -Force -ErrorAction Stop;$writeOk=$true}catch{$writeOk=$false;$err="WRITE/MODIFY: $($_.Exception.Message)"}}}catch{$err=$_.Exception.Message}finally{if(Get-PSDrive $drive -ErrorAction SilentlyContinue){Remove-PSDrive $drive -Force -ErrorAction SilentlyContinue}};[pscustomobject]@{Computer=$env:COMPUTERNAME;Role=$role;Path=$path;User=$cred.UserName;ShouldAllow=$should;AccessOk=$access;ReadOk=$read;WriteModifyOk=$writeOk;Error=$err}}
 $res=@();foreach($i in $matrix){$res+=Test-One ([string]$i.Role) ([string]$i.Path) ([System.Convert]::ToBoolean($i.ShouldAllow)) (Get-Cred ([string]$i.Key)) $DoWrite};$res
}
try{if($RunOnComputer -in @($env:COMPUTERNAME,'localhost','.')){$results=& $RemoteBlock -Csv $csv -Board $BoardCredential -Director $DirectorCredential -Unauthorized $UnauthorizedCredential -DoWrite $DoWriteTest}else{$args=@($csv,$BoardCredential,$DirectorCredential,$UnauthorizedCredential,$DoWriteTest);if($RemoteAdminCredential){$results=Invoke-Command -ComputerName $RunOnComputer -Credential $RemoteAdminCredential -ScriptBlock $RemoteBlock -ArgumentList $args -ErrorAction Stop}else{$results=Invoke-Command -ComputerName $RunOnComputer -ScriptBlock $RemoteBlock -ArgumentList $args -ErrorAction Stop}}
foreach($r in $results){Write-TestLog "Role=$($r.Role); Path=$($r.Path); User=$($r.User); ShouldAllow=$($r.ShouldAllow); AccessOk=$($r.AccessOk); ReadOk=$($r.ReadOk); WriteModifyOk=$($r.WriteModifyOk); Error=$($r.Error)" DATA;if($r.ShouldAllow -and $r.AccessOk){if($DoWriteTest -and $null -ne $r.WriteModifyOk -and -not $r.WriteModifyOk){Write-TestLog "Accesso consentito ma modifica/rinomina fallita: Role=$($r.Role), Path=$($r.Path)" FAIL}else{Write-TestLog "Accesso consentito correttamente: Role=$($r.Role), Path=$($r.Path)" PASS}}elseif($r.ShouldAllow -and -not $r.AccessOk){Write-TestLog "Accesso atteso ma NON riuscito: Role=$($r.Role), Path=$($r.Path)" FAIL}elseif(-not $r.ShouldAllow -and -not $r.AccessOk){Write-TestLog "Accesso negato correttamente: Role=$($r.Role), Path=$($r.Path)" PASS}else{Write-TestLog "Accesso NON atteso ma riuscito: Role=$($r.Role), Path=$($r.Path)" FAIL}}
}catch{Write-TestLog "Errore generale: $($_.Exception.Message)" FAIL}
Finish-Test
