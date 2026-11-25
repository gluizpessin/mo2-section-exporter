# Roadmap

The goal is to make it easy to save an installed MO2 section, reclaim the space used by the old modlist, and restore that section into another instance for the same game.

## Shipped in v0.1.0

- Portable Windows executable with guided import and export.
- Individual verified ZIPs or one ZIP merged by MO2 mod priority.
- Restore a saved section under a new separator, with collision checks and a profile backup.
- Skyrim dependency review and stock-file filtering.

## v0.2.0 preview

- Detect the source and destination games and read configured mods and profiles paths.
- Record the source game in new exports and block known game mismatches on import.
- Preserve installed mod layouts across games. Run Skyrim-specific checks only for Skyrim.
- Treat game support outside the tested Skyrim workflow as experimental. Cyberpunk 2077 is the first live validation target. Both archive formats passed Cyberpunk-style fixture tests.

## Next priorities

1. **Validate a real Cyberpunk transfer.** Export an archive-only mod and a framework-dependent mod, import into a second MO2 profile, and confirm both work in-game.
2. **Build a compatibility matrix.** Record the game, MO2 version, instance layout, archive format, and result for each verified transfer. Validate Fallout 4 and more non-Bethesda games as test setups become available.
3. **Improve import review.** Show the games, destination profile, separator, and name collisions together before writing. Make the unknown-game state clear for older bundles.
4. **Add Cyberpunk framework hints.** Surface evidence of CET, RED4ext, redscript, and ArchiveXL usage for manual review. Keep game-root files and MO2 Overwrite outside the normal transfer unless the user explicitly selects them.
5. **Expand Windows regression tests.** Cover custom paths, game mismatches, old bundles, and both archive formats with representative game layouts.

## Later

- Evaluate optional plugin load-order restoration for games with a verified format.
- Add further game-specific checks as test cases and maintainers become available.
