param([string]$OutputDir='.\Esiti')
$tests = Get-ChildItem -Path $PSScriptRoot -Filter 'Test-*.ps1' | Where-Object { $_.Name -ne 'Test-08.01.ps1' } | Sort-Object Name
foreach($t in $tests){ Write-Host "=== Running $($t.Name) ==="; & $t.FullName -OutputDir $OutputDir; Write-Host "ExitCode=$LASTEXITCODE" }
& (Join-Path $PSScriptRoot 'Test-08.01.ps1') -OutputDir $OutputDir
