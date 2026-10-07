# Sona for Windows 11 x64. Run from PowerShell as your normal user.
[CmdletBinding()]
param(
    [string]$PackagePath,
    [string]$Sha256,
    [switch]$NoLaunch
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
if (-not [Environment]::Is64BitOperatingSystem -or $env:PROCESSOR_ARCHITECTURE -eq 'ARM64' -or $env:PROCESSOR_ARCHITEW6432 -eq 'ARM64' -or [Environment]::OSVersion.Version.Build -lt 22000) {
    throw 'This Sona release requires Windows 11 x64.'
}
$install = Join-Path $env:LOCALAPPDATA 'Programs\Sona'
$executable = Join-Path $install 'Sona.exe'
Get-Process -Name Sona -ErrorAction SilentlyContinue | ForEach-Object {
    if ($_.Path -eq $executable) { throw 'Quit Sona from its tray menu, then run the installer again.' }
}
$temporary = Join-Path ([IO.Path]::GetTempPath()) ('Sona-setup-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temporary | Out-Null
try {
    if (-not $PackagePath) {
        $release = Invoke-RestMethod 'https://api.github.com/repos/zachk-alt/sona/releases/latest' -Headers @{ 'User-Agent' = 'Sona-Windows-Installer' }
        $asset = @($release.assets | Where-Object name -eq 'Sona-windows-x64.zip')
        $checksums = @($release.assets | Where-Object name -eq 'SHA256SUMS.txt')
        if ($asset.Count -ne 1 -or $checksums.Count -ne 1) { throw 'This release does not contain the Windows package and checksums yet.' }
        $PackagePath = Join-Path $temporary 'Sona-windows-x64.zip'
        Invoke-WebRequest -UseBasicParsing -TimeoutSec 300 $asset[0].browser_download_url -OutFile $PackagePath
        $checksumFile = Join-Path $temporary 'SHA256SUMS.txt'
        Invoke-WebRequest -UseBasicParsing -TimeoutSec 300 $checksums[0].browser_download_url -OutFile $checksumFile
        $checksumText = Get-Content -LiteralPath $checksumFile -Raw
        $line = @($checksumText -split "`n" | Where-Object { $_ -match '^[0-9a-fA-F]{64}\s+\*?Sona-windows-x64\.zip\s*$' })
        if ($line.Count -ne 1) { throw 'The Windows package checksum is missing or ambiguous.' }
        $Sha256 = ($line[0] -split '\s+')[0]
    }
    if ($Sha256 -notmatch '^[0-9a-fA-F]{64}$') { throw 'For a local package, pass -Sha256 from its trusted release checksums.' }
    if ((Get-FileHash -LiteralPath $PackagePath -Algorithm SHA256).Hash -ne $Sha256) { throw 'The Sona package checksum does not match.' }
    $staged = Join-Path $temporary 'app'
    # Expand-Archive rejects unsafe paths. The archive is also checked before extraction.
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead((Resolve-Path -LiteralPath $PackagePath))
    try {
        foreach ($entry in $zip.Entries) {
            if ([IO.Path]::IsPathRooted($entry.FullName) -or $entry.FullName -match '(^|[\\/])\.\.([\\/]|$)') { throw 'Unsafe path in Sona package.' }
        }
    } finally { $zip.Dispose() }
    Expand-Archive -LiteralPath $PackagePath -DestinationPath $staged
    if (-not (Test-Path -LiteralPath (Join-Path $staged 'Sona.exe')) -or -not (Test-Path -LiteralPath (Join-Path $staged 'bridge\sona-cleanup.mjs')) -or -not (Test-Path -LiteralPath (Join-Path $staged 'bridge\gemini-cli.mjs')) -or -not (Test-Path -LiteralPath (Join-Path $staged 'bridge\gemini-launch.mjs')) -or -not (Test-Path -LiteralPath (Join-Path $staged 'bridge\gemini-loader.mjs'))) { throw 'The package is incomplete.' }

    foreach ($required in @('bridge\assistant.mjs','bridge\assistant-transports.mjs','bridge\blender.mjs','bridge\blender-scene.py','bridge\errors.mjs','bridge\snippets.mjs','bridge\operations.mjs','bridge\prompts\rewrite.txt','bridge\prompts\snippet-assist.txt')) {
        if (-not (Test-Path -LiteralPath (Join-Path $staged $required))) { throw "The package is incomplete: $required" }
    }

    # Node is private to Sona; no PATH change and no global npm installation.
    $nodeVersion = 'v24.20.0'
    $nodeName = "node-$nodeVersion-win-x64.zip"
    $nodeHash = '6cac9ffbca8f6a47091e4b5c772e0606049c3871cb67d900c0cedde630e545ba'
    $nodeZip = Join-Path $temporary $nodeName
    Write-Host 'Preparing the local cleanup runtime…'
    Invoke-WebRequest -UseBasicParsing -TimeoutSec 300 "https://nodejs.org/dist/$nodeVersion/$nodeName" -OutFile $nodeZip
    if ((Get-FileHash $nodeZip -Algorithm SHA256).Hash -ne $nodeHash) { throw 'The Node download failed its integrity check.' }
    $nodeExpanded = Join-Path $temporary 'node'
    Expand-Archive $nodeZip $nodeExpanded
    $runtime = Join-Path $staged 'runtime\node'
    New-Item -ItemType Directory -Path $runtime -Force | Out-Null
    Copy-Item (Join-Path $nodeExpanded "node-$nodeVersion-win-x64\node.exe") $runtime
    Copy-Item (Join-Path $nodeExpanded "node-$nodeVersion-win-x64\LICENSE") (Join-Path $runtime 'LICENSE.txt')

    # Whisper's official Windows runtime requires the Microsoft VC++ redistributable.
    $vc = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64' -ErrorAction SilentlyContinue
    if (-not $vc -or $vc.Installed -ne 1 -or $vc.Minor -lt 40) {
        Write-Host 'Installing the Microsoft speech-runtime dependency. Windows may request administrator approval.'
        $redist = Join-Path $temporary 'vc_redist.x64.exe'
        Invoke-WebRequest -UseBasicParsing -TimeoutSec 300 'https://aka.ms/vs/17/release/vc_redist.x64.exe' -OutFile $redist
        $signature = Get-AuthenticodeSignature $redist
        if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') { throw 'Microsoft runtime signature validation failed.' }
        $result = Start-Process $redist -ArgumentList '/install', '/quiet', '/norestart' -Wait -PassThru
        if ($result.ExitCode -notin 0, 1638, 3010) { throw "Microsoft runtime installation failed with code $($result.ExitCode)." }
    }
    # Keep the previous version for recovery. User config/model data live elsewhere.
    New-Item -ItemType Directory -Path (Split-Path $install -Parent) -Force | Out-Null
    $backup = $null
    if (Test-Path -LiteralPath $install) {
        $backup = "$install.previous-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        Move-Item -LiteralPath $install -Destination $backup
    }
    try { Move-Item -LiteralPath $staged -Destination $install }
    catch { if ($backup -and -not (Test-Path -LiteralPath $install)) { Move-Item -LiteralPath $backup -Destination $install }; throw }
    $shell = New-Object -ComObject WScript.Shell
    $shortcutPath = Join-Path ([Environment]::GetFolderPath('Programs')) 'Sona.lnk'
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = $executable; $shortcut.WorkingDirectory = $install; $shortcut.IconLocation = "$executable,0"; $shortcut.Save()
    Write-Host "Sona installed to $install"
    Write-Host 'First launch lets you choose a shortcut and downloads the verified local speech model (about 148 MB).'
    Write-Host 'Choose a supported existing AI connection in Settings. Sona uses fixed economical presets and never signs you in.'
    Write-Host 'Enable Microphone access and Let desktop apps access your microphone in Windows Privacy & security settings.'
    if (-not $NoLaunch) { Start-Process $executable }
} finally {
    # Only this invocation's random temporary directory is removed.
    if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Recurse -Force }
}
