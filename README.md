# MO2 Section Exporter

Portable Windows utility for carrying selected Skyrim Special Edition mods between Mod Organizer 2 instances.

## Use

1. Open the portable executable and select an MO2 installation, profile, and separator.
2. Search the checklist and choose which mods to bring. Filtering preserves selections outside the visible results.
3. Review the dependency table, choose whether to include resolved plugin masters, and select an export folder outside the source modlist.
4. Wait for ZIP verification to finish before deleting the source list.

**Individual ZIPs** preserves each installed mod as a separate archive. **Single merged ZIP** combines selected files using MO2 left-pane priority to resolve conflicts. Set ESP, ESM, and ESL load order in the destination profile.

The guided interface supports light and dark modes. Export progress, average speed, and elapsed time are displayed locally.

## Dependencies and stock files

The review follows declared plugin masters and shows which mod requires each one. It flags missing masters, SKSE DLLs, and HDT-SMP references found in loose meshes or configs. Verify runtime compatibility and any other requirements in the destination setup.

Recognized Skyrim stock files are excluded from both export formats. The destination modlist is expected to supply them. Loose replacers installed by mods are exported normally.

## Build

Run in Windows PowerShell:

    .\Build.ps1

The build uses the Windows .NET Framework compiler and produces one GUI executable. It uses the Windows PowerShell runtime that ships with Windows.

## AI assistance

This project was developed with assistance from OpenAI Codex. Guilherme Pessin defined the workflow and provided feedback from using the app. Codex assisted with implementation, interface concepts, and automated checks. Dependency detection can miss requirements, so review the export and test it in the destination modlist.

## License

The project source is licensed under the MIT License. Exported mods and assets remain subject to their original licenses.
