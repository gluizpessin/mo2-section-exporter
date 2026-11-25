# MO2 Section Exporter

Portable Windows tool for carrying selected mods from one Mod Organizer 2 setup to another. Run the executable, choose a portable MO2 installation and profile, select a separator, and export to a folder outside the installation.

- Individual ZIPs preserves each selected mod as a separate archive.
- Single merged ZIP resolves conflicts using MO2's left-pane priority.
- The dependency preview follows declared Skyrim SE plugin masters and flags missing masters and SKSE DLLs. Review external requirements and right-pane plugin order in the destination.
- Export progress and verification metrics stay on your PC.

## Build

Run the following in Windows PowerShell. The Windows .NET Framework compiler is used to embed the exporter in a single GUI executable.

    .\Build.ps1

The app uses Windows PowerShell included with Windows.
