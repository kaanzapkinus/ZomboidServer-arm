# Changelog

Versions are git tags; every release ships with these notes on the GitHub Releases page.

## v2.2.0 — 2026-08-24 — mod permissions, honest errors, backups menu

### Fixed
- **Mods installed by the auto-update timer could not be updated afterwards.** The timer runs
  as root, so the mod folders it wrote were owned by root; a later `pzctl` run as the normal
  user hit `Permission denied` on `rm`/`cp` and *still reported success*, leaving a
  half-replaced mod. Mod files are now always written as the game user, an existing folder
  owned by someone else is reclaimed before it is replaced, and a failed replace is reported
  as a failure. Existing installs are repaired automatically on the next mod operation.
- **A broken downloader path made every mod download fail with no explanation.** When the
  installer fell back to the .NET build, it wrote `PZ_DD=dotnet /path/DepotDownloader.dll`
  unquoted into the env file; sourcing that ran the `.dll` as a command and left `PZ_DD`
  unset, so mod downloads used a path that does not exist while the initial server download
  (which never read the file) worked fine. All env values are quoted now, the installer
  verifies the downloader before writing it, `pzctl` refuses up front with the configured
  path when it is unusable, and the file the installer generates is parse-checked.
- Every DepotDownloader run is logged to `depotdownloader.log`, and failures print the
  downloader's own error instead of a bare "failed".
- `Ctrl+C` in Live logs returns to the menu instead of quitting pzctl.
- Backups now include the player database (`db/`); a restore without it lost every character.
- `ini_set` preserves file ownership, so a root-run timer can no longer lock the game user
  out of its own `servertest.ini`.

### Added
- **Backups menu** (main menu 9): list every archive with date, size and origin
  (manual / mod-update / pre-reset / pre-restore), create one, restore one (stops the server,
  saves a pre-restore copy first, handles archives from both the current and the original
  layout), or delete one.
- Mods that are on disk but in neither list are shown as `[on disk, not in the list]` and can
  be switched on from Disable / enable — manually copied mods no longer look invisible.
- `DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1` is exported for every downloader call, so minimal
  images without libicu work the same as full ones.
- The installer rejects paths containing spaces instead of failing later in confusing ways.

### Reverted
- **The Steam-session boot gate from v2.1.1 is gone**, along with its `tcpdump` dependency.
  The evidence behind it was weak: the server answered Steam queries normally the whole time,
  and the "stuck at Getting Server Info" reports were resolved by removing faulty mods, not by
  the gate. It could also fail a perfectly healthy boot when Valve traffic happened to be
  quiet, so it has been removed rather than kept as an option.

## v2.1.1 — 2026-08-11 — Steam-session boot gate + audit fixes

### Added
- **Steam-session health gate in `pz-boot-retry`**: a box64 boot can reach "listening" with a
  dead Steam game-server session, and players joining through Steam Relay can never reach such
  a server (stuck at "Getting Server Info"). After LISTENING the boot loop now samples for
  traffic to Valve's network and restarts the boot if the session never comes up. On by
  default when `tcpdump` is available (now installed as a dependency); disable with
  `PZ_REQUIRE_STEAM=0`.

### Fixed
- A scheduled mod-update check no longer burns its daily slot when the Steam API is
  unreachable; it retries on the next 30-minute tick, and `check`/`apply` report "API
  unreachable" instead of pretending everything is current.
- Mod reorder: the `5>1` move syntax is now parsed with plain string operations. The old
  regex (`\>`) is interpreted as a word boundary by some regex engines, which would have
  silently broken moves on those platforms; malformed inputs (`a>b`, `>5`, `1>2>3`) are
  rejected with a clear message.
- The installer's admin-password validation was rewritten the same way (an escaped-quote
  regex class that can break depending on the shell transporting it).
- Status shows `0 mods` instead of a blank when `Mods=` is empty.

## v2.1.0 — 2026-08-11 — map mods, faster re-adds, import hardening

### Added
- **Map mod support**: map folders inside installed mods (`media/maps`, `42/media/maps`,
  `common/media/maps`) are detected and added to `Map=` automatically after installs and
  imports — custom maps first, base map (`Muldraugh, KY`) always last. New Mods-menu action
  rebuilds `Map=` from the active mods.
- `MODUPDATE_BACKUP_KEEP=0` disables pre-update world backups (range is now 0-3).

### Changed
- Re-adding an already-installed mod or collection is now instant: one batched Steam call
  classifies every item, current items are skipped, stale ones are re-downloaded as updates.
- World reset regenerates `ResetID` and guarantees a non-empty `ServerPlayerID`.
- README slimmed down; documented the update paths (game vs scripts).

### Fixed
- Importing a foreign `server.ini` no longer copies host-identity keys (`ServerPlayerID`,
  `ResetID`, `Seed`, `SteamVAC`, `server_browser_announced_ip`) — copying these could leave
  clients stuck at "Getting Server Info". Foreign `Map=` entries are filtered to maps that
  exist locally.
- Re-adding a collection no longer re-activates disabled mods or duplicates them across the
  active and disabled lists; their files still get refreshed.

## v2.0.0 — 2026-08-10 — B42 stable, mod auto-updates, pzctl expansion

Repo renamed **zomboid-b42-on-arm → ZomboidServer-arm** (old links redirect).
Everything below was tested end-to-end on a live Oracle Ampere box in an isolated
side-by-side install before release.

### Added
- **Branch selection** in `install.sh`: live branch list from Steam with a built-in
  fallback; `public` (B42 stable) is the default now that the old `unstable` beta
  branch is gone; the choice is remembered for re-runs.
- **Workshop mod auto-updates**: every mod added through `pzctl` is tracked in a
  manifest; `pz-modupdate check|apply|auto` + a systemd timer compare against Steam,
  wait until the server has been empty for a configurable time (player count via
  RCON), take rotating pre-update world backups (1-3 kept, default 2), apply, restart,
  and record everything in a 1000-entry-capped log. Optional check-on-restart mode.
- **pzctl**: mods submenu with multi-remove (`2 5 7-9`), remove-all, reorder
  (`3 1 2` or `5>1`), disable/enable without uninstalling, and import of mods +
  load order + settings from another `server.ini` (file or URL); RCON **admin
  console**; **world reset** with confirmation and backup; **sandbox settings**
  editor with automatic backup/restore; Status now shows every directory the
  server uses plus branch and game version.
- **Raspberry Pi 4/5**: the installer picks the Pi-optimized box64 package.
- Side-by-side/namespaced installs via env overrides (`PZ_SVC`, `PZ_INSTALL_DIR`,
  `PZ_CACHEDIR`, `PZ_PORT`, preseeded answers) — also how the test suite runs.

### Changed
- README rewritten for stable B42: branch table, ARM compatibility matrix, calmer
  uninstall wording.
- `uninstall.sh` covers the new units/scripts, prompts before removing the shared
  DepotDownloader, and follows `PZCTL_ENV` for namespaced installs.
- Shell architecture: shared logic lives in `scripts/common.sh`; `pzctl` and the
  updater both source it and resolve every path from the installer's env file.

### Fixed
- ini edits are injection-safe now: passwords/server names containing `|`, `&` or
  `\` no longer corrupt `servertest.ini` or the systemd unit (admin password is
  validated against characters the unit file can't carry).
- Update lock moved from `/tmp` to the game data dir: Ubuntu's
  `fs.protected_regular` silently blocked the root-run timer from locking a
  user-owned `/tmp` file.
- A failed or busy auto-update keeps the pending flag and retries on the next
  timer tick instead of dropping the update until the next scheduled check.
- Workshop downloads run in a temp dir owned by the game user; the root-run timer
  previously handed DepotDownloader an unwritable directory.
- The RCON client retries once shortly after boot (the RCON socket comes up a few
  seconds after the game port).

## v1.0.0 — 2026-07-03 — initial release

One-command installer + `pzctl` control panel for the Project Zomboid B42
(then `unstable`) dedicated server on ARM64 via box64: DepotDownloader instead of
steamcmd, ciopfs case-insensitivity overlay, tuned box64/JVM flags, hybrid
boot-hang watchdog, restart-until-listening boot loop, local-mod install flow.
