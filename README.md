# OoT Editor for macOS

A standalone companion for the MacNativeGames port of the Switch 2 Ocarina of Time remake, update **131072**. It runs on Apple silicon with macOS 26 or later.

## Edit a save

1. Create a save in OoT. Quit the game, then choose **Edit Player Save Copy**. For the separate Quick Start profile, choose **Edit Test Save**.
2. In **Save Workshop**, click **Open Backup** and select the suggested save-account folder. Choose your slot.
3. Edit rupees, wallet size, hearts, magic, inventory, bottles, ammo, keys, or supported progression flags. Use **Quick Edits** to refill the selected wallet, health and magic, or supplies already supported by the save. Fill empty bottles with a potion, fairy, or milk.
4. With the game closed, choose **Apply to Profile**. This is available when the editor finds one native save account. It checks that the destination still matches the open copy, backs up that account, and replaces the edited files together. Reopen the save before making more edits.
5. For other backups or multiple accounts, export a folder or ZIP and copy the replacement pair into the matching save slot with the game closed.

The Workshop edits copies and requires the game to be closed before applying. **Open Backups** shows snapshots created by the editor.

## Graphics and playtesting

- **Player graphics** controls internal resolution, upscaling, frame cap, and interpolation for the next normal launch. Start with **1080p from 720p**, **MetalFX**, and **60 FPS** for more GPU headroom than native 1080p.
- **Quick Start** opens the native game with a separate persistent test profile and the runtime’s opening skip. **New Game** uses the shortened opening. **Continue** resumes the test save. Quick Start uses its own graphics settings and disables player mods for the test session.

## Build

Install Xcode or the macOS Command Line Tools with the macOS 26 SDK or newer. Run `bash build.sh` from this checkout. It builds and verifies an ad-hoc-signed `build/OoT Editor.app`.

To use Quick Start, build and install [MacNativeGames Ocarina of Time](https://github.com/ly05010419/MacNativeGames/tree/main/games/oot) as `~/Applications/Ocarina of Time.app`. The editor package contains no game or save data.

## Credits

Save Workshop bundles the MIT-licensed [OOT-SW2SE editor by Traiver](https://github.com/Traiver/OOT-SW2SE/tree/de26f03d0a299e39e5536bf68eeef9b251fadba1). The bundled HTML adds quick edits, bottle filling, and an optional native Apply action. The macOS host is adapted in `SaveWorkshop.swift`, and its license is included under `Vendor/OOT-SW2SE`.
