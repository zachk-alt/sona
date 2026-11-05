[CmdletBinding()]
param([string]$OutputDirectory = (Join-Path $PSScriptRoot '..\artifacts'), [switch]$SkipTests)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$windows = Join-Path $root 'windows'
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
# Full path, because MSBuild resolves SherpaNativeDirectory against the project folder, not this shell's location.
$OutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).Path
$publish = Join-Path $OutputDirectory 'publish'
if (-not $SkipTests) {
    & dotnet run --project (Join-Path $windows 'tests\Sona.Core.Tests\Sona.Core.Tests.csproj') -c Release
    if ($LASTEXITCODE -ne 0) { throw 'Core tests failed.' }
}

# sherpa-onnx native pair. The NuGet runtime's sherpa-onnx-c-api.dll also carries text to speech with espeak-ng
# (GPL-3.0-or-later) linked in, so it never ships. Sona ships the official no-TTS Windows build of the same
# version instead: the archive and both DLLs are pinned by SHA-256.
$sherpaName = 'sherpa-onnx-v1.13.8-win-x64-shared-MT-Release-no-tts-lib'
$sherpaUrl = "https://github.com/k2-fsa/sherpa-onnx/releases/download/v1.13.8/$sherpaName.tar.bz2"
$sherpaArchiveSha256 = 'a1253e665c4f236119c443c8932a8acfca32a546c78c05962d483c9a0eae21b7'
$sherpaPins = [ordered]@{
    'sherpa-onnx-c-api.dll' = '86c7807d12982aa31c5cae57c686f30df9e5d5db4309b314d1efd5c873a8333c'
    'onnxruntime.dll'       = '7f66f939a881baf4f46a2216496798edf4a1429878b646d12674aa62f27d8a25'
}
function Test-Sha256([string]$Path, [string]$Expected) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -eq $Expected
}
function Test-SherpaPair([string]$Folder) {
    foreach ($name in $sherpaPins.Keys) { if (-not (Test-Sha256 (Join-Path $Folder $name) $sherpaPins[$name])) { return $false } }
    return $true
}
$sherpaCache = Join-Path $OutputDirectory 'sherpa-no-tts'
$sherpaNative = Join-Path $sherpaCache 'lib'
if (-not (Test-SherpaPair $sherpaNative)) {
    New-Item -ItemType Directory -Force -Path $sherpaCache | Out-Null
    $archive = Join-Path $sherpaCache "$sherpaName.tar.bz2"
    if (-not (Test-Sha256 $archive $sherpaArchiveSha256)) {
        if (Test-Path -LiteralPath $archive) { Remove-Item -LiteralPath $archive -Force }
        Invoke-WebRequest -Uri $sherpaUrl -OutFile $archive -UseBasicParsing
        if (-not (Test-Sha256 $archive $sherpaArchiveSha256)) { throw "$sherpaName.tar.bz2 does not match its pinned SHA-256." }
    }
    $extract = Join-Path $sherpaCache 'extract'
    $extractedLib = Join-Path (Join-Path $extract $sherpaName) 'lib'
    # Older Windows tar builds have no bzip2 of their own and call an external bzip2, so try a few extractors in turn.
    $attempts = New-Object System.Collections.Generic.List[scriptblock]
    $attempts.Add({ & tar -xjf $archive -C $extract })
    $gitUsrBin = if ($env:ProgramFiles) { Join-Path $env:ProgramFiles 'Git\usr\bin' } else { $null }
    $windowsTar = if ($env:SystemRoot) { Join-Path $env:SystemRoot 'System32\tar.exe' } else { $null }
    if ($gitUsrBin -and $windowsTar -and (Test-Path -LiteralPath (Join-Path $gitUsrBin 'bzip2.exe')) -and (Test-Path -LiteralPath $windowsTar)) {
        $attempts.Add({
            $savedPath = $env:PATH
            try { $env:PATH = "$gitUsrBin;$savedPath"; & $windowsTar -xjf $archive -C $extract }
            finally { $env:PATH = $savedPath }
        })
    }
    $sevenZip = Get-Command 7z -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source
    if (-not $sevenZip -and $env:ProgramFiles -and (Test-Path -LiteralPath (Join-Path $env:ProgramFiles '7-Zip\7z.exe'))) { $sevenZip = Join-Path $env:ProgramFiles '7-Zip\7z.exe' }
    if ($sevenZip) {
        $attempts.Add({
            & $sevenZip x $archive "-o$extract" -y | Out-Null
            & $sevenZip x (Join-Path $extract "$sherpaName.tar") "-o$extract" -y | Out-Null
        })
    }
    $unpacked = $false
    foreach ($attempt in $attempts) {
        if (Test-Path -LiteralPath $extract) { Remove-Item -LiteralPath $extract -Recurse -Force }
        New-Item -ItemType Directory -Force -Path $extract | Out-Null
        try { & $attempt } catch { Write-Host "sherpa-onnx extract attempt failed: $($_.Exception.Message)" }
        if (Test-Path -LiteralPath (Join-Path $extractedLib 'sherpa-onnx-c-api.dll')) { $unpacked = $true; break }
    }
    if (-not $unpacked) { throw "Could not extract $sherpaName.tar.bz2. Install 7-Zip or Git for Windows (for bzip2) and retry." }
    New-Item -ItemType Directory -Force -Path $sherpaNative | Out-Null
    foreach ($name in $sherpaPins.Keys) {
        $source = Join-Path $extractedLib $name
        if (-not (Test-Sha256 $source $sherpaPins[$name])) { throw "$name from $sherpaName does not match its pinned SHA-256." }
        Copy-Item -LiteralPath $source -Destination (Join-Path $sherpaNative $name) -Force
    }
    Remove-Item -LiteralPath $extract -Recurse -Force
}

& dotnet publish (Join-Path $windows 'src\Sona.Windows\Sona.Windows.csproj') -c Release -r win-x64 --self-contained true -p:EnableWindowsTargeting=true "-p:SherpaNativeDirectory=$sherpaNative" -o $publish
if ($LASTEXITCODE -ne 0) { throw 'Windows publish failed.' }
# License gate, on top of the same check in the csproj: the shipped pair must be the pinned no-TTS build,
# and sherpa-onnx-c-api.dll must not contain espeak-ng.
if (-not (Test-SherpaPair $publish)) { throw 'Published sherpa-onnx-c-api.dll or onnxruntime.dll is not the pinned no-TTS sherpa-onnx build.' }
$sherpaText = [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes((Join-Path $publish 'sherpa-onnx-c-api.dll')))
if ($sherpaText.Contains('espeak_ng_')) { throw 'Published sherpa-onnx-c-api.dll contains espeak_ng_ (GPL-3.0-or-later text to speech).' }
# Native Whisper libraries stay beside the single-file managed app by design.
Copy-Item (Join-Path $windows 'README.md') (Join-Path $publish 'README-Windows.md')
Copy-Item (Join-Path $windows 'docs\THIRD-PARTY.md') (Join-Path $publish 'THIRD-PARTY.md')
Copy-Item (Join-Path $windows 'scripts\install.ps1') (Join-Path $OutputDirectory 'install-windows.ps1')
$zip = Join-Path $OutputDirectory 'Sona-windows-x64.zip'
Compress-Archive -Path (Join-Path $publish '*') -DestinationPath $zip -Force
$hash = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant()
[IO.File]::WriteAllText((Join-Path $OutputDirectory 'SHA256SUMS.txt'), "$hash  Sona-windows-x64.zip`n", (New-Object Text.UTF8Encoding $false))
Write-Host $zip
