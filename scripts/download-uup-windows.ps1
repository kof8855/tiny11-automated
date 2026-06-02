#!/usr/bin/env pwsh
# download-uup-windows.ps1 - v4
# Downloads UUP files and builds Windows ISO with full version info output

$ErrorActionPreference = "Continue"

Write-Output "=== UUP Dump ISO Builder v4 ==="

# Copy UUP config if needed
if (-not (Test-Path "ConvertConfig.ini") -and (Test-Path "uup-config\ConvertConfig.ini")) {
    Write-Output "Copying UUP config..."
    Copy-Item -Path "uup-config\*" -Destination $PWD -Recurse -Force
}

# Step 1: Get converter
Write-Output "Step 1: Downloading converter..."
New-Item -ItemType Directory -Force -Path "files" | Out-Null

aria2c --no-conf --console-log-level=warn -x4 -s4 --allow-overwrite=true `
    --auto-file-renaming=false -d"files" -o"7zr.exe" `
    "https://uupdump.net/misc/7zr.exe" 2>&1

aria2c --no-conf --console-log-level=warn -x4 -s4 --allow-overwrite=true `
    --auto-file-renaming=false -d"files" -o"uup-converter-wimlib.7z" `
    "https://uupdump.net/misc/uup-converter-wimlib-v121.7z" 2>&1

if (Test-Path "files\uup-converter-wimlib.7z") {
    & "files\7zr.exe" x "-x!ConvertConfig.ini" "-x!CustomAppsList.txt" -y "files\uup-converter-wimlib.7z" 2>&1
    Write-Output "  Converter extracted"
} else {
    Write-Output "FATAL: converter download failed"
    exit 1
}

# Step 2: Get UUP file list
Write-Output "Step 2: Fetching UUP file list..."
$scriptUrl = "https://uupdump.net/get.php?id=7f6836ae-9517-4e27-9f76-5823e0b6744c&pack=zh-cn&edition=professional%3Bcore&aria2=2"
aria2c --no-conf --console-log-level=warn --allow-overwrite=true --auto-file-renaming=false `
    -o"aria2_script.txt" $scriptUrl 2>&1

$errLine = Select-String -Path "aria2_script.txt" -Pattern "UUPDUMP_ERROR" -SimpleMatch
if ($errLine) { Write-Output "UUP Error: $errLine"; exit 1 }

$fileCount = (Get-Content "aria2_script.txt" | Where-Object { $_ -match "^http" }).Count
Write-Output "  $fileCount files to download"

# Step 3: Download UUP files
Write-Output "Step 3: Downloading UUP files..."
New-Item -ItemType Directory -Force -Path "UUPs" | Out-Null
aria2c --no-conf --console-log-level=warn -x16 -s16 -j5 -c -R -d"UUPs" -i"aria2_script.txt" 2>&1

# Step 4: Run converter
Write-Output "Step 4: Running UUP converter..."
"y" | cmd /c "convert-UUP.cmd" 2>&1

# Step 5: Find and extract version from ISO name
Write-Output "Step 5: Finding generated ISO..."
$iso = Get-ChildItem -Path "." -Filter "*.iso" -ErrorAction SilentlyContinue |
       Sort-Object Length -Descending | Select-Object -First 1

if (-not $iso) {
    $iso = Get-ChildItem -Path "." -Recurse -Filter "*.iso" -ErrorAction SilentlyContinue |
           Sort-Object Length -Descending | Select-Object -First 1
}

if ($iso -and $iso.Length -gt 500MB) {
    $gb = [math]::Round($iso.Length / 1GB, 2)
    Write-Output "Found ISO: $($iso.Name) (${gb}GB)"
    
    # Extract build number from ISO name (e.g., "22621.1_MULTI_X64_ZH-CN.ISO")
    # Patterns: "22621.1_" or "22631.7079_" or "22621_MULTI"
    $buildNumber = ""
    $origIsoName = $iso.Name
    if ($origIsoName -match "(\d+\.\d+)[_\."]) {
        $buildNumber = $Matches[1]
    } elseif ($origIsoName -match "(\d{5})[_\."]) {
        $buildNumber = $Matches[1]
    }
    
    Write-Output "Detected build: '$buildNumber' from '$origIsoName'"
    
    # Save version info and original ISO name for downstream steps
    $origIsoName | Out-File -FilePath "uup_version.txt" -Force
    $buildNumber | Out-File -FilePath "uup_build.txt" -NoNewline -Force
    
    # Output in a parseable format for the workflow
    Write-Output "UUP_VERSION=$buildNumber"
    
    # Move to Win11_Source.iso
    if ($iso.Name -ne "Win11_Source.iso") {
        Move-Item -Path $iso.FullName -Destination "Win11_Source.iso" -Force
    }
    Write-Output "ISO ready: Win11_Source.iso"
} else {
    Write-Output "FATAL: No ISO generated!"
    exit 1
}
