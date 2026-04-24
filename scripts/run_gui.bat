@echo off
setlocal EnableDelayedExpansion

:: Determine project root (one level above scripts/)
set "SCRIPT_DIR=%~dp0"
pushd "%SCRIPT_DIR%.."
set "ROOT_DIR=%CD%"
popd

:: Set UTF-8 console codepage to prevent garbled log output on Windows
chcp 65001 >nul 2>&1

:: Ensure Python is available
where python >nul 2>&1
if errorlevel 1 (
    echo ERROR: Python not found on PATH.
    echo Please install Python 3.9+ and add it to PATH.
    echo https://www.python.org/downloads/
    pause
    exit /b 1
)

:: Set env flags
set PYTHONDONTWRITEBYTECODE=1
set PYTHONIOENCODING=utf-8

:: Launch the GUI
python "%ROOT_DIR%\gui.py"
if errorlevel 1 (
    echo.
    echo [ERROR] gui.py exited with an error. Check output above.
    pause
    exit /b 1
)
