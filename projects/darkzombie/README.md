# DarkZombie Dimmer

**Portable Windows multi-monitor software dimmer** by KushZombie Software.

![Illustrative DarkZombie display control interface](assets/darkzombie-demo.svg)

*Illustrative theme artwork, not a photograph of a user workstation.*

DarkZombie makes it simple to dim multiple displays separately without constantly adjusting each monitor's brightness controls. Designed for dark desktop setups, touchscreen use, and multi-monitor workstations.

## Download

**[Download DarkZombie v1.0.5c Polished for Windows](downloads/DarkZombie_v1.0.5c_Windows_Portable.zip)**

**Current polished build.** After the original v1.0.5 launch failure, the owner tested v1.0.5c on Windows and reported that it opens and appears to work. This retains the full polished interface and uses the known-good v1.0.4 executable launcher. Longer-term use and operation on other computers have not yet been independently verified.

**[Rollback download: DarkZombie v1.0.4](downloads/DarkZombie_v1.0.4_Windows_Portable.zip)**, the previously accepted baseline. Both ZIPs are retained separately.

- **Platform:** Windows 10/11 x64
- **Requirements:** Windows PowerShell 5.1 and Windows .NET Framework/WPF (normally already present)
- **Installer:** None. Extract the ZIP and run `DarkZombie.exe`
- **Internet or account:** Not required
- **Administrator permissions:** Not required
- **Troubleshooting:** `Launch_Visible_Startup.cmd` displays startup errors instead of hiding them

SHA-256 of **v1.0.5c ZIP:** `951370f54aed2bfc0ea9cc7674c3af220b112e983b17f3f5a63dbd3a9e34ab41`

SHA-256 of **v1.0.4 rollback ZIP:** `9b440d93738f3b93a7553e88bc9030ce0860cfe7c5ddffd3f5aefd7964dbb758`

## Features

- Detect multiple connected displays, with individual **0–85% software dimming** sliders.
- Presets: **Clear** (0%), **Chill** (20%), **Night** (40%), **Zombie** (60%).
- Save and load favorite per-monitor levels.
- Touchscreen-friendly full-screen interface; **F11** switches between full-screen and windowed mode.
- Hide to the system tray; reopen, reset dimming, or exit from the tray.
- Create a desktop shortcut with the branded **DZ** icon.
- Automatic local settings retention.
- Includes `Emergency_Reset.cmd` to close DarkZombie and remove its overlays if needed.

## How it works and what it does not do

DarkZombie creates **click-through black overlays** on each monitor. It **does not** change the physical backlight brightness or provide hardware-level DDC/CI control. Exclusive-fullscreen games, HDR and protected-video pipelines may bypass the overlay.

It is an independent application, **not** a modification of or redistribution of the third-party Dimmer utility.

## Installation

1. Download the ZIP above.
2. Extract the **entire** ZIP to a folder you intend to keep.
3. Run `DarkZombie.exe` inside the extracted `DarkZombie_v1.0.4` folder.
4. Choose **Create Shortcut** in the application, or run `Create_Desktop_Shortcut.cmd`.

Keep `DarkZombie.exe` and `DarkZombie.ps1` together. Moving the extracted folder later may break an already-created desktop shortcut.

If something goes wrong, close DarkZombie through its tray icon or run `Emergency_Reset.cmd`. To uninstall, exit the app and delete the extracted folder. Settings are stored locally in `%LOCALAPPDATA%\DarkZombie\settings.json`.

## Source and credits

The app's graphical interface, monitor dimming, and startup behavior are implemented in readable Windows PowerShell/WPF:

- [**Polished v1.0.5c source**](source/DarkZombie_v1.0.5c.ps1)
- [**Accepted v1.0.4 rollback source**](source/DarkZombie.ps1)
- Both portable ZIPs include the relevant launcher source and helper scripts.

**KushZombie:** Original concept, creative direction, functional requirements, Windows testing and acceptance. AI-assisted implementation and iteration were used during development.

**Status:** v1.0.5c launched in the project owner's latest Windows test. Original v1.0.5 failed to open and is **not** the download linked here. The public package is unsigned, so Windows may show an unknown-publisher warning. The archive was checked for bundled account/settings files; deployment on other Windows machines is not independently verified.

Source is published for transparency; this repository does not grant a separate open-source redistribution license.

[Back to the KushZombie portfolio](../../README.md)
