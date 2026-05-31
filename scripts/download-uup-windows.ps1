#!/usr/bin/env pwsh
# download-uup-windows.ps1 - v3
# Uses the uup_download_windows.cmd directly with stdin redirect to handle pauses

$ErrorActionPreference = "Continue"

Write-Output "=== UUP Dump ISO Builder v3 ==="

# First, copy UUP config files from uup-config/ if not already in CWD
if (-not (Test-Path "ConvertConfig.ini") -and (Test-Path "uup-config\ConvertConfig.ini")) {
    Write-Output "Copying UUP config from uup-config/..."
    Copy-Item -Path "uup-config\*" -Destination $PWD -Recurse -Force
}

Write-Output "Current directory: $(Get-Location)"
Write-Output "Files in CWD:"
Get-ChildItem | ForEach-Object { Write-Output "  $($_.Name)" }

# Step 1: Get aria2c.exe via get_aria2.ps1
Write-Output "Step 1: Getting aria2c..."
if (Test-Path "files\get_aria2.ps1") {
    Write-Output "  Running get_aria2.ps1..."
    & "$PWD\files\get_aria2.ps1" 2>&1
} else {
    Write-Output "  No get_aria2.ps1 found"
    Get-ChildItem "files" -Recurse | ForEach-Object { Write-Output "    $($_.FullName)" }
}
if (Test-Path "files\aria2c.exe") {
    Write-Output "  aria2c.exe ready!"
} else {
    Write-Output "  aria2c.exe not found, using system aria2c"
}

# Step 2: Download converter files
Write-Output "Step 2: Downloading converter..."
if (-not (Test-Path "files\7zr.exe")) {
    $urls = @(
        @{url="https://uupdump.net/misc/7zr.exe"; file="files\7zr.exe"},
        @{url="https://uupdump.net/misc/uup-converter-wimlib-v121.7z"; file="files\uup-converter-wimlib.7z"}
    )
    foreach ($item in $urls) {
        Write-Output "  Downloading: $($item.file)"
        # Try aria2c first (Windows runner has it installed)
        aria2c --no-conf --console-log-level=warn -x4 -s4 --allow-overwrite=true `
            --auto-file-renaming=false -d"files" -o"$(Split-Path $item.file -Leaf)" $item.url 2>&1
        if (-not (Test-Path $item.file)) {
            Write-Output "  aria2c failed, trying Invoke-WebRequest..."
            try {
                Invoke-WebRequest -Uri $item.url -OutFile $item.file -UseBasicParsing -TimeoutSec 300
            } catch {
                Write-Output "  ERROR: $_"
            }
        }
        if (Test-Path $item.file) {
            $size = [math]::Round((Get-Item $item.file).Length / 1KB)
            Write-Output "  OK: $($item.file) (${size}KB)"
        } else {
            Write-Output "  FATAL: $($item.file) download failed"
            exit 1
        }
    }
} else {
    Write-Output "  Converter already downloaded"
}

# Step 3: Extract converter
Write-Output "Step 3: Extracting converter..."
if (Test-Path "files\uup-converter-wimlib.7z") {
    & "files\7zr.exe" x "-x!ConvertConfig.ini" "-x!CustomAppsList.txt" -y "files\uup-converter-wimlib.7z" 2>&1
    if (Test-Path "convert-UUP.cmd") {
        Write-Output "  Converter extracted successfully"
    } else {
        Write-Output "  FATAL: convert-UUP.cmd not found after extraction"
        exit 1
    }
} else {
    Write-Output "  No converter archive found"
    exit 1
}

# Step 4: Download UUP files using the UUP dump's own aria2 script
Write-Output "Step 4: Getting UUP aria2 script..."
$scriptUrl = "https://uupdump.net/get.php?id=7f6836ae-9517-4e27-9f76-5823e0b6744c&pack=zh-cn&edition=professional%3Bcore&aria2=2"
aria2c --no-conf --console-log-level=warn --allow-overwrite=true --auto-file-renaming=false -o"aria2_script.txt" $scriptUrl 2>&1

if (-not (Test-Path "aria2_script.txt")) {
    Write-Output "  FATAL: Failed to get UUP aria2 script"
    exit 1
}

$errMsg = Select-String -Path "aria2_script.txt" -Pattern "UUPDUMP_ERROR" -SimpleMatch
if ($errMsg) { Write-Output "  UUP Error: $errMsg"; exit 1 }

$fileCount = (Get-Content "aria2_script.txt" | Where-Object { $_ -match "^http" }).Count
Write-Output "  Got script with $fileCount files"

# Step 5: Download the UUP files
Write-Output "Step 5: Downloading UUP files..."
New-Item -ItemType Directory -Force -Path "UUPs" | Out-Null
aria2c --no-conf --console-log-level=warn -x16 -s16 -j5 -c -R -d"UUPs" -i"aria2_script.txt" 2>&1
$files = Get-ChildItem "UUPs" -File
$totalMB = [math]::Round(($files | Measure-Object -Property Length -Sum).Sum / 1MB)
Write-Output "  Downloaded $($files.Count) files, $totalMB MB"

if ($files.Count -lt 10) {
    Write-Output "  FATAL: Too few UUP files downloaded"
    exit 1
}

# Step 6: Run the converter
Write-Output "Step 6: Running UUP converter..."
Write-Output "  Args: AutoStart=1 Cleanup=1 AutoExit=1"

# Feed 'y' to any prompts via stdin
"y" | cmd /c "convert-UUP.cmd" 2>&1
$exitCode = $LASTEXITCODE
Write-Output "  Converter finished, exit code: $exitCode"

# Step 7: Find ISO
Write-Output "Step 7: Locating ISO..."
$iso = Get-ChildItem -Path "." -Filter "*.iso" -ErrorAction SilentlyContinue | 
       Sort-Object Length -Descending | Select-Object -First 1
if (-not $iso) {
    $iso = Get-ChildItem -Path "." -Recurse -Filter "*.iso" -ErrorAction SilentlyContinue | 
           Sort-Object Length -Descending | Select-Object -First 1
}

if ($iso -and $iso.Length -gt 500MB) {
    $gb = [math]::Round($iso.Length / 1GB, 2)
    Write-Output "SUCCESS: $($iso.Name) - ${gb}GB"
    if ($iso.Name -ne "Win11_Source.iso") { Move-Item -Path $iso.FullName -Destination "Win11_Source.iso" -Force }
    Write-Output "ISO ready: Win11_Source.iso"
} else {
    Write-Output "FATAL: No ISO generated!"
    Get-ChildItem | Where-Object { $_.Length -gt 10MB } | ForEach-Object { 
        Write-Output "  $($_.Name) ($([math]::Round($_.Length/1MB,1)) MB)" 
    }
    exit 1
}
