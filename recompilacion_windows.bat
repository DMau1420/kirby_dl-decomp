@echo off
setlocal enabledelayedexpansion

if "%~1"=="" (
    echo Uso: %~nx0 ^<ruta_de_rom.gb^>
    exit /b 1
)

for %%I in ("%~1") do (
    set "ROM_PATH=%%~fI"
    set "ROM_STEM=%%~nI"
)

if not exist "%ROM_PATH%" (
    echo [ERROR] No se encontro la ROM: "%ROM_PATH%"
    exit /b 1
)

set "WORK_DIR=%~dp0"
if "%WORK_DIR:~-1%"=="\" set "WORK_DIR=%WORK_DIR:~0,-1%"
set "REPO_DIR=%WORK_DIR%\gb-recompiled"
set "OUT_DIR=%WORK_DIR%\recomp_windows"

echo ==================================================
echo   Recompilacion automatica para Windows
echo   ROM: "%ROM_PATH%"
echo ==================================================

where git >nul 2>nul
if errorlevel 1 (
    echo [ERROR] No se encontro 'git' en PATH.
    exit /b 1
)

where cmake >nul 2>nul
if errorlevel 1 (
    echo [ERROR] No se encontro 'cmake' en PATH.
    exit /b 1
)

REM 1. Clonar gb-recompiled solo si no existe
if not exist "%REPO_DIR%" (
    echo [1/5] Clonando gb-recompiled...
    git clone https://github.com/arcanite24/gb-recompiled.git "%REPO_DIR%"
    if errorlevel 1 exit /b 1
) else (
    echo [1/5] Usando gb-recompiled existente en "%REPO_DIR%"
)

REM 2. Detectar o descargar SDL2-2.30.9
if not defined SDL2_SOURCE_DIR (
    if exist "%WORK_DIR%\SDL2-2.30.9\CMakeLists.txt" (
        set "SDL2_SOURCE_DIR=%WORK_DIR%\SDL2-2.30.9"
    ) else if exist "%WORK_DIR%\SDL2\CMakeLists.txt" (
        set "SDL2_SOURCE_DIR=%WORK_DIR%\SDL2"
    )
)

if not defined SDL2_SOURCE_DIR (
    echo [2/5] Descargando SDL2-2.30.9...
    curl -fL "https://github.com/libsdl-org/SDL/releases/download/release-2.30.9/SDL2-2.30.9.tar.gz" -o "%WORK_DIR%\SDL2.tar.gz"
    if errorlevel 1 (
        echo [ERROR] No se pudo descargar SDL2-2.30.9.
        exit /b 1
    )
    tar -xzf "%WORK_DIR%\SDL2.tar.gz" -C "%WORK_DIR%"
    if errorlevel 1 exit /b 1
    set "SDL2_SOURCE_DIR=%WORK_DIR%\SDL2-2.30.9"
) else (
    echo [2/5] Usando SDL2 en "%SDL2_SOURCE_DIR%"
)

REM 3. Compilar gbrecomp si no existe
set "GBRECOMP_BIN="
if exist "%REPO_DIR%\build\bin\Release\gbrecomp.exe" set "GBRECOMP_BIN=%REPO_DIR%\build\bin\Release\gbrecomp.exe"
if exist "%REPO_DIR%\build\bin\gbrecomp.exe" set "GBRECOMP_BIN=%REPO_DIR%\build\bin\gbrecomp.exe"

if not defined GBRECOMP_BIN (
    echo [3/5] Compilando gbrecomp...
    cmake -S "%REPO_DIR%" -B "%REPO_DIR%\build" -DCMAKE_BUILD_TYPE=Release
    if errorlevel 1 exit /b 1
    cmake --build "%REPO_DIR%\build" --config Release --parallel
    if errorlevel 1 exit /b 1
    if exist "%REPO_DIR%\build\bin\Release\gbrecomp.exe" set "GBRECOMP_BIN=%REPO_DIR%\build\bin\Release\gbrecomp.exe"
    if exist "%REPO_DIR%\build\bin\gbrecomp.exe" set "GBRECOMP_BIN=%REPO_DIR%\build\bin\gbrecomp.exe"
) else (
    echo [3/5] Usando gbrecomp existente: "%GBRECOMP_BIN%"
)

if not defined GBRECOMP_BIN (
    echo [ERROR] No se encontro gbrecomp.exe tras compilar.
    exit /b 1
)

REM 4. Recompilar ROM a C en recomp_windows
echo [4/5] Generando proyecto C en "%OUT_DIR%"...
"%GBRECOMP_BIN%" "%ROM_PATH%" -o "%OUT_DIR%"
if errorlevel 1 exit /b 1

REM Parchear recomp_windows\CMakeLists.txt para usar SDL2_SOURCE_DIR y copiar SDL2.dll automaticamente
powershell -NoProfile -Command "$p = '%OUT_DIR%\CMakeLists.txt'; $nl = [Environment]::NewLine; $t = Get-Content -Raw -Encoding UTF8 $p; if ($t -notmatch 'SDL2_SOURCE_DIR') { $new1 = 'set(SDL2_SOURCE_DIR \"\" CACHE PATH \"Path to SDL2 source\")' + $nl + 'if(SDL2_SOURCE_DIR AND EXISTS \"${SDL2_SOURCE_DIR}/CMakeLists.txt\")' + $nl + '    set(SDL_TEST OFF CACHE BOOL \"\" FORCE)' + $nl + '    set(SDL_SHARED ON CACHE BOOL \"\" FORCE)' + $nl + '    set(SDL_STATIC OFF CACHE BOOL \"\" FORCE)' + $nl + '    add_subdirectory(\"${SDL2_SOURCE_DIR}\" \"${CMAKE_BINARY_DIR}/SDL2\" EXCLUDE_FROM_ALL)' + $nl + 'else()' + $nl + '    find_package(SDL2 REQUIRED)' + $nl + 'endif()'; $t = $t.Replace('find_package(SDL2 REQUIRED)', $new1); } if ($t -notmatch 'copy_if_different') { $t = $t + $nl + 'if(WIN32 AND TARGET SDL2::SDL2)' + $nl + '    add_custom_command(TARGET %ROM_STEM% POST_BUILD COMMAND ${CMAKE_COMMAND} -E copy_if_different $<TARGET_FILE:SDL2::SDL2> $<TARGET_FILE_DIR:%ROM_STEM%> VERBATIM)' + $nl + 'endif()' + $nl; } Set-Content -NoNewline -Encoding UTF8 $p $t"

REM 5. Compilar ejecutable de Windows
echo [5/5] Compilando "%ROM_STEM%.exe"...
cmake -S "%OUT_DIR%" -B "%OUT_DIR%\build" -DCMAKE_BUILD_TYPE=Release "-DSDL2_SOURCE_DIR=%SDL2_SOURCE_DIR%"
if errorlevel 1 exit /b 1
cmake --build "%OUT_DIR%\build" --config Release --parallel
if errorlevel 1 exit /b 1

echo.
echo ==================================================
echo   Compilacion para Windows completada
echo ==================================================
if exist "%OUT_DIR%\build\Release\%ROM_STEM%.exe" (
    echo Ejecutable: "%OUT_DIR%\build\Release\%ROM_STEM%.exe"
) else (
    echo Ejecutable: "%OUT_DIR%\build\%ROM_STEM%.exe"
)
echo.
endlocal
