# ============================================================================
# YOLOs-CPP Windows Build Script (PowerShell)
# ============================================================================
# Usage:
#   .\build.ps1                    # Build with default settings (CPU)
#   .\build.ps1 -GPU               # Build with GPU support, auto-detect CUDA 13/12
#   .\build.ps1 -GPU13             # Build with ONNX Runtime CUDA 13 package
#   .\build.ps1 -GPU12             # Build with ONNX Runtime CUDA 12 package
#   .\build.ps1 -Version 1.26.0    # Specify ONNX Runtime version
# ============================================================================

param(
    [string]$Version = "1.26.0",
    [switch]$GPU,
    [switch]$GPU12,
    [switch]$GPU13,
    [switch]$Clean,
    [switch]$Help
)

$ErrorActionPreference = "Stop"

# Colors for output
function Write-Green { param($msg) Write-Host $msg -ForegroundColor Green }
function Write-Yellow { param($msg) Write-Host $msg -ForegroundColor Yellow }
function Write-Red { param($msg) Write-Host $msg -ForegroundColor Red }
function Write-Cyan { param($msg) Write-Host $msg -ForegroundColor Cyan }
function Test-DllOnPath {
    param([string]$DllName)
    & where.exe $DllName *> $null
    return $LASTEXITCODE -eq 0
}

if ($Help) {
    Write-Host @"
YOLOs-CPP Windows Build Script

Usage:
    .\build.ps1 [options]

Options:
    -Version <ver>  ONNX Runtime version (default: 1.26.0)
    -GPU            Enable GPU/CUDA support and auto-detect CUDA 13/12
    -GPU13          Enable GPU/CUDA support with CUDA 13 package
    -GPU12          Enable GPU/CUDA support with CUDA 12 package
    -Clean          Clean build directory before building
    -Help           Show this help message

Examples:
    .\build.ps1                     # CPU build
    .\build.ps1 -GPU                # GPU build, auto-detect CUDA 13/12
    .\build.ps1 -GPU13              # CUDA 13 GPU build
    .\build.ps1 -GPU12              # CUDA 12 GPU build
    .\build.ps1 -Clean -GPU13       # Clean CUDA 13 GPU build
"@
    exit 0
}

Write-Cyan "============================================"
Write-Cyan "  YOLOs-CPP Windows Build Script"
Write-Cyan "============================================"
Write-Host ""

$CudaMajor = 0
if ($GPU13) {
    $CudaMajor = 13
} elseif ($GPU12) {
    $CudaMajor = 12
} elseif ($GPU) {
    $hasCuda13 = (Test-DllOnPath "cudart64_13.dll") -or
                 (Test-Path "$env:ProgramFiles\NVIDIA GPU Computing Toolkit\CUDA\v13.*\bin\x64\cudart64_13.dll") -or
                 (Test-Path "$env:ProgramFiles\NVIDIA GPU Computing Toolkit\CUDA\v13.*\bin\cudart64_13.dll")
    $hasCuda12 = (Test-DllOnPath "cudart64_12.dll") -or
                 (Test-Path "$env:ProgramFiles\NVIDIA GPU Computing Toolkit\CUDA\v12.*\bin\x64\cudart64_12.dll") -or
                 (Test-Path "$env:ProgramFiles\NVIDIA GPU Computing Toolkit\CUDA\v12.*\bin\cudart64_12.dll")

    if ($hasCuda13) {
        $CudaMajor = 13
    } elseif ($hasCuda12) {
        $CudaMajor = 12
    } else {
        Write-Red "Could not auto-detect CUDA 13 or CUDA 12 runtime DLLs. Use -GPU13 or -GPU12, or add CUDA bin to PATH."
        exit 1
    }
}

# Determine ONNX Runtime package
if ($CudaMajor -eq 13) {
    $OrtPackage = "onnxruntime-win-x64-gpu_cuda13-$Version"
    $OrtUrl = "https://github.com/microsoft/onnxruntime/releases/download/v$Version/onnxruntime-win-x64-gpu_cuda13-$Version.zip"
    Write-Host "Building with GPU support: CUDA 13.x ABI"
} elseif ($CudaMajor -eq 12) {
    $OrtPackage = "onnxruntime-win-x64-gpu-$Version"
    $OrtUrl = "https://github.com/microsoft/onnxruntime/releases/download/v$Version/onnxruntime-win-x64-gpu-$Version.zip"
    Write-Host "Building with GPU support: CUDA 12.x ABI"
} else {
    $OrtPackage = "onnxruntime-win-x64-$Version"
    $OrtUrl = "https://github.com/microsoft/onnxruntime/releases/download/v$Version/onnxruntime-win-x64-$Version.zip"
    Write-Host "Building with CPU support"
}

$OrtDir = Join-Path $PSScriptRoot $OrtPackage
$ZipFile = Join-Path $PSScriptRoot "$OrtPackage.zip"
$ExtractDir = Join-Path $PSScriptRoot "_ort_extract_$OrtPackage"

# Download ONNX Runtime if not present
if (-not (Test-Path $OrtDir)) {
    try {
        if (-not (Test-Path $ZipFile)) {
            Write-Yellow "Downloading ONNX Runtime $Version..."
            Write-Host "  $OrtUrl"
            Invoke-WebRequest -Uri $OrtUrl -OutFile $ZipFile -UseBasicParsing
        } else {
            Write-Host "Using existing ONNX Runtime archive: $ZipFile"
        }

        Write-Host "Extracting..."
        Remove-Item -Recurse -Force $ExtractDir -ErrorAction SilentlyContinue
        New-Item -ItemType Directory -Force -Path $ExtractDir | Out-Null
        & tar -xf $ZipFile -C $ExtractDir
        if ($LASTEXITCODE -ne 0) { throw "Failed to extract ONNX Runtime archive" }

        $extracted = Get-ChildItem -Path $ExtractDir -Directory | Select-Object -First 1
        if (-not $extracted) { throw "ONNX Runtime archive did not contain an extracted directory" }

        Remove-Item -Recurse -Force $OrtDir -ErrorAction SilentlyContinue
        Move-Item -LiteralPath $extracted.FullName -Destination $OrtDir
        Remove-Item -Recurse -Force $ExtractDir -ErrorAction SilentlyContinue
        Remove-Item $ZipFile
        Write-Green "ONNX Runtime downloaded successfully"
    } catch {
        Remove-Item -Recurse -Force $ExtractDir -ErrorAction SilentlyContinue
        Write-Red "Failed to download ONNX Runtime: $_"
        Write-Host "Please download manually from: $OrtUrl"
        exit 1
    }
} else {
    Write-Host "Using existing ONNX Runtime at: $OrtDir"
}

# Create build directory
$BuildDir = Join-Path $PSScriptRoot "build"
if ($Clean -and (Test-Path $BuildDir)) {
    Write-Yellow "Cleaning build directory..."
    Remove-Item -Recurse -Force $BuildDir
}
New-Item -ItemType Directory -Force -Path $BuildDir | Out-Null

# Configure with CMake
Write-Cyan "Configuring with CMake..."
Push-Location $BuildDir

try {
    $CmakeArgs = @(
        "..",
        "-DONNXRUNTIME_DIR=$OrtDir",
        "-DYOLOS_ORT_CUDA_MAJOR=$CudaMajor",
        "-DCMAKE_BUILD_TYPE=Release"
    )
    
    # Use Visual Studio generator on Windows
    if (Get-Command "cmake" -ErrorAction SilentlyContinue) {
        cmake @CmakeArgs
        if ($LASTEXITCODE -ne 0) { throw "CMake configuration failed" }
    } else {
        Write-Red "CMake not found. Please install CMake and add it to PATH."
        exit 1
    }
    
    # Build
    Write-Cyan "Building..."
    cmake --build . --config Release --parallel
    if ($LASTEXITCODE -ne 0) { throw "Build failed" }
    
    Write-Green ""
    Write-Green "============================================"
    Write-Green "  Build Successful!"
    Write-Green "============================================"
    Write-Host ""
    Write-Host "Executables are in: $BuildDir\Release\"
    Write-Host ""
    Write-Host "Run:"
    Write-Host "  .\Release\image_inference.exe ..\models\yolo11n.onnx ..\data\dog.jpg"
    
} finally {
    Pop-Location
}
