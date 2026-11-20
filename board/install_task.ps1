# Registers the "TSM Forever Collector" task: runs collect.js (hidden) every 30 min while you're logged in.
# Remove it with:  Unregister-ScheduledTask -TaskName 'TSM Forever Collector' -Confirm:$false
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$action = New-ScheduledTaskAction -Execute "wscript.exe" -Argument "`"$dir\run-hidden.vbs`"" -WorkingDirectory $dir
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(30) -RepetitionInterval (New-TimeSpan -Minutes 30)
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
  -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
Register-ScheduledTask -TaskName "TSM Forever Collector" -Action $action -Trigger $trigger -Settings $settings `
  -Description "Downloads TradeSkillMaster's public WoW Forever price files and rebuilds dashboard.html" -Force | Out-Null
Get-ScheduledTask -TaskName "TSM Forever Collector" | Get-ScheduledTaskInfo | Select-Object TaskName, NextRunTime
