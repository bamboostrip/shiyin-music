@echo off
rem Thin ASCII-only launcher for build_windows.ps1 (single source of logic).
rem Keep this file ASCII: cmd's chcp 65001 mis-splits long UTF-8 batch files.
rem Usage: build_windows.bat [release|debug]  (args pass through to the ps1)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0build_windows.ps1" %*
