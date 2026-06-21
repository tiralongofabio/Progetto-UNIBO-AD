<#
.SYNOPSIS
  Aggrega gli output dei test detection security in un report Markdown.
#>
[CmdletBinding()]
param(
    [string]$EsitiDir = '.\Esiti',
    [string]$OutputFile = '.\Esiti\Riepilogo-Security-Detection.md'
)
Set-StrictMode -Version Latest
if(!(Test-Path $EsitiDir)){New-Item -ItemType Directory -Path $EsitiDir -Force|Out-Null}
$files = Get-ChildItem $EsitiDir -Filter 'Test-0*.out' -ErrorAction SilentlyContinue | Where-Object {$_.Name -match '06\.01|07\.01|07\.02'} | Sort-Object Name
$lines = New-Object System.Collections.Generic.List[string]
$lines.Add('# Riepilogo Security Detection')
$lines.Add('')
$lines.Add('| Test | Result | Warnings | File |')
$lines.Add('|---|---:|---:|---|')
foreach($f in $files){$txt=Get-Content $f.FullName -Raw;$result=if($txt -match 'Result=(\w+)'){$Matches[1]}else{'UNKNOWN'};$warn=if($txt -match 'Warnings=(\d+)'){$Matches[1]}else{'?'};$lines.Add("| $($f.BaseName) | $result | $warn | $($f.Name) |")}
$lines.Add('')
$lines.Add('Generato: ' + (Get-Date -Format o))
Set-Content -Path $OutputFile -Value $lines -Encoding UTF8
Write-Host "Creato $OutputFile"
