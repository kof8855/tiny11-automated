#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Downloads Windows 11 from UUP Dump using Invoke-WebRequest.
    Designed for GitHub Actions windows-latest runner.
#>

param(
    [string]$UupSetId = "7f6836ae-9517-4e27-9f76-5823e0b6744c",
    [string]$Pack = "zh-cn",
    [string]$Edition = "professional%3Bcore",
    [string]$OutputIso = "Win11_Source.iso"
)

$startTime = Get-Date
Write-Output "=== UUP Dump ISO Builder v2 ==="
Write-Output "SetID=$UupSetId Edition=$Edition"

# Step 1: Create directories
New-Item -ItemType Directory -Force -Path "files" | Out-Null
New-Item -ItemType Directory -Force -Path "UUPs" | Out-Null

# Step 2: Download converter files using Invoke-WebRequest
Write-Output "Step 1/6: Downloading 7zr.exe..."
try {
    Invoke-WebRequest -Uri "https://uupdump.net/misc/7zr.exe" -OutFile "files\7zr.exe" -UseBasicParsing -TimeoutSec 120
    Write-Output "  7zr.exe downloaded ($((Get-Item 'files\7zr.exe').Length / 1KB) KB)"
} catch {
    Write-Output "  Invoke-WebRequest failed, trying aria2c..."
    aria2c --no-conf --console-log-level=warn -x4 -s4 --allow-overwrite=true -d"files" -o"7zr.exe" "https://uupdump.net/misc/7zr.exe" 2>&1
}

if (-not (Test-Path "files\7zr.exe")) { Write-Output "FATAL: 7zr.exe not found"; exit 1 }

Write-Output "Step 2/6: Downloading uup-converter-wimlib..."
try {
    Invoke-WebRequest -Uri "https://uupdump.net/misc/uup-converter-wimlib-v121.7z" -OutFile "files\uup-converter-wimlib.7z" -UseBasicParsing -TimeoutSec 300
    Write-Output "  converter downloaded ($((Get-Item 'files\uup-converter-wimlib.7z').Length / 1MB) MB)"
} catch {
    Write-Output "  Invoke-WebRequest failed, trying aria2c..."
    aria2c --no-conf --console-log-level=warn -x4 -s4 --allow-overwrite=true -d"files" -o"uup-converter-wimlib.7z" "https://uupdump.net/misc/uup-converter-wimlib-v121.7z" 2>&1
}

if (-not (Test-Path "files\uup-converter-wimlib.7z")) { Write-Output "FATAL: converter not found"; exit 1 }

# Step 3: Extract converter
Write-Output "Step 3/6: Extracting converter..."
$7zr = "files\7zr.exe"
$conv = "files\uup-converter-wimlib.7z"
& $7zr x "-x!ConvertConfig.ini" "-x!CustomAppsList.txt" -y $conv 2>&1

if (-not (Test-Path "convert-UUP.cmd")) { 
    Write-Output "FATAL: Converter extraction failed (no convert-UUP.cmd)"
    Get-ChildItem -Path "." | ForEach-Object { Write-Output "  $($_.Name)" }
    exit 1
}

# Step 4: Get aria2 script for UUP set
Write-Output "Step 4/6: Fetching UUP file list..."
$scriptUrl = "https://uupdump.net/get.php?id=$UupSetId&pack=$Pack&edition=$Edition&aria2=2"
$aria2Script = "aria2_script.txt"

try {
    Invoke-WebRequest -Uri $scriptUrl -OutFile $aria2Script -UseBasicParsing -TimeoutSec 60
} catch {
    aria2c --no-conf --console-log-level=warn --allow-overwrite=true -o"$aria2Script" $scriptUrl 2>&1
}

# Check for errors
$errLine = Select-String -Path $aria2Script -Pattern "#UUPDUMP_ERROR:" -SimpleMatch
if ($errLine) { 
    Write-Output "UUP Error: $($errLine.Line)"
    exit 1
}
$fileCount = (Get-Content $aria2Script | Where-Object { $_ -match "^http|^https" }).Count
Write-Output "  $fileCount files to download"

# Step 5: Download UUP files with aria2c
Write-Output "Step 5/6: Downloading UUP files (15-30 min)..."
aria2c --no-conf --console-log-level=warn -x16 -s16 -j5 -c -R -d"UUPs" -i"$aria2Script" 2>&1
$dlCount = (Get-ChildItem "UUPs" -File).Count
$dlSize = [math]::Round(((Get-ChildItem "UUPs" -File | Measure-Object -Property Length -Sum).Sum) / 1MB, 0)
Write-Output "  Downloaded $dlCount files ($dlSize MB)"

# Step 6: Run converter
Write-Output "Step 6/6: Running UUP converter..."
$convStart = Get-Date

# Set AutoExit=1 to prevent pause at end
Write-Output "  Verifying config..."
if (Test-Path "ConvertConfig.ini") {
    $autoExit = Select-String -Path "ConvertConfig.ini" -Pattern "AutoExit" -SimpleMatch
    Write-Output "  ConvertConfig.ini found: AutoExit=$($autoExit -ne $null)"
    Get-Content "ConvertConfig.ini" | ForEach-Object { Write-Output "    $_" }
}

# Run converter directly via cmd /c
Write-Output "  Running: cmd /c convert-UUP.cmd"
cmd /c "convert-UUP.cmd" 2>&1
$exitCode = $LASTEXITCODE
$convTime = [math]::Round(((Get-Date) - $convStart).TotalMinutes, 1)
Write-Output "  Converter exit code: $exitCode (${convTime}min)"

# Step 7: Find the generated ISO
Write-Output "Looking for generated ISO..."
$iso = Get-ChildItem -Path "." -Filter "*.iso" -ErrorAction SilentlyContinue | 
       Where-Object { $_.Length -gt 500MB } | Sort-Object Length -Descending | Select-Object -First 1

if (-not $iso) {
    $iso = Get-ChildItem -Path "." -Recurse -Filter "*.iso" -ErrorAction SilentlyContinue | 
           Where-Object { $_.Length -gt 500MB } | Sort-Object Length -Descending | Select-Object -First 1
}

if ($iso) {
    $gb = [math]::Round($iso.Length / 1GB, 2)
    Write-Output "SUCCESS: ISO found - $($iso.Name) (${gb}GB)"
    if ($iso.Name -ne $OutputIso) { Move-Item -Path $iso.FullName -Destination $OutputIso -Force }
    Write-Output "ISO ready at: $OutputIso"
} else {
    Write-Output "ERROR: No ISO found!"
    Get-ChildItem -Path "." | ForEach-Object { Write-Output "  $($_.Name) ($($_.Length / 1KB) KB)" }
    exit 1
}

$totalMin = [math]::Round(((Get-Date) - $startTime).TotalMinutes, 1)
Write-Output "=== UUP build completed in ${totalMin}min ==="
