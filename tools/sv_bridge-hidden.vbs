' Wrapper for the ForeverSVBridge scheduled task.
' Starts the always-on watcher windowless. The watcher holds a lock file, so if
' one is already running this start exits immediately and nothing is duplicated.
Set sh = CreateObject("WScript.Shell")
sh.Run "pythonw.exe ""<KIT>\tools\sv_watch.py""", 0, False
