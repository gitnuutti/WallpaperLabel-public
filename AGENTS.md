# WallpaperLabel — agent context

Post-restore desktop wallpaper tool: stamps `<C: volume label> on <HOSTNAME>` in a grey band across the top of a freshly drawn wallpaper.

## Key scripts

| File | Role |
|------|------|
| `Set-WallpaperLabel.ps1` | Main logic: draw, apply, `-Arm`, `-OnLogon`, `-Force`, `-ClearForImage` |
| `Arm-WallpaperLabel.ps1` | Mouse entry for `-Arm` |
| `Clear-WallpaperLabel-ForImage.ps1` | Mouse entry for pre-backup clear + RunOnce |

Double-click `.ps1` directly (no `.bat` wrappers). Pause only on manual top-level launch; nested calls (hub, setup, thin entry scripts) pass `-NoPause` or are detected via call stack so automation does not hang.

## Paths (three places — do not conflate)

| Role | Path |
|------|------|
| **Runtime (on-image)** | `C:\Users\Public\PRESOURCES\Post Restore Setup\WallpaperLabel\` |
| **Dev / git** | clone of `siltanug/WallpaperLabel` (e.g. `T:\DEV\WallpaperLabel\`) |
| **Generated bmp** | `%LOCALAPPDATA%\WallpaperLabel\` |

Logon launcher: `HKLM\...\RunOnce\WallpaperLabel` → `powershell -OnLogon` on the **runtime** canonical script path.

## Behaviour

- Paints solid `RGB(43,24,48)` (must match WINSETUP `SetDesktopBackground.ps1`), then grey band + dark text.
- `-ClearForImage`: plain wallpaper + clear `LastText` + register HKLM RunOnce (run before backup; BURESTC2 hub does this automatically).
- `-OnLogon`: repaint only when `<C: label> on <HOSTNAME>` differs from `HKCU:\Software\WallpaperLabel\LastText`; RunOnce fires once at first logon.
- `-Arm`: elevates, copies to runtime, clears legacy Run/task/VBS launchers, registers RunOnce.

Tunables at top of `Set-WallpaperLabel.ps1`: `$FontPixels`, `$TopMargin`, `$BgColor`, `$BandColor`, `$TextColor`.

## Conventions

- Standalone `.ps1` scripts: portable, mouse-runnable, `Read-Host` on exit (accept `-NoPause` for agents).
- Test from dev: double-click `Set-WallpaperLabel.ps1`. Logon path always uses runtime canonical paths inside the script.