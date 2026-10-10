<#
.SYNOPSIS
    Prepares and exports clean retail assets for Command & Conquer Generals Zero Hour.

.DESCRIPTION
    Scans your retail install (Steam, EA App, CD), extracts all required game assets,
    sanitizes them (removes Windows executables and unnecessary installers), and
    stages them into gameres-export/ for build packaging or inspection.
#>

param(
    [Parameter(Position = 0)]
    [string]$GameDir = "",

    [Parameter(Position = 1)]
    [string]$ExportDir = "gameres-export"
)

$ErrorActionPreference = "Stop"

$ProjectRoot = (Resolve-Path "$PSScriptRoot\..").Path
$TargetExport = Join-Path $ProjectRoot $ExportDir

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host " Command & Conquer Generals: Zero Hour Asset Preparation  " -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

if ([string]::IsNullOrWhiteSpace($GameDir)) {
    $searchPaths = @(
        "C:\Program Files (x86)\Steam\steamapps\common\Command & Conquer Generals - Zero Hour",
        "C:\Program Files (x86)\Steam\steamapps\common\Command and Conquer Generals Zero Hour",
        "D:\SteamLibrary\steamapps\common\Command & Conquer Generals - Zero Hour",
        "D:\SteamLibrary\steamapps\common\Command and Conquer Generals Zero Hour",
        "E:\SteamLibrary\steamapps\common\Command & Conquer Generals - Zero Hour",
        "E:\SteamLibrary\steamapps\common\Command and Conquer Generals Zero Hour",
        "F:\SteamLibrary\steamapps\common\Command & Conquer Generals - Zero Hour",
        "C:\Program Files\EA Games\Command & Conquer Generals Zero Hour",
        "C:\Program Files (x86)\EA Games\Command & Conquer Generals Zero Hour",
        "C:\Program Files (x86)\Electronic Arts\Command & Conquer Generals Zero Hour",
        "C:\Program Files (x86)\Origin Games\Command and Conquer Generals Zero Hour"
    )

    foreach ($p in $searchPaths) {
        if (Test-Path $p) {
            $check = Get-ChildItem -Path $p -Filter "*INIZH.big" -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($check) {
                $GameDir = $p
                break
            }
        }
    }
}

if ([string]::IsNullOrWhiteSpace($GameDir) -or -not (Test-Path $GameDir)) {
    $GameDir = Read-Host "Please enter the full path to your Zero Hour install folder"
}

if ([string]::IsNullOrWhiteSpace($GameDir) -or -not (Test-Path $GameDir)) {
    Write-Error "Invalid game directory. Aborting."
    exit 1
}

Write-Host "--> Source: $GameDir" -ForegroundColor Green
Write-Host "--> Destination: $TargetExport" -ForegroundColor Green

if (Test-Path $TargetExport) {
    Remove-Item -Recurse -Force $TargetExport
}
New-Item -ItemType Directory -Path $TargetExport -Force | Out-Null

Write-Host "`nCopying Zero Hour .big archives..." -ForegroundColor Yellow
Get-ChildItem -Path $GameDir -File -Filter "*.big" | ForEach-Object {
    Copy-Item $_.FullName -Destination $TargetExport -Force
    Write-Host "  + $($_.Name)" -ForegroundColor Gray
}

# Copy folders
foreach ($folder in @("Data", "Maps", "Window", "Movies")) {
    $src = Join-Path $GameDir $folder
    if (Test-Path $src) {
        Write-Host "Copying folder: $folder..." -ForegroundColor Yellow
        Copy-Item -Path $src -Destination $TargetExport -Recurse -Force
    }
}

# Copy ZH_Generals if present
$zhGen = Join-Path $GameDir "ZH_Generals"
if (Test-Path $zhGen) {
    Write-Host "Copying base game data (ZH_Generals)..." -ForegroundColor Yellow
    Copy-Item -Path $zhGen -Destination $TargetExport -Recurse -Force
} else {
    $parent = Split-Path $GameDir -Parent
    foreach ($cand in @((Join-Path $parent "Command & Conquer Generals"), (Join-Path $parent "Command and Conquer Generals"), (Join-Path $parent "Generals"))) {
        if (Test-Path (Join-Path $cand "INI.big")) {
            Write-Host "Found base game at: $cand. Creating ZH_Generals..." -ForegroundColor Cyan
            $destBase = Join-Path $TargetExport "ZH_Generals"
            New-Item -ItemType Directory -Path $destBase -Force | Out-Null
            Get-ChildItem -Path $cand -File -Filter "*.big" | ForEach-Object {
                Copy-Item $_.FullName -Destination $destBase -Force
            }
            foreach ($d in @("Data", "Maps", "Window")) {
                if (Test-Path (Join-Path $cand $d)) {
                    Copy-Item -Path (Join-Path $cand $d) -Destination $destBase -Recurse -Force
                }
            }
            break
        }
    }
}

# Fonts
$fontsDest = Join-Path $TargetExport "fonts"
New-Item -ItemType Directory -Path $fontsDest -Force | Out-Null
$winFonts = "C:\Windows\Fonts"
if (Test-Path (Join-Path $winFonts "arial.ttf")) {
    Copy-Item (Join-Path $winFonts "arial.ttf") (Join-Path $fontsDest "arial.ttf") -Force
    Copy-Item (Join-Path $winFonts "arialbd.ttf") (Join-Path $fontsDest "arialbold.ttf") -Force
    Copy-Item (Join-Path $winFonts "cour.ttf") (Join-Path $fontsDest "couriernew.ttf") -Force
    Copy-Item (Join-Path $winFonts "times.ttf") (Join-Path $fontsDest "timesnewroman.ttf") -Force
    Write-Host "Copied Windows TrueType fonts." -ForegroundColor Gray
}

# Config
$cfgSrc = Join-Path $ProjectRoot "ios\config"
if (Test-Path (Join-Path $cfgSrc "dxvk.conf")) {
    Copy-Item (Join-Path $cfgSrc "dxvk.conf") (Join-Path $TargetExport "dxvk.conf") -Force
}
if (Test-Path (Join-Path $cfgSrc "Options.ini")) {
    Copy-Item (Join-Path $cfgSrc "Options.ini") (Join-Path $TargetExport "DefaultOptions.ini") -Force
}

$count = (Get-ChildItem -Path $TargetExport -Recurse).Count
Write-Host "`nSUCCESS: Prepared $count files in $TargetExport" -ForegroundColor Green
