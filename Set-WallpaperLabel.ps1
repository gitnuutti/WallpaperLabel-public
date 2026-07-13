# Set-WallpaperLabel.ps1
# Stamps "<C: volume label> on <HOSTNAME>" in a grey band across the top of the
# desktop wallpaper, then applies the result as the current wallpaper.
#
# The band is a fixed full-width rectangle, so every run paints over the same
# region -> it OVERWRITES any previous label cleanly. That means a master
# partition can be labeled, imaged, and after the image is restored to another
# partition this script overwrites the old label with the new partition's
# C: label + host name. Nothing stacks.
#
# Usage:
#   Set-WallpaperLabel.ps1            Apply the label to the wallpaper now (force).
#   Set-WallpaperLabel.ps1 -Arm       Apply the label to THIS machine now, then
#                                      install to the canonical PRESOURCES path
#                                      and register HKLM RunOnce.
#                                      Paints as the user first, then self-elevates
#                                      via UAC (for the RunOnce) if needed.
#   Set-WallpaperLabel.ps1 -OnLogon   (Invoked by logon launcher.) Repaint ONLY if the
#                                      current "<C: label> on <HOSTNAME>" differs from
#                                      the last stamp -> detects a restore to a new
#                                      partition; no-op when nothing changed.
#   Set-WallpaperLabel.ps1 -ClearForImage
#                                      Strip the label before backup/imaging on the master,
#                                      then register HKLM RunOnce so the image carries a
#                                      one-shot first-logon apply for clones.
#
# Clone flow: -ClearForImage before backup -> plain wallpaper in image + pending RunOnce
# -> first logon on master or clone applies the correct label, then RunOnce is consumed.
#
# Plain apply needs no admin. -Arm and -ClearForImage write HKLM RunOnce, so they elevate.
# Pause (Read-Host) only when this script is the top-level mouse launch; callers use -NoPause.

param(
    [switch]$Arm,
    [switch]$OnLogon,
    [switch]$Force,
    [switch]$ClearForImage,
    [switch]$NoPause,
    [switch]$Applied   # internal: label already painted as the user before elevation
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class WP {
    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    public static extern int SystemParametersInfo(int uAction, int uParam, string lpvParam, int fuWinIni);
}
"@

# --- tunables --------------------------------------------------------------
$FontName   = 'Arial'
$FontPixels = 20
$TopMargin  = 0
$BgColor    = [System.Drawing.Color]::FromArgb(43, 24, 48)
$BandColor  = [System.Drawing.Color]::FromArgb(200, 200, 200)
$TextColor  = [System.Drawing.Color]::FromArgb(64, 64, 64)
$Canonical  = 'C:\Users\Public\PRESOURCES\Post Restore Setup\WallpaperLabel\Set-WallpaperLabel.ps1'
$RunKeyName = 'WallpaperLabel'
$MarkerKey  = 'HKCU:\Software\WallpaperLabel'
$MarkerName = 'LastText'
$WorkDir    = Join-Path $env:LOCALAPPDATA 'WallpaperLabel'
$PlainBmp   = Join-Path $WorkDir 'wallpaper_plain.bmp'
$LabeledBmp = Join-Path $WorkDir 'wallpaper_labeled.bmp'
$ShipFiles  = @(
    'Arm-WallpaperLabel.ps1',
    'Clear-WallpaperLabel-ForImage.ps1'
)
# ---------------------------------------------------------------------------

function Test-IsAdmin {
    return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
        ).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
}

function Test-WantsPause {
    # WINSETUP_HUB=1 = launched by the WINSETUP hub (non-interactive) - don't pause.
    if ($NoPause -or $env:CI -eq 'true' -or $env:WINSETUP_HUB -eq '1') { return $false }
    foreach ($frame in (Get-PSCallStack | Select-Object -Skip 1)) {
        if ($frame.ScriptName -like '*.ps1') { return $false }
    }
    return $true
}

function Wait-ScriptComplete {
    if (-not (Test-WantsPause)) { return }
    Write-Host ''
    Read-Host 'Press Enter to exit'
}

function Get-LabelText {
    $label = (Get-Volume -DriveLetter C).FileSystemLabel
    if ([string]::IsNullOrWhiteSpace($label)) { return $env:COMPUTERNAME }
    return "$label on $env:COMPUTERNAME"
}

function Invoke-ApplyWallpaperBmp {
    param([string]$BmpPath)
    if (-not (Test-Path -LiteralPath $BmpPath)) { return }
    $desktopKey = 'HKCU:\Control Panel\Desktop'
    Set-ItemProperty -Path $desktopKey -Name Wallpaper      -Value $BmpPath -ErrorAction Stop
    Set-ItemProperty -Path $desktopKey -Name WallpaperStyle -Value '10'     -ErrorAction Stop
    Set-ItemProperty -Path $desktopKey -Name TileWallpaper  -Value '0'      -ErrorAction Stop
    $SPI_SETDESKWALLPAPER = 0x0014
    $SPIF_UPDATEINIFILE   = 0x01
    $SPIF_SENDCHANGE      = 0x02
    [WP]::SystemParametersInfo($SPI_SETDESKWALLPAPER, 0, $BmpPath, ($SPIF_UPDATEINIFILE -bor $SPIF_SENDCHANGE)) | Out-Null
}

function Save-PlainWallpaperBmp {
    $bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $bmp = New-Object System.Drawing.Bitmap $bounds.Width, $bounds.Height
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.Clear($BgColor)
    $g.Dispose()
    $bmp.Save($PlainBmp, [System.Drawing.Imaging.ImageFormat]::Bmp)
    $bmp.Dispose()
}

function Invoke-ApplyLabel {
    # Render "<C: label> on <HOST>" into the band and apply it as the wallpaper
    # for the CURRENT user, then record the marker. No admin needed.
    param([Parameter(Mandatory)][string]$Text)
    New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null

    $bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $w = $bounds.Width
    $h = $bounds.Height

    $bmp = New-Object System.Drawing.Bitmap $w, $h
    $g   = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode     = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
    $g.Clear($BgColor)

    $bandH = [int]($FontPixels * 1.6)
    $band  = New-Object System.Drawing.Rectangle 0, $TopMargin, $w, $bandH
    $brushBand = New-Object System.Drawing.SolidBrush $BandColor
    $g.FillRectangle($brushBand, $band)

    $maxW = $w - 80
    $px = $FontPixels
    $font = New-Object System.Drawing.Font($FontName, $px, [System.Drawing.GraphicsUnit]::Pixel)
    while (($g.MeasureString($Text, $font)).Width -gt $maxW -and $px -gt 24) {
        $font.Dispose()
        $px -= 4
        $font = New-Object System.Drawing.Font($FontName, $px, [System.Drawing.GraphicsUnit]::Pixel)
    }

    $fmt = New-Object System.Drawing.StringFormat
    $fmt.Alignment     = [System.Drawing.StringAlignment]::Center
    $fmt.LineAlignment = [System.Drawing.StringAlignment]::Center
    $rectF = New-Object System.Drawing.RectangleF(0, $TopMargin, $w, $bandH)
    $brushText = New-Object System.Drawing.SolidBrush $TextColor
    $g.DrawString($Text, $font, $brushText, $rectF, $fmt)

    $g.Dispose(); $font.Dispose(); $brushBand.Dispose(); $brushText.Dispose()

    $bmp.Save($LabeledBmp, [System.Drawing.Imaging.ImageFormat]::Bmp)
    $bmp.Dispose()

    Invoke-ApplyWallpaperBmp -BmpPath $LabeledBmp

    New-Item -Path $MarkerKey -Force | Out-Null
    Set-ItemProperty -Path $MarkerKey -Name $MarkerName -Value $Text
}

function Clear-LegacyWallpaperLaunchers {
    Remove-ItemProperty 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run' -Name $RunKeyName -ErrorAction SilentlyContinue
    Remove-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name $RunKeyName -ErrorAction SilentlyContinue
    Remove-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce' -Name $RunKeyName -ErrorAction SilentlyContinue
    # Deleting a task that was never created (first run) writes to stderr, which
    # under ErrorActionPreference=Stop surfaces as a terminating NativeCommandError.
    # Redirection (2>$null / *>$null) does NOT prevent this in PS 5.1 - only
    # switching to Continue for the call does. Best-effort cleanup, ignore result.
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & schtasks.exe /Delete /TN $RunKeyName /F *> $null
    $global:LASTEXITCODE = 0
    $ErrorActionPreference = $prevEAP

    $startupLnk = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup\WallpaperLabel-Fast.lnk'
    if (Test-Path -LiteralPath $startupLnk) {
        Remove-Item -LiteralPath $startupLnk -Force
        Write-Host "Removed duplicate Startup shortcut: $startupLnk"
    }
}

function Register-LogonRunOnce {
    $cmd = 'powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $Canonical + '" -OnLogon'
    Clear-LegacyWallpaperLaunchers
    Set-ItemProperty 'HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce' -Name $RunKeyName -Value $cmd
}

function Install-CanonicalFiles {
    $canonDir = Split-Path $Canonical
    New-Item -ItemType Directory -Force -Path $canonDir | Out-Null
    Copy-Item -LiteralPath $PSCommandPath -Destination $Canonical -Force

    $srcDir = Split-Path $PSCommandPath
    foreach ($f in $ShipFiles) {
        $src = Join-Path $srcDir $f
        if (Test-Path $src) { Copy-Item -LiteralPath $src -Destination (Join-Path $canonDir $f) -Force }
    }
}

function Invoke-Elevated {
    param(
        [string[]]$ExtraArgs
    )
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"") + $ExtraArgs
    Start-Process powershell -Verb RunAs -ArgumentList $argList
}

# ===========================================================================
#  -ClearForImage : strip label before master backup + arm RunOnce for image
# ===========================================================================
if ($ClearForImage) {
    if (-not (Test-IsAdmin)) {
        Write-Host 'Elevating to register HKLM RunOnce...'
        $elevArgs = @('-ClearForImage')
        if ($NoPause) { $elevArgs += '-NoPause' }
        Invoke-Elevated -ExtraArgs $elevArgs
        return
    }

    if ($PSCommandPath -ne $Canonical) {
        Install-CanonicalFiles
    }

    New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
    Save-PlainWallpaperBmp

    if (Test-Path -LiteralPath $LabeledBmp) {
        Remove-Item -LiteralPath $LabeledBmp -Force
    }

    $historyKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Wallpapers'
    if (Test-Path $historyKey) {
        Set-ItemProperty -Path $historyKey -Name BackgroundHistoryPath0 -Value $PlainBmp -ErrorAction SilentlyContinue
    }

    $transcoded = Join-Path $env:APPDATA 'Microsoft\Windows\Themes\TranscodedWallpaper'
    if (Test-Path -LiteralPath $transcoded) {
        Remove-Item -LiteralPath $transcoded -Force
    }

    Invoke-ApplyWallpaperBmp -BmpPath $PlainBmp
    Start-Sleep -Milliseconds 300
    RUNDLL32.EXE user32.dll,UpdatePerUserSystemParameters ,1 ,True | Out-Null

    Remove-ItemProperty -Path 'HKCU:\Software\WallpaperLabel' -Name 'LastText' -ErrorAction SilentlyContinue

    Register-LogonRunOnce

    Write-Host 'WallpaperLabel: cleared label (plain wallpaper) and armed RunOnce for imaging.'
    Wait-ScriptComplete
    return
}

# ===========================================================================
#  -Arm : apply the label now, then install + register HKLM RunOnce, then exit
# ===========================================================================
if ($Arm) {
    # Paint the label on THIS machine now (plain apply needs no admin), BEFORE any
    # elevation so it lands in the interactive user's HKCU - not the admin's. Then
    # elevate only to install to PRESOURCES + register the HKLM RunOnce that
    # re-applies after a restore/clone. The elevated re-run carries -Applied so it
    # does not repaint under the wrong profile.
    if (-not $Applied) { Invoke-ApplyLabel -Text (Get-LabelText) }

    if (-not (Test-IsAdmin)) {
        $elevArgs = @('-Arm', '-Applied')
        if ($NoPause) { $elevArgs += '-NoPause' }
        Invoke-Elevated -ExtraArgs $elevArgs
        return
    }

    Install-CanonicalFiles
    Register-LogonRunOnce

    Write-Host "WallpaperLabel: applied '$(Get-LabelText)' and armed RunOnce for post-restore logon."
    Wait-ScriptComplete
    return
}

# ===========================================================================
#  Default : render the label and apply it as the wallpaper
# ===========================================================================
New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null

$text = Get-LabelText

if ($OnLogon -and -not $Force) {
    $last = $null
    $mk = Get-ItemProperty -Path $MarkerKey -Name $MarkerName -ErrorAction SilentlyContinue
    if ($mk -and ($mk.PSObject.Properties.Name -contains $MarkerName)) { $last = $mk.$MarkerName }
    if ($last -eq $text) { return }
}

Invoke-ApplyLabel -Text $text
Write-Host "Wallpaper updated: $text"

if (-not $OnLogon) {
    Wait-ScriptComplete
}