#Requires -Version 5.1
<#
.SYNOPSIS
    Installs the custom KiCad footprint libraries, symbol libraries and 3D
    models from this repository into a local KiCad installation and
    registers them in KiCad's fp-lib-table and sym-lib-table.

.DESCRIPTION
    Copies footprints/*.pretty, symbols/*.kicad_sym and 3dmodels/*.3dshapes
    to a local folder, rewrites the 3D model references inside the copied
    footprints so they point at the local install folder, and adds/updates
    the library entries in the user's fp-lib-table and sym-lib-table.

.PARAMETER KicadVersion
    KiCad version folder to use (for example "10.0"). Detected automatically
    from %APPDATA%\kicad when omitted.

.PARAMETER InstallDir
    Target folder for the libraries. Defaults to
    <Documents>\KiCad\<version>\kicad-custom-libs.

.PARAMETER ConfigDir
    Folder containing fp-lib-table and sym-lib-table. Defaults to
    %APPDATA%\kicad\<version>.

.PARAMETER NoRegister
    Copy the libraries but do not modify fp-lib-table or sym-lib-table.

.EXAMPLE
    .\install.ps1

.EXAMPLE
    .\install.ps1 -KicadVersion 10.0 -InstallDir D:\KiCadLibs -ConfigDir C:\temp\kicad-cfg
#>
[CmdletBinding()]
param(
    [string]$KicadVersion,
    [string]$InstallDir,
    [string]$ConfigDir,
    [switch]$NoRegister
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not (Test-Path -LiteralPath (Join-Path $repoRoot 'footprints'))) {
    throw "footprints/ not found next to this script. Run the script from the repository root."
}
if (-not (Test-Path -LiteralPath (Join-Path $repoRoot '3dmodels'))) {
    throw "3dmodels/ not found next to this script."
}
if (-not (Test-Path -LiteralPath (Join-Path $repoRoot 'symbols'))) {
    throw "symbols/ not found next to this script."
}

$configBase = if ($env:APPDATA) { Join-Path $env:APPDATA 'kicad' } else { $null }

if (-not $KicadVersion) {
    if (-not $configBase -or -not (Test-Path -LiteralPath $configBase)) {
        throw "Could not find the KiCad configuration folder. Pass -KicadVersion (for example 10.0)."
    }
    $KicadVersion = Get-ChildItem -LiteralPath $configBase -Directory |
        Where-Object { $_.Name -match '^\d+(\.\d+)+$' } |
        Sort-Object { [version]$_.Name } -Descending |
        Select-Object -First 1 -ExpandProperty Name
    if (-not $KicadVersion) {
        throw "No KiCad version folders found under $configBase. Pass -KicadVersion (for example 10.0)."
    }
}

$configDirPath = if ($ConfigDir) { $ConfigDir } else { Join-Path $configBase $KicadVersion }

if (-not $InstallDir) {
    $documents = [Environment]::GetFolderPath('MyDocuments')
    $InstallDir = Join-Path $documents "KiCad\$KicadVersion\kicad-custom-libs"
}

$InstallDir = $InstallDir.TrimEnd('\', '/')
$installFwd = $InstallDir -replace '\\', '/'

if (Get-Process -Name kicad -ErrorAction SilentlyContinue) {
    Write-Warning 'KiCad is running. Close it after the install and before saving anything, otherwise it may overwrite fp-lib-table.'
}

Write-Host "KiCad version : $KicadVersion"
Write-Host "Install folder: $InstallDir"
Write-Host "Config folder : $configDirPath"

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Copy-LibraryTree {
    param([string]$Source, [string]$Destination)
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    Get-ChildItem -LiteralPath $Source -Force | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $Destination -Recurse -Force
    }
}

Write-Host 'Copying footprints, symbols and 3D models...'
Copy-LibraryTree -Source (Join-Path $repoRoot 'footprints') -Destination (Join-Path $InstallDir 'footprints')
Copy-LibraryTree -Source (Join-Path $repoRoot 'symbols') -Destination (Join-Path $InstallDir 'symbols')
Copy-LibraryTree -Source (Join-Path $repoRoot '3dmodels') -Destination (Join-Path $InstallDir '3dmodels')

$modelMap = [ordered]@{
    '${EASYEDA2KICAD}/easyeda2kicad.3dshapes/' = "$installFwd/3dmodels/easyeda2kicad.3dshapes/"
    'C:/Users/Vvirtue/Documents/KiCad/10.0/3dmodels/' = "$installFwd/3dmodels/"
    'C:/Users/Vvirtue/AppData/Local/KiCadComponentImporter/global_libraries/3DModels/' = "$installFwd/3dmodels/"
    'C:/Users/Vvirtue/Pictures/Import/3d/' = "$installFwd/3dmodels/new_footprint.3dshapes/"
}

Write-Host 'Rewriting 3D model paths in installed footprints...'
$patched = 0
Get-ChildItem -LiteralPath (Join-Path $InstallDir 'footprints') -Recurse -Filter '*.kicad_mod' | ForEach-Object {
    $text = [System.IO.File]::ReadAllText($_.FullName)
    $original = $text
    foreach ($key in $modelMap.Keys) {
        $text = $text.Replace($key, $modelMap[$key])
    }
    $text = $text.Replace('(model "ZMPT101B.stp"', "(model `"$installFwd/3dmodels/new_footprint.3dshapes/ZMPT101B.stp`"")
    if ($text -ne $original) {
        [System.IO.File]::WriteAllText($_.FullName, $text, $utf8NoBom)
        $patched++
    }
}
Write-Host "Patched $patched footprint file(s)."

function Update-LibTable {
    param(
        [string]$TablePath,
        [string]$TableName,
        [System.Collections.IDictionary]$Uris
    )

    if (Test-Path -LiteralPath $TablePath) {
        $lines = [System.IO.File]::ReadAllText($TablePath) -split "\r?\n"
    }
    else {
        $lines = @("($TableName", "`t(version 7)", ')')
    }

    $nameAlternation = ($Uris.Keys | ForEach-Object { [regex]::Escape($_) }) -join '|'
    $entryPattern = '^\s*\(lib\s+\(name\s+"(?:' + $nameAlternation + ')"\)'
    $lines = @($lines | Where-Object { $_ -notmatch $entryPattern })

    $entries = @()
    foreach ($name in $Uris.Keys) {
        $entries += "`t(lib (name `"$name`") (type `"KiCad`") (uri `"$($Uris[$name])`") (options `"`") (descr `"Installed by the kicad-custom-libs installer`"))"
    }

    $insertAt = -1
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        if ($lines[$i].Trim() -eq ')') { $insertAt = $i; break }
    }

    if ($insertAt -ge 0) {
        $before = if ($insertAt -gt 0) { @($lines[0..($insertAt - 1)]) } else { @() }
        $after = @($lines[$insertAt..($lines.Count - 1)])
        $lines = $before + $entries + $after
    }
    else {
        $lines = $lines + $entries
    }

    [System.IO.File]::WriteAllText($TablePath, (($lines -join "`n").TrimEnd("`r", "`n") + "`n"), $utf8NoBom)
}

if (-not $NoRegister) {
    New-Item -ItemType Directory -Path $configDirPath -Force | Out-Null

    $footprintUris = [ordered]@{
        'easyeda2kicad'      = "$installFwd/footprints/easyeda2kicad.pretty"
        'IPEX-1'             = "$installFwd/footprints/IPEX-1.pretty"
        'JST_PH_2P'          = "$installFwd/footprints/JST_PH_2P.pretty"
        'new_footprint'      = "$installFwd/footprints/new_footprint.pretty"
        'PinHeader_2P'       = "$installFwd/footprints/PinHeader_2P.pretty"
        'Project_Components' = "$installFwd/footprints/Project_Components.pretty"
        'SK-3296S-01-L2'     = "$installFwd/footprints/SK-3296S-01-L2.pretty"
        'TYPEC-304J-BCP16'   = "$installFwd/footprints/TYPEC-304J-BCP16.pretty"
        'Ziisor_IPEX-1'      = "$installFwd/footprints/Ziisor_IPEX-1.pretty"
    }
    $footprintTable = Join-Path $configDirPath 'fp-lib-table'
    Update-LibTable -TablePath $footprintTable -TableName 'fp_lib_table' -Uris $footprintUris
    Write-Host "Registered $($footprintUris.Count) footprint libraries in $footprintTable"

    $symbolUris = [ordered]@{
        'easyeda2kicad'      = "$installFwd/symbols/easyeda2kicad.kicad_sym"
        'IPEX-1'             = "$installFwd/symbols/IPEX-1.kicad_sym"
        'JST_PH_2P'          = "$installFwd/symbols/JST_PH_2P.kicad_sym"
        'PinHeader_2P'       = "$installFwd/symbols/PinHeader_2P.kicad_sym"
        'Project_Components' = "$installFwd/symbols/Project_Components.kicad_sym"
        'SK-3296S-01-L2'     = "$installFwd/symbols/SK-3296S-01-L2.kicad_sym"
        'TYPEC-304J-BCP16'   = "$installFwd/symbols/TYPEC-304J-BCP16.kicad_sym"
        'Ziisor_IPEX-1'      = "$installFwd/symbols/Ziisor_IPEX-1.kicad_sym"
    }
    $symbolTable = Join-Path $configDirPath 'sym-lib-table'
    Update-LibTable -TablePath $symbolTable -TableName 'sym_lib_table' -Uris $symbolUris
    Write-Host "Registered $($symbolUris.Count) symbol libraries in $symbolTable"
}

Write-Host ''
Write-Host 'Done. Open KiCad -> Preferences -> Manage Footprint Libraries and Manage Symbol Libraries to verify the libraries.'
Write-Host 'The 3D models are installed next to the footprints and referenced by absolute path.'
