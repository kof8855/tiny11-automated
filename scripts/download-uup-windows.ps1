#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Downloads Windows 11 from UUP Dump and builds an ISO on Windows.
    Designed for GitHub Actions windows-latest runner.
#>

param(
    [string]$UupSetId = "7f6836ae-9517-4e27-9f76-5823e0b6744c",
    [string]$Pack = "zh-cn",
    [string]$Edition = "professional%3Bcore",
    [string]$OutputIso = "Win11_Source.iso"
)

$startTime = Get-Date

function Write-Step {
    param([string]$Message)
    Write-Output "[$(Get-Date -Format 'HH:mm:ss')] $Message"
}

Write-Step "=== UUP Dump ISO Builder for Windows ==="
Write-Step "SetID=$UupSetId Pack=$Pack Edition=$Edition"

# Step 1: Verify tools
Write-Step "Checking tools..."
if (-not (Get-Command aria2c -ErrorAction SilentlyContinue)) {
    Write-Step "aria2c not found, installing via choco..."
    choco install aria2 -y --no-progress 2>&1 | Out-Null
}
$aria2 = (Get-Command aria2c).Source
Write-Step "aria2c: $aria2"

# Step 2: Create dirs & copy config
New-Item -ItemType Directory -Force -Path "files" | Out-Null
New-Item -ItemType Directory -Force -Path "UUPs" | Out-Null

if (Test-Path "ConvertConfig.ini") {
    Write-Step "ConvertConfig.ini found (custom config)"
    Get-Content "ConvertConfig.ini" | Select-String "AutoExit|AutoStart|SkipApps"
}

# Step 3: Download converter
Write-Step "Downloading 7zr.exe..."
aria2c --no-conf --console-log-level=warn -x4 -s4 `
    --allow-overwrite=true --auto-file-renaming=false `
    -d"files" -o"7zr.exe" "https://uupdump.net/misc/7zr.exe" 2>&1
if (-not (Test-Path "files\7zr.exe")) { throw "7zr.exe download failed" }

Write-Step "Downloading uup-converter-wimlib..."
aria2c --no-conf --console-log-level=warn -x4 -s4 `
    --allow-overwrite=true --auto-file-renaming=false `
    -d"files" -o"uup-converter-wimlib.7z" "https://uupdump.net/misc/uup-converter-wimlib-v121.7z" 2>&1
if (-not (Test-Path "files\uup-converter-wimlib.7z")) { throw "converter download failed" }

# Step 4: Extract converter
Write-Step "Extracting UUP converter..."
$7zr = "files\7zr.exe"
$conv = "files\uup-converter-wimlib.7z"
& $7zr -x!ConvertConfig.ini -x!CustomAppsList.txt -y x $conv 2>&1
if (-not (Test-Path "convert-UUP.cmd")) { throw "Converter extraction failed" }

Write-Step "Converter extracted. Files:"
Get-ChildItem -Path "." -Filter "*.cmd" | ForEach-Object { Write-Step "  $($_.Name)" }

# Step 5: Retrieve aria2 script for UUP
Write-Step "Fetching UUP aria2 script..."
$aria2Script = "aria2_script.txt"
$scriptUrl = "https://uupdump.net/get.php?id=$UupSetId&pack=$Pack&edition=$Edition&aria2=2"
aria2c --no-conf --console-log-level=warn --allow-overwrite=true `
    --auto-file-renaming=false -o"$aria2Script" $scriptUrl 2>&1

if (Test-Path $aria2Script) {
    $errLine = Select-String -Path $aria2Script -Pattern "#UUPDUMP_ERROR:" -SimpleMatch
    if ($errLine) {
        throw "UUP Dump server error: $($errLine.Line)"
    }
    $fileCount = (Get-Content $aria2Script | Where-Object { $_ -match "^http" }).Count
    Write-Step "UUP script retrieved - $fileCount files to download"
} else {
    throw "Failed to retrieve UUP aria2 script"
}

# Step 6: Download UUP files
Write-Step "Downloading UUP files (this may take 15-30 minutes)..."
aria2c --no-conf --console-log-level=warn -x16 -s16 -j5 -c -R `
    -d"UUPs" -i"$aria2Script" 2>&1

$uupCount = (Get-ChildItem "UUPs" -File).Count
Write-Step "UUP download complete - $uupCount files in UUPs/"

# Step 7: Run converter
Write-Step "Starting UUP converter (convert-UUP.cmd)..."
Write-Step "This builds the Windows ISO from UUP files (~5-10 min)"

# Run CMD and capture output
$proc = Start-Process -FilePath "cmd.exe" -ArgumentList "/c convert-UUP.cmd" `
    -NoNewWindow -Wait -PassThru -RedirectStandardOutput "converter_out.txt" `
    -RedirectStandardError "converter_err.txt"
$exitCode = $proc.ExitCode

if (Test-Path "converter_out.txt") {
    Write-Step "Last 20 lines of converter output:"
    Get-Content "converter_out.txt" -Tail 20 | ForEach-Object { Write-Step "  $_" }
}

Write-Step "Converter exit code: $exitCode"

# Step 8: Find generated ISO - look broadly
Write-Step "Searching for generated ISO..."
$iso = $null
# Check current directory for .iso or .ISO
$iso = Get-ChildItem -Path "." -Filter "*.iso" -ErrorAction SilentlyContinue | 
       Where-Object { $_.Length -gt 1GB } | Sort-Object Length -Descending | Select-Object -First 1
if (-not $iso) {
    $iso = Get-ChildItem -Path "." -Recurse -Filter "*.iso" -ErrorAction SilentlyContinue | 
           Where-Object { $_.Length -gt 1GB } | Sort-Object Length -Descending | Select-Object -First 1
}

if ($iso) {
    Write-Step "Found ISO: $($iso.Name) - $([math]::Round($iso.Length/1GB,2)) GB"
    if ($iso.Name -ne $OutputIso) {
        Move-Item -Path $iso.FullName -Destination $OutputIso -Force
        Write-Step "Renamed to $OutputIso"
    }
} else {
    Write-Step "ERROR: No ISO found!"
    Write-Step "Directory listing:"
    Get-ChildItem -Path "." | ForEach-Object { Write-Step "  $($_.Name) ($([math]::Round($_.Length/1MB,1)) MB)" }
    throw "ISO was not generated"
}

$elapsed = (Get-Date) - $startTime
Write-Step "=== UUP ISO build completed in $([math]::Round($elapsed.TotalMinutes,1)) minutes ==="
