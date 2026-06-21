[CmdletBinding()]
param(
    [string]$FileServer = 'SRV-FS-001',
    [string]$RootPath = 'D:\Shares',
    [switch]$StrictAGDLP,
    [string]$OutputDir = '.\Esiti'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'
$TestId = 'Test-04.02'
$ResolvedOutputDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDir)
if (-not (Test-Path -LiteralPath $ResolvedOutputDir)) { New-Item -ItemType Directory -Path $ResolvedOutputDir -Force | Out-Null }
$OutFile = Join-Path $ResolvedOutputDir "$TestId.out"
Set-Content -Path $OutFile -Encoding UTF8 -Value @("TestId=$TestId","Started=$(Get-Date -Format o)","Computer=$env:COMPUTERNAME","User=$env:USERDOMAIN\$env:USERNAME","FileServer=$FileServer","RootPath=$RootPath","StrictAGDLP=$($StrictAGDLP.IsPresent)","---")
$script:Failed = $false; $script:Warnings = 0
function Write-TestLog { param([string]$Message,[ValidateSet('INFO','PASS','WARN','FAIL','DATA')][string]$Level='INFO') $line="{0} [{1}] {2}" -f (Get-Date -Format o),$Level,$Message; Add-Content -Path $OutFile -Encoding UTF8 -Value $line; Write-Host $line; if($Level -eq 'FAIL'){$script:Failed=$true}; if($Level -eq 'WARN'){$script:Warnings++} }
function Finish-Test { Add-Content -Path $OutFile -Encoding UTF8 -Value @("---","Warnings=$script:Warnings","Completed=$(Get-Date -Format o)","Result=$(if($script:Failed){'FAIL'}else{'PASS'})"); if($script:Failed){exit 1}else{exit 0} }

$expectedPaths = @(
    'D:\Shares\Shared',
    'D:\Shares\Departments',
    'D:\Shares\Governance'
)
$departmentNames = @('HR','IT','Finance','Legal','Marketing','Sales','Operations')
$departmentSubfolders = @('Public','Internal','Confidential')

try {
    $result = Invoke-Command -ComputerName $FileServer -ScriptBlock {
        param($RootPath,$expectedPaths,$departmentNames,$departmentSubfolders)
        $allPaths = New-Object System.Collections.Generic.List[string]
        foreach($p in $expectedPaths){ $allPaths.Add($p) }
        foreach($d in $departmentNames){
            $deptRoot = Join-Path 'D:\Shares\Departments' $d
            $allPaths.Add($deptRoot)
            foreach($sf in $departmentSubfolders){ $allPaths.Add((Join-Path $deptRoot $sf)) }
        }
        $govRoot = 'D:\Shares\Governance'
        if(Test-Path $govRoot){ Get-ChildItem $govRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object { $allPaths.Add($_.FullName) } }
        $out = foreach($p in ($allPaths | Select-Object -Unique)){
            if(Test-Path $p){
                $acl = Get-Acl $p
                foreach($a in $acl.Access){
                    [pscustomobject]@{ Path=$p; Exists=$true; Identity=$a.IdentityReference.Value; Rights=[string]$a.FileSystemRights; Type=[string]$a.AccessControlType; Inherited=$a.IsInherited }
                }
            } else {
                [pscustomobject]@{ Path=$p; Exists=$false; Identity=''; Rights=''; Type=''; Inherited=$false }
            }
        }
        $out
    } -ArgumentList $RootPath,$expectedPaths,$departmentNames,$departmentSubfolders -ErrorAction Stop

    $paths = $result | Group-Object Path
    foreach($g in $paths){
        $exists = @($g.Group | Where-Object Exists).Count -gt 0
        if(-not $exists){
            if($g.Name -match '\\(Finance|Legal|Marketing|Sales|Operations|IT|HR)(\\|$)' -or $g.Name -match 'D:\\Shares\\(Shared|Departments|Governance)'){
                Write-TestLog "Path atteso mancante: $($g.Name)" 'WARN'
            }
            continue
        }
        Write-TestLog "ACL Path=$($g.Name)" 'DATA'
        foreach($ace in $g.Group | Where-Object Exists){ Write-TestLog "  Identity=$($ace.Identity); Rights=$($ace.Rights); Type=$($ace.Type); Inherited=$($ace.Inherited)" 'DATA' }
        $nonAdmin = @($g.Group | Where-Object { $_.Exists -and $_.Identity -notmatch 'NT AUTHORITY\\SYSTEM|BUILTIN\\Administrators' })
        if($nonAdmin.Count -eq 0){ Write-TestLog "Path senza ACL applicative non-admin: $($g.Name)" 'FAIL'; continue }

        if($g.Name -match 'D:\\Shares\\Departments\\([^\\]+)\\(Public|Internal|Confidential)$'){
            $dept=$Matches[1]; $area=$Matches[2]
            $expectedMd="DL_FS_${dept}_${area}_MD"
            $expectedFc="DL_FS_${dept}_${area}_FC"
            if(@($nonAdmin | Where-Object { $_.Identity -match [regex]::Escape($expectedMd) -or $_.Identity -match [regex]::Escape($expectedFc) }).Count -gt 0){
                Write-TestLog "ACL area dipartimentale coerente: $($g.Name)" 'PASS'
            } else { Write-TestLog "ACL area dipartimentale senza DL atteso $expectedMd/$($expectedFc): $($g.Name)" 'FAIL' }
        }
        if($StrictAGDLP){
            $directGG = @($nonAdmin | Where-Object { $_.Identity -match '\\GG_' })
            foreach($ace in $directGG){ Write-TestLog "ACE diretta GG_* rilevata in StrictAGDLP: Path=$($g.Name); Identity=$($ace.Identity)" 'FAIL' }
        } else {
            $directGG = @($nonAdmin | Where-Object { $_.Identity -match '\\GG_' })
            foreach($ace in $directGG){ Write-TestLog "ACE diretta GG_* da revisionare: Path=$($g.Name); Identity=$($ace.Identity)" 'WARN' }
        }
        $tooBroad = @($nonAdmin | Where-Object { $_.Identity -match 'Everyone|Domain Users|Authenticated Users|BUILTIN\\Users' -and $_.Rights -match 'Modify|FullControl|Write' })
        foreach($ace in $tooBroad){ Write-TestLog "ACE troppo ampia con scrittura/modifica: Path=$($g.Name); Identity=$($ace.Identity); Rights=$($ace.Rights)" 'FAIL' }
    }
} catch {
    Write-TestLog "Errore verifica ACL su $FileServer : $($_.Exception.Message)" 'FAIL'
}
Finish-Test
