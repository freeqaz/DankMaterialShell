# Fork notes

A personal fork of [AvengeMedia/DankMaterialShell](https://github.com/AvengeMedia/DankMaterialShell)
(Dux Modular Shell since v2) carrying a few patches for a **GPD Pocket 4** (6" 1920x1200
panel, Goodix fingerprint reader, suspends many times a day).

Upstream never touches this file, so it never conflicts on a re-sync. Everything that
explains *why* a commit exists lives here or in the commit body — not in code comments
that a refactor will silently delete.

## Ground rules

- **The fork is based on upstream's latest RELEASE TAG, not `master`.** Since
  2026-11-10 (`2447c29ee core: switch from quickshell to dux-qt-base shared library`)
  a master build re-execs itself as `dms qs` and dlopens `libdux-qt-base.so.0`, which
  Arch's `quickshell` package does not provide: the UI dies instantly with
  `UI exited: exit status 127` and the unit hits its start limit (no shell at all).
  Release tags (v2.1.x) still run the system `qs`, matching the `dux-shell` package. Move
  to master only once a release ships the qtbase runtime and Arch packages it, or build
  with `QTBASE=1`.
- SHAs are not stable: each re-sync re-applies the fork commits onto the new tag and
  the branch is force-pushed.
- **Issues and pull requests go upstream**, not here.

## The commits

### `bar: taller floor and full-height widgets for a 6" 1080p panel`

**Upstreamable: no — never.** File: `Common/Theme.qml`.

Upstream's defaults give a 36px bar with 26px widgets. On a ~368 PPI panel that is
physically tiny and a poor touch target, and none of the constants is reachable from
`settings.json`. Since v2 all consumers (bar, dock, OSD, power menu) go through
`Theme.barWidgetThickness()` / `Theme.barThickness()`, so the patch is three edits there:

| Constant | Upstream | Fork | Sizes |
|---|---|---|---|
| `barWidgetThickness` baseline | `26` | `34` | the buttons |
| `Theme.barHeight` | `48` | `50` | the bar floor |
| `barThickness` widget term | `… + pad + 4` | `… + pad` | (margin comes from the gap) |

```
widgetThickness = max(20, 34 + pad * 0.6)
barThickness    = max(widgetThickness + pad, barHeight - 4 - (8 - pad))
```

laptop (`innerPadding 0`): 34px widgets in a **38px** bar (floor-bound);
tablet (`innerPadding 8`): ~**47px** (widget-bound). Values are pre-`snapEven`.

v1 deliberately left the dock/OSD/power-menu copies of the formula at 26 to avoid an
unverified visual change; v2 centralised the formula, so they now follow the real bar
height — the inconsistency that note warned about is gone.

**Verify after a re-sync:** `bar-profile laptop` → 38px bar / 34px widgets. Measuring
**36 / 44** means the commit did not survive.

### `display: pull brightness state instead of trusting the one push`

**Upstreamable: yes.** File: `Services/BrightnessService.qml` (was `DisplayService.qml`
before v2 split it).

The daemon can answer before its logind backend has enumerated the backlight, and
`updateSingleDevice()` can never *add* a device, so an empty first state stuck forever
(both brightness keys dead, CC slider greyed). Upstream v2 now pulls `getState` once on
connect (#3035) but still neither retries while empty nor consumes `brightness.rescan`
results. The fork retries `getState` at 1/2/4/8s while the list is empty and feeds rescan
responses into `updateFromBrightnessState()`, so resume/screen-change rescans heal it.
Drop this if upstream adds an empty-list retry.

### `cc: let plugin tiles set the square tile's icon weight`

**Upstreamable: probably.** Files: `Modules/Plugins/PluginComponent.qml`,
`Modules/ControlCenter/Widgets/PluginTile.qml`, `Modules/ControlCenter/Widgets/CcTile.qml`.

A compact CC tile (v2: `w: 2, h: 1` → `CcTile.compact`) is icon-only, so a plugin with
*levels* (the three-step `nightTint`) has only `isActive` — one bit. Material Symbols is a
variable font and `DIcon` animates its `wght` axis, so the fix is a passthrough:

| File | Change |
|---|---|
| `PluginComponent.qml` | `property int ccWidgetIconWeight: 0` |
| `PluginTile.qml` | `iconWeight: instance?.ccWidgetIconWeight ?? 0` |
| `CcTile.qml` | `property int iconWeight: 0`; both `DIcon`s use it when `> 0`, else upstream's `showsActive ? 500 : 400` |

`0` means "unset", so every other tile renders exactly as upstream (v1 used `400`, which
would now override upstream's 500-when-active emphasis).

A changing glyph reads as a changing *function*; a thickening stroke reads as more *of the
same* — which is what a level is. If upstream adds its own weight/emphasis API, drop this;
`nightTint` degrades to a plain on/off tile.

### `WIP idle: post-lock monitor-off ignores inhibitors; …`

Uncommitted work found in the tree at the 2026-11-17 re-sync, preserved as a commit so it
was not lost. `IdleService`: the post-lock monitor-off monitor never respects inhibitors,
and an external inhibitor only gates the base monitors when `respectInhibitors` is set.
Needs a real write-up (or a drop) — its intent was not documented.

## Retired commits (absorbed upstream by v2.1)

Dropped at the 2026-11-17 re-sync after reading upstream's `Modules/Lock/Pam.qml`; kept
here so nobody re-adds them:

| Fork commit | Upstream equivalent |
|---|---|
| `lock: recover from a wedged fprintd instead of re-forking PAM forever` | `errorRetry` backoff whose 2nd retry outlasts `daemonIdleExitMs` (lets fprintd idle-exit and reset), `recover()` on resume / lid-open / user activity |
| `lock: do not open a fingerprint PAM session during a suspend transition` | `fprint.allowed` gated on `SessionService.preparingForSleep` / `sleepRequested` (`ba8c4e60a`) |
| `lock: do not let untouched verify windows disarm the fingerprint reader` | `attemptSettled()` — an attempt older than `sessionTimeoutMs - slack` is a benign timeout, not a fault; plus `retryFprintOnActivity()` presence gate |

If the fingerprint reader starts going dead on an idle lock screen again, compare against
these first.

## Build and install

The fork **shadows** the `dux-shell` package rather than replacing it — nothing under
`/usr` is touched and the packaged shell remains a working fallback.

```sh
git submodule update --init                    # dux-qml-common (DCommon) is required
make build                                     # AS YOUR USER — never sudo
sudo install -m755 core/bin/dms /usr/local/bin/dms.new && sudo mv -f /usr/local/bin/dms.new /usr/local/bin/dms
sudo make install-completions PREFIX=/usr/local
systemctl --user restart dms                   # NOT while locked
```

- Since v2 the **QML is embedded** in the binary (`-tags withshell`); there is no
  `install-shell` target and no `/usr/local/share/quickshell/dms` tree any more.
  **Never set `DMS_SHELL_DIR`** to the old v1.5 tree from a v2 binary.
- Install by **rename** (`mv`), so the running process keeps its old inode.
- **Skip `install-systemd`** and the bare `install` / `uninstall` targets — they write or
  delete `~/.config/systemd/user/dms.service`, which replaces the package unit wholesale.
- The binary **must** support `sd_notify`: the package unit is `Type=notify` with
  `TimeoutStartSec=90`. A binary that never sends `READY=1` is SIGTERMed every 90s
  (exit 143) — on 2026-11-17 that ran all afternoon and orphaned the session lock on every
  kill. Check: `strings /usr/local/bin/dms | grep 'report shell readiness'`.

### How the fork is selected

```ini
# ~/.config/systemd/user/dms.service.d/10-local-fork.conf
[Service]
ExecStart=
ExecStart=/usr/local/bin/dms run --session
```

Delete the drop-in (+ `daemon-reload` + `restart`) to fall back to `/usr/bin/dms`.

## Remotes

```sh
origin      git@github.com:freeqaz/DankMaterialShell.git      # this fork; push here
upstream    https://github.com/AvengeMedia/DankMaterialShell  # re-sync from this
```

## Re-syncing with upstream

```sh
git fetch upstream --tags
NEW=$(git tag -l 'v*' --sort=-v:refname | head -1)
OLD=$(git describe --tags --abbrev=0 HEAD)                       # current base tag
git branch backup/pre-$NEW HEAD
git switch -c fork-$NEW $NEW && git submodule update --init
git cherry-pick $OLD..backup/pre-$NEW                            # rerere helps
```

**Never resolve a conflict with `--skip` without reading what upstream did** — it drops
*our* commit and looks like success. (It was correct for the three retired lock commits
above, and only after checking upstream's code.)

Invariants before rebuilding:

```sh
grep -n 'barHeight: 50' quickshell/Common/Theme.qml                          # 1 hit
grep -n 'Math.max(20, 34' quickshell/Common/Theme.qml                        # 1 hit
grep -c brightnessPullRetry quickshell/Services/BrightnessService.qml        # 5
grep -c 'root.iconWeight > 0' quickshell/Modules/ControlCenter/Widgets/CcTile.qml  # 2
```

Then build/install as above, and do the first restart with a terminal open and the screen
unlocked. Expect a one-time `settings.json` migration on a major bump (v1.5 → v2.1 went
config 13 → 42: `showDock` → `dockConfigs[].enabled`, `cornerRadius` → `radiusStrength`,
CC `width` → `w`/`h`, bar widgets become objects); back the file up first.
