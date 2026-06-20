@echo off
REM ============================================================================
REM YOLOs-CPP Windows Build Script
REM ============================================================================
REM Usage:
REM   build.bat             - Build with CPU support
REM   build.bat gpu         - Build with GPU support, auto-detect CUDA 13/12
REM   build.bat gpu13       - Build with ONNX Runtime CUDA 13 package
REM   build.bat gpu12       - Build with ONNX Runtime CUDA 12 package
REM   build.bat gpu13 1.26.0
REM ============================================================================

setlocal EnableExtensions EnableDelayedExpansion

pushd "%~dp0"
set "PROJECT_ROOT=%CD%"

REM ---------------------------------------------------------------------------
REM Basic configuration
REM ---------------------------------------------------------------------------
set "VERSION=1.26.0"
set "GPU=0"
set "CUDA_MAJOR=0"

set "VCPKG_ROOT=D:\vcpkg"
set "VCPKG_TOOLCHAIN=%VCPKG_ROOT%\scripts\buildsystems\vcpkg.cmake"
set "VCPKG_TRIPLET=x64-windows"

if not "%~2"=="" set "VERSION=%~2"

if "%~1"=="" (
    set "GPU=0"
) else if /I "%~1"=="cpu" (
    set "GPU=0"
) else if /I "%~1"=="gpu13" (
    set "GPU=1"
    set "CUDA_MAJOR=13"
) else if /I "%~1"=="gpu12" (
    set "GPU=1"
    set "CUDA_MAJOR=12"
) else if /I "%~1"=="gpu" (
    set "GPU=1"

    where /q cudart64_13.dll
    if not errorlevel 1 set "CUDA_MAJOR=13"
    if "!CUDA_MAJOR!"=="0" if exist "%ProgramFiles%\NVIDIA GPU Computing Toolkit\CUDA\v13.*\bin\x64\cudart64_13.dll" set "CUDA_MAJOR=13"
    if "!CUDA_MAJOR!"=="0" if exist "%ProgramFiles%\NVIDIA GPU Computing Toolkit\CUDA\v13.*\bin\cudart64_13.dll" set "CUDA_MAJOR=13"

    if "!CUDA_MAJOR!"=="0" (
        where /q cudart64_12.dll
        if not errorlevel 1 set "CUDA_MAJOR=12"
    )
    if "!CUDA_MAJOR!"=="0" if exist "%ProgramFiles%\NVIDIA GPU Computing Toolkit\CUDA\v12.*\bin\x64\cudart64_12.dll" set "CUDA_MAJOR=12"
    if "!CUDA_MAJOR!"=="0" if exist "%ProgramFiles%\NVIDIA GPU Computing Toolkit\CUDA\v12.*\bin\cudart64_12.dll" set "CUDA_MAJOR=12"

    if "!CUDA_MAJOR!"=="0" (
        echo ERROR: Could not auto-detect CUDA 13 or CUDA 12 runtime DLLs.
        echo Use one of:
        echo   build.bat gpu13
        echo   build.bat gpu12
        echo or add the CUDA bin directory to PATH.
        popd
        exit /b 1
    )
) else (
    echo ERROR: Unknown build mode: %~1
    echo Usage:
    echo   build.bat
    echo   build.bat gpu
    echo   build.bat gpu13
    echo   build.bat gpu12
    popd
    exit /b 1
)

echo ============================================
echo   YOLOs-CPP Windows Build Script
echo ============================================
echo.
echo Project root:
echo   %PROJECT_ROOT%
echo.

REM ---------------------------------------------------------------------------
REM Validate vcpkg
REM ---------------------------------------------------------------------------
if not exist "%VCPKG_TOOLCHAIN%" (
    echo ERROR: vcpkg toolchain was not found:
    echo   %VCPKG_TOOLCHAIN%
    echo.
    echo Check the VCPKG_ROOT setting in build.bat.
    popd
    exit /b 1
)

REM ---------------------------------------------------------------------------
REM Determine ONNX Runtime package
REM ---------------------------------------------------------------------------
if "%GPU%"=="1" (
    if "%CUDA_MAJOR%"=="13" (
        set "ORT_PACKAGE=onnxruntime-win-x64-gpu_cuda13-%VERSION%"
        set "ORT_URL=https://github.com/microsoft/onnxruntime/releases/download/v%VERSION%/onnxruntime-win-x64-gpu_cuda13-%VERSION%.zip"
        echo Building with GPU support: CUDA 13.x ABI
    ) else if "%CUDA_MAJOR%"=="12" (
        set "ORT_PACKAGE=onnxruntime-win-x64-gpu-%VERSION%"
        set "ORT_URL=https://github.com/microsoft/onnxruntime/releases/download/v%VERSION%/onnxruntime-win-x64-gpu-%VERSION%.zip"
        echo Building with GPU support: CUDA 12.x ABI
    ) else (
        echo ERROR: Invalid CUDA major: %CUDA_MAJOR%
        popd
        exit /b 1
    )
) else (
    set "ORT_PACKAGE=onnxruntime-win-x64-%VERSION%"
    set "ORT_URL=https://github.com/microsoft/onnxruntime/releases/download/v%VERSION%/onnxruntime-win-x64-%VERSION%.zip"
    echo Building with CPU support...
)

set "ORT_DIR=%PROJECT_ROOT%\%ORT_PACKAGE%"
set "ORT_ZIP=%PROJECT_ROOT%\%ORT_PACKAGE%.zip"
set "ORT_EXTRACT_DIR=%PROJECT_ROOT%\_ort_extract_%ORT_PACKAGE%"

REM ---------------------------------------------------------------------------
REM Download ONNX Runtime if needed
REM ---------------------------------------------------------------------------
if not exist "%ORT_DIR%\include\onnxruntime_cxx_api.h" (
    if not exist "%ORT_ZIP%" (
        echo Downloading ONNX Runtime %VERSION%...
        echo   %ORT_URL%

        powershell -NoProfile -ExecutionPolicy Bypass -Command "Invoke-WebRequest -Uri '%ORT_URL%' -OutFile '%ORT_ZIP%'"

        if errorlevel 1 (
            echo ERROR: Failed to download ONNX Runtime.
            echo URL:
            echo   %ORT_URL%
            popd
            exit /b 1
        )
    ) else (
        echo Using existing ONNX Runtime archive:
        echo   %ORT_ZIP%
    )

    echo Extracting ONNX Runtime...

    if exist "%ORT_EXTRACT_DIR%" rmdir /s /q "%ORT_EXTRACT_DIR%"
    mkdir "%ORT_EXTRACT_DIR%"

    tar -xf "%ORT_ZIP%" -C "%ORT_EXTRACT_DIR%"

    if errorlevel 1 (
        echo ERROR: Failed to extract ONNX Runtime.
        rmdir /s /q "%ORT_EXTRACT_DIR%" 2>nul
        popd
        exit /b 1
    )

    set "EXTRACTED_ORT_DIR="
    for /d %%D in ("%ORT_EXTRACT_DIR%\*") do (
        if not defined EXTRACTED_ORT_DIR set "EXTRACTED_ORT_DIR=%%~fD"
    )

    if not defined EXTRACTED_ORT_DIR (
        echo ERROR: ONNX Runtime archive did not contain an extracted directory.
        rmdir /s /q "%ORT_EXTRACT_DIR%" 2>nul
        popd
        exit /b 1
    )

    if exist "%ORT_DIR%" rmdir /s /q "%ORT_DIR%"
    move "!EXTRACTED_ORT_DIR!" "%ORT_DIR%" >nul
    if errorlevel 1 (
        echo ERROR: Failed to move ONNX Runtime to:
        echo   %ORT_DIR%
        rmdir /s /q "%ORT_EXTRACT_DIR%" 2>nul
        popd
        exit /b 1
    )
    rmdir /s /q "%ORT_EXTRACT_DIR%" 2>nul
    del /q "%ORT_ZIP%"
    echo ONNX Runtime downloaded successfully.
) else (
    echo Using existing ONNX Runtime:
    echo   %ORT_DIR%
)

REM ---------------------------------------------------------------------------
REM Remove the old CMake cache.
REM Necessary because the vcpkg toolchain must be present on first configure.
REM ---------------------------------------------------------------------------
if exist "%PROJECT_ROOT%\build\CMakeCache.txt" (
    echo Removing previous CMake cache...
    rmdir /s /q "%PROJECT_ROOT%\build"
)

if not exist "%PROJECT_ROOT%\build" (
    mkdir "%PROJECT_ROOT%\build"
)

REM ---------------------------------------------------------------------------
REM Configure
REM ---------------------------------------------------------------------------
echo.
echo Configuring with CMake...
echo   vcpkg:
echo     %VCPKG_ROOT%
echo   ONNX Runtime:
echo     %ORT_DIR%
echo   ORT CUDA ABI:
echo     %CUDA_MAJOR%
echo.

cmake -S "%PROJECT_ROOT%" -B "%PROJECT_ROOT%\build" -G "Visual Studio 18 2026" -A x64 -DCMAKE_TOOLCHAIN_FILE="%VCPKG_TOOLCHAIN%" -DVCPKG_TARGET_TRIPLET="%VCPKG_TRIPLET%" -DONNXRUNTIME_DIR="%ORT_DIR%" -DYOLOS_ORT_CUDA_MAJOR="%CUDA_MAJOR%" -DBUILD_EXAMPLES=OFF

if errorlevel 1 (
    echo.
    echo CMake configuration failed.
    popd
    exit /b 1
)

REM ---------------------------------------------------------------------------
REM Build
REM ---------------------------------------------------------------------------
echo.
echo Building Release configuration...

cmake --build "%PROJECT_ROOT%\build" --config Release --parallel

if errorlevel 1 (
    echo.
    echo Build failed.
    popd
    exit /b 1
)

if "%GPU%"=="1" (
    set "MISSING_ORT_PROVIDER_DLLS="
    for %%D in (onnxruntime_providers_shared.dll onnxruntime_providers_cuda.dll) do (
        if not exist "%PROJECT_ROOT%\build\Release\%%D" (
            where /q %%D
            if errorlevel 1 set "MISSING_ORT_PROVIDER_DLLS=!MISSING_ORT_PROVIDER_DLLS! %%D"
        )
    )

    if "%CUDA_MAJOR%"=="13" (
        set "CUDA_DLLS=cudart64_13.dll cublas64_13.dll cublasLt64_13.dll cufft64_12.dll cudnn64_9.dll"
        set "CUDA_INSTALL_HINT=Install CUDA 13.x and cuDNN 9.x"
    ) else (
        set "CUDA_DLLS=cudart64_12.dll cublas64_12.dll cublasLt64_12.dll cufft64_11.dll cudnn64_9.dll"
        set "CUDA_INSTALL_HINT=Install CUDA 12.x and cuDNN 9.x"
    )

    set "MISSING_CUDA_DLLS="
    for %%D in (!CUDA_DLLS!) do (
        if not exist "%PROJECT_ROOT%\build\Release\%%D" (
            where /q %%D
            if errorlevel 1 set "MISSING_CUDA_DLLS=!MISSING_CUDA_DLLS! %%D"
        )
    )

    if not "!MISSING_ORT_PROVIDER_DLLS!!MISSING_CUDA_DLLS!"=="" (
        echo.
        echo WARNING: GPU build completed, but some ONNX Runtime CUDA dependencies were not found.
        if not "!MISSING_ORT_PROVIDER_DLLS!"=="" (
            echo Missing ONNX Runtime provider DLLs:
            echo   !MISSING_ORT_PROVIDER_DLLS!
        )
        if not "!MISSING_CUDA_DLLS!"=="" (
            echo Missing CUDA/cuDNN DLLs:
            echo   !MISSING_CUDA_DLLS!
        )
        echo !CUDA_INSTALL_HINT!, then add their bin directories to PATH
        echo or copy the DLLs to:
        echo   %PROJECT_ROOT%\build\Release\
        echo To run image inference on CPU instead, pass 0 as the fourth argument:
        echo   %PROJECT_ROOT%\build\Release\image_inference.exe model.onnx image.jpg labels.names 0
    )
)

echo.
echo ============================================
echo   Build Successful!
echo ============================================
echo.
echo Executables are in:
echo   %PROJECT_ROOT%\build\Release\
echo.

popd
endlocal
