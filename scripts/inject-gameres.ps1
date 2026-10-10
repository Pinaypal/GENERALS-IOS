<#
.SYNOPSIS
    Injects local Command & Conquer Generals Zero Hour retail game assets into the iOS Shell IPA on Windows.

.DESCRIPTION
    Takes the lightweight GeneralsXZH-unsigned.ipa built via GitHub Actions and injects
    your local retail game assets into Payload/GeneralsXZH.app/GameData/.
    Uses pure .NET ZipFile methods so no external tools (like 7-Zip) are required.

.EXAMPLE
    .\scripts\inject-gameres.ps1
    .\scripts\inject-gameres.ps1 -GameDir "C:\Program Files (x86)\Steam\steamapps\common\Command & Conquer Generals - Zero Hour"
    .\scripts\inject-gameres.ps1 -IpaPath "GeneralsXZH-unsigned.ipa" -OutputPath "GeneralsZH-ready-to-sideload.ipa"
#>

param(
    [Parameter(Position = 0)]
    [string]$IpaPath = "GeneralsXZH-unsigned.ipa",

    [Parameter(Position = 1)]
    [string]$GameDir = "",

    [Parameter(Position = 2)]
    [string]$OutputPath = "GeneralsXZH-ready-to-sideload.ipa"
)

$ErrorActionPreference = "Stop"

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host " Command & Conquer Generals: Zero Hour iOS Asset Injector " -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

# Resolve project root
$ProjectRoot = (Resolve-Path "$PSScriptRoot\..").Path

# 1. Resolve IPA path
if (-not (Test-Path $IpaPath)) {
    $candidates = @(
        (Join-Path $ProjectRoot $IpaPath),
        (Join-Path $ProjectRoot "build\$IpaPath"),
        (Join-Path $ProjectRoot "GeneralsXZH-unsigned.ipa"),
        (Join-Path $ProjectRoot "build\GeneralsXZH-unsigned.ipa"),
        (Join-Path $ProjectRoot "GeneralsXZH.ipa"),
        (Join-Path (Get-Location) "*.ipa")
    )
    foreach ($c in $candidates) {
        $found = Get-Item $c -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($found -and (Test-Path $found.FullName)) {
            $IpaPath = $found.FullName
            break
        }
    }
}

if (-not (Test-Path $IpaPath)) {
    Write-Error "Could not find iOS IPA at '$IpaPath'.`nDownload 'GeneralsXZH-unsigned.ipa' from GitHub Actions and place it in the project root."
    exit 1
}

Write-Host "--> Shell IPA: $IpaPath" -ForegroundColor Green

# 2. Resolve retail Game directory
if ([string]::IsNullOrWhiteSpace($GameDir)) {
    # Check gameres-export first
    $exported = Join-Path $ProjectRoot "gameres-export"
    if (Test-Path (Join-Path $exported "INIZH.big")) {
        $GameDir = $exported
    }
}

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
        "C:\Program Files (x86)\Origin Games\Command and Conquer Generals Zero Hour",
        "C:\Games\Command and Conquer Generals Zero Hour",
        "D:\Games\Command and Conquer Generals Zero Hour"
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
    Write-Host "`nCould not auto-detect retail Zero Hour directory." -ForegroundColor Yellow
    $entered = Read-Host "Please enter the full path to your Zero Hour install folder"
    if ([string]::IsNullOrWhiteSpace($entered) -or -not (Test-Path $entered)) {
        Write-Error "Invalid game directory specified. Aborting."
        exit 1
    }
    $GameDir = $entered.Trim('"').Trim("'")
}

# Auto-resolve Zero Hour subfolder if parent directory was provided
if (Test-Path (Join-Path $GameDir "Command and Conquer Generals Zero Hour")) {
    $GameDir = Join-Path $GameDir "Command and Conquer Generals Zero Hour"
} elseif (Test-Path (Join-Path $GameDir "Command & Conquer Generals - Zero Hour")) {
    $GameDir = Join-Path $GameDir "Command & Conquer Generals - Zero Hour"
}

Write-Host "--> Retail Game Source: $GameDir" -ForegroundColor Green

# 3. Verify core files
$iniZh = Get-ChildItem -Path $GameDir -Filter "*INIZH.big" -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $iniZh) {
    Write-Error "Could not find INIZH.big in '$GameDir'. Please ensure this is the Zero Hour installation folder."
    exit 1
}

Add-Type -AssemblyName System.IO.Compression.FileSystem

$TempFolder = Join-Path $env:TEMP ("generals_ipa_inject_" + [System.Guid]::NewGuid().ToString("N"))
if (Test-Path $TempFolder) { Remove-Item -Recurse -Force $TempFolder }

try {
    Write-Host "`n==> [1/4] Extracting Shell IPA ($IpaPath)..." -ForegroundColor Yellow
    [System.IO.Compression.ZipFile]::ExtractToDirectory((Resolve-Path $IpaPath).Path, $TempFolder)

    $AppDir = Get-ChildItem -Path (Join-Path $TempFolder "Payload") -Directory -Filter "*.app" | Select-Object -First 1
    if (-not $AppDir) {
        Write-Error "Invalid IPA: No .app directory found inside Payload/."
        exit 1
    }

    $TargetGameData = Join-Path $AppDir.FullName "GameData"
    if (-not (Test-Path $TargetGameData)) {
        New-Item -ItemType Directory -Path $TargetGameData -Force | Out-Null
    }

    Write-Host "==> [2/4] Injecting retail game assets from: $GameDir..." -ForegroundColor Yellow

    # Copy all .big files from root
    $bigFiles = Get-ChildItem -Path $GameDir -File -Filter "*.big"
    foreach ($file in $bigFiles) {
        Copy-Item -Path $file.FullName -Destination $TargetGameData -Force
        Write-Host "    + $($file.Name)" -ForegroundColor Gray
    }

    # Copy Data, Maps, Window, Movies directories if present
    $subDirs = @("Data", "Maps", "Window", "Movies")
    foreach ($dirName in $subDirs) {
        $sourceDir = Join-Path $GameDir $dirName
        if (Test-Path $sourceDir) {
            Write-Host "    + Copying folder: $dirName..." -ForegroundColor Gray
            Copy-Item -Path $sourceDir -Destination $TargetGameData -Recurse -Force
        }
    }

    # Check for Steam base game folder: ZH_Generals
    $zhGenDir = Join-Path $GameDir "ZH_Generals"
    if (Test-Path $zhGenDir) {
        Write-Host "    + Copying base game data (ZH_Generals)..." -ForegroundColor Gray
        Copy-Item -Path $zhGenDir -Destination $TargetGameData -Recurse -Force
    } else {
        # Search adjacent folder for base Generals (Command & Conquer Generals)
        $parent = Split-Path $GameDir -Parent
        $baseGeneralsCandidates = @(
            (Join-Path $parent "Command & Conquer Generals"),
            (Join-Path $parent "Command and Conquer Generals"),
            (Join-Path $parent "Generals")
        )
        foreach ($cand in $baseGeneralsCandidates) {
            if (Test-Path (Join-Path $cand "INI.big")) {
                Write-Host "    + Detected base game at: $cand. Creating ZH_Generals..." -ForegroundColor Cyan
                $destZhGen = Join-Path $TargetGameData "ZH_Generals"
                New-Item -ItemType Directory -Path $destZhGen -Force | Out-Null
                Get-ChildItem -Path $cand -File -Filter "*.big" | ForEach-Object {
                    Copy-Item -Path $_.FullName -Destination $destZhGen -Force
                }
                foreach ($d in @("Data", "Maps", "Window")) {
                    $srcSub = Join-Path $cand $d
                    if (Test-Path $srcSub) {
                        Copy-Item -Path $srcSub -Destination $destZhGen -Recurse -Force
                    }
                }
                break
            }
        }
    }

    # Ensure Core Fonts exist
    $fontsTarget = Join-Path $TargetGameData "fonts"
    if (-not (Test-Path (Join-Path $fontsTarget "arial.ttf"))) {
        Write-Host "    + Staging Windows TrueType fonts..." -ForegroundColor Gray
        New-Item -ItemType Directory -Path $fontsTarget -Force | Out-Null
        $winFonts = "C:\Windows\Fonts"
        if (Test-Path (Join-Path $winFonts "arial.ttf")) {
            Copy-Item (Join-Path $winFonts "arial.ttf") (Join-Path $fontsTarget "arial.ttf") -Force
        }
        if (Test-Path (Join-Path $winFonts "arialbd.ttf")) {
            Copy-Item (Join-Path $winFonts "arialbd.ttf") (Join-Path $fontsTarget "arialbold.ttf") -Force
        }
        if (Test-Path (Join-Path $winFonts "cour.ttf")) {
            Copy-Item (Join-Path $winFonts "cour.ttf") (Join-Path $fontsTarget "couriernew.ttf") -Force
        }
        if (Test-Path (Join-Path $winFonts "times.ttf")) {
            Copy-Item (Join-Path $winFonts "times.ttf") (Join-Path $fontsTarget "timesnewroman.ttf") -Force
        }
    }

    # Ensure Configuration files exist
    $configSrc = Join-Path $ProjectRoot "ios\config"
    if (Test-Path (Join-Path $configSrc "dxvk.conf")) {
        Copy-Item (Join-Path $configSrc "dxvk.conf") (Join-Path $TargetGameData "dxvk.conf") -Force
    }
    if (Test-Path (Join-Path $configSrc "Options.ini")) {
        Copy-Item (Join-Path $configSrc "Options.ini") (Join-Path $TargetGameData "DefaultOptions.ini") -Force
    }

    # Clean out any stray Windows executables from TargetGameData
    Get-ChildItem -Path $TargetGameData -File | Where-Object {
        $_.Extension -match "\.(exe|dll|dat|ico|lcf|doc|txt)$"
    } | Remove-Item -Force -ErrorAction SilentlyContinue

    $FullOutputPath = Join-Path $ProjectRoot $OutputPath
    if (Test-Path $FullOutputPath) {
        Remove-Item -Force $FullOutputPath
    }

    Write-Host "==> [3/4] Repackaging complete IPA into: $FullOutputPath..." -ForegroundColor Yellow
    [System.IO.Compression.ZipFile]::CreateFromDirectory($TempFolder, $FullOutputPath)

    $finalSizeMb = [math]::Round((Get-Item $FullOutputPath).Length / 1MB, 2)
    Write-Host "==> [4/4] Done!" -ForegroundColor Green
    Write-Host "`nSUCCESS: Created $OutputPath ($finalSizeMb MB)" -ForegroundColor Green
    Write-Host @"

Next Steps to Play on iPhone or iPad:
--------------------------------------
1. Connect your iPhone or iPad to your PC via USB.
2. Open Sideloadly (or AltServer / TrollStore).
3. Drag and drop '$FullOutputPath' into Sideloadly.
4. Enter your Apple ID and click 'Start' to install.
5. On your iOS device, go to Settings > General > VPN & Device Management and Trust your developer profile.
6. Launch Generals Zero Hour and enjoy native RTS with touch controls!
"@ -ForegroundColor White

}
finally {
    if (Test-Path $TempFolder) {
        Remove-Item -Recurse -Force $TempFolder -ErrorAction SilentlyContinue
    }
}
