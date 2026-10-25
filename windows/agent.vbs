' Silent launcher for the always-on hotkey agent (no console window).
Option Explicit
Dim sh, fso, dir, ps
Set sh  = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
dir = fso.GetParentFolderName(WScript.ScriptFullName)
ps  = dir & "\szu-power.ps1"
sh.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & ps & """ -Agent", 0, False
