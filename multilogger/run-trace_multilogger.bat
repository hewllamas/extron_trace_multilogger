@echo off
setlocal
title Extron trace multilogger

:: ---------------------------------------------------------------------------
::  Double-click to start logging trace from every processor listed in the
::  $Processors table in trace_multilogger.ps1. A tick-box dialog pops up
::  first - all ticked by default, untick any you don't want this session,
::  then "Start Logging".
::
::  Runs -NoExit on purpose: each processor's connection is a PowerShell
::  background job, and those jobs live and die with this window - closing it
::  stops all logging. Leave it open for the duration of your trace capture.
::
::  Once it's running, type straight into this window:
::      Get-Job                                     - check each processor's job status
::      Receive-Job -Name processor-02 -Keep        - peek at recent output
::      Get-Job | Stop-Job; Get-Job | Remove-Job    - stop everything
::
::  Logs land in <repo>\logs\<processor>\, named Trace_MultiLogger_<timestamp>.log.
:: ---------------------------------------------------------------------------

powershell.exe -NoProfile -NoExit -ExecutionPolicy Bypass -File "%~dp0trace_multilogger.ps1"
