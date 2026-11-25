# Changelog

## 0.1.3

- Preview the destination profile, separator, mods, estimated extraction size, free space, and name collisions before importing.
- Record SHA-256 checksums in new exports and verify them on import. Older bundles remain importable without stored checksums.

## 0.1.2

- Add a startup language selector with ten languages. The default follows the Windows display language, with English as the fallback.
- Follow the Windows app theme at launch and offer a light/dark toggle on the startup screen.
- Use the modern Windows export folder picker and remember the destination. Change it from the startup screen.
- Some detailed status and error messages still use English.

## 0.1.1

- Cancel dependency review or an active export without restarting.
- Turn dependency review off to export the selected mods directly.
- Resize the main, review, and import windows. The footer shows the app version.
- Check for updates on startup. Choose **Update and open** or dismiss the offer and keep the current version.

## 0.1.0

First public prerelease.

- Export selected mods from existing MO2 separators as individual verified ZIPs or one priority-merged ZIP.
- Restore a saved section into another portable instance under a new separator. Individual imports preserve relative mod priority and enabled states.
- Review declared plugin masters, missing requirements, and detected SKSE and HDT-SMP references.
- Exclude recognized Skyrim stock files from exports.
- Use a guided light or dark interface with background processing and export progress, speed, and elapsed time.
- Reject import name collisions and back up the destination mod list.
