' Runs the collector with no window (started by the "TSM Forever Collector" scheduled task).
Set fso = CreateObject("Scripting.FileSystemObject")
dir = fso.GetParentFolderName(WScript.ScriptFullName)
Set sh = CreateObject("WScript.Shell")
sh.CurrentDirectory = dir
sh.Run "node """ & dir & "\collect.js""", 0, True
