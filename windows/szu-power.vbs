' Silent launcher: runs szu-power.ps1 with no console window.
' Forwards any args (e.g. "-Agent", "-Fetch") to the script.
Option Explicit
Dim sh, fso, dir, ps, extra, i, cmd
Set sh  = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
dir = fso.GetParentFolderName(WScript.ScriptFullName)
ps  = dir & "\szu-power.ps1"
extra = ""
For i = 0 To WScript.Arguments.Count - 1
    extra = extra & " " & WScript.Arguments(i)
Next
cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & ps & """" & extra
sh.Run cmd, 0, False
