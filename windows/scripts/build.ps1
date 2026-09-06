[CmdletBinding()]
param([string]$OutputDirectory = (Join-Path $PSScriptRoot '..\artifacts'), [switch]$SkipTests)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$windows = Join-Path $root 'windows'
$publish = Join-Path $OutputDirectory 'publish'
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
if (-not $SkipTests) {
    & dotnet run --project (Join-Path $windows 'tests\Sona.Core.Tests\Sona.Core.Tests.csproj') -c Release
    if ($LASTEXITCODE -ne 0) { throw 'Core tests failed.' }
}
& dotnet publish (Join-Path $windows 'src\Sona.Windows\Sona.Windows.csproj') -c Release -r win-x64 --self-contained true -p:EnableWindowsTargeting=true -o $publish
if ($LASTEXITCODE -ne 0) { throw 'Windows publish failed.' }
# Native Whisper libraries stay beside the single-file managed app by design.
Copy-Item (Join-Path $windows 'README.md') (Join-Path $publish 'README-Windows.md')
Copy-Item (Join-Path $windows 'docs\THIRD-PARTY.md') (Join-Path $publish 'THIRD-PARTY.md')
Copy-Item (Join-Path $windows 'scripts\install.ps1') (Join-Path $OutputDirectory 'install-windows.ps1')
$zip = Join-Path $OutputDirectory 'Sona-windows-x64.zip'
Compress-Archive -Path (Join-Path $publish '*') -DestinationPath $zip -Force
$hash = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant()
[IO.File]::WriteAllText((Join-Path $OutputDirectory 'SHA256SUMS.txt'), "$hash  Sona-windows-x64.zip`n", (New-Object Text.UTF8Encoding $false))
Write-Host $zip
