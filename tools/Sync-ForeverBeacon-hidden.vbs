' Wrapper for the ForeverBeaconSync scheduled task.
' wscript.exe has no console of its own and Run(..., 0, False) starts PowerShell
' hidden, so the sync runs with no window at all.
Set sh = CreateObject("WScript.Shell")
sh.Run "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File ""<KIT>\ForeverBeacon\tools\Sync-ForeverBeacon.ps1""", 0, False
