# Mouse entry: install to runtime PRESOURCES and register HKLM RunOnce.
param([switch]$NoPause)

function Wait-ScriptComplete {
    # WINSETUP_HUB=1 = launched by the WINSETUP hub (non-interactive) - don't pause.
    if ($NoPause -or $env:CI -eq 'true' -or $env:WINSETUP_HUB -eq '1') { return }
    Write-Host ''
    Read-Host 'Press Enter to exit'
}

& (Join-Path $PSScriptRoot 'Set-WallpaperLabel.ps1') -Arm -NoPause
Wait-ScriptComplete