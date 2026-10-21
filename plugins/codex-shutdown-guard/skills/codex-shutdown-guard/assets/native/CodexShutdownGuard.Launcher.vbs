Option Explicit

Dim shell, fileSystem, scriptRoot, mainScript, mode, command

Set shell = CreateObject("WScript.Shell")
Set fileSystem = CreateObject("Scripting.FileSystemObject")

scriptRoot = fileSystem.GetParentFolderName(WScript.ScriptFullName)
mainScript = fileSystem.BuildPath(scriptRoot, "CodexShutdownGuard.ps1")
mode = "-Show"

If WScript.Arguments.Count > 0 Then
    mode = CStr(WScript.Arguments(0))
    If Left(mode, 1) <> "-" Then
        mode = "-" & mode
    End If
End If

command = Chr(34) & shell.ExpandEnvironmentStrings("%SystemRoot%") & _
    "\System32\WindowsPowerShell\v1.0\powershell.exe" & Chr(34) & _
    " -NoProfile -ExecutionPolicy Bypass -STA -File " & Chr(34) & _
    mainScript & Chr(34) & " " & mode

' Run with window style 0 so Windows Terminal is never opened for the guard.
shell.Run command, 0, False
