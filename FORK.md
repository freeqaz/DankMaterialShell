# Fork notes

A personal fork of [AvengeMedia/DankMaterialShell](https://github.com/AvengeMedia/DankMaterialShell)
carrying four patches for a **GPD Pocket 4** (6" 1920x1200 panel, Goodix fingerprint
reader, suspends many times a day).

Upstream never touches this file, so it never conflicts on a rebase. Everything that
explains *why* a commit exists lives here or in the commit body — not in code comments
that a refactor will silently delete.

## Ground rules

- **`master` is rebased onto upstream `master`**, not merged. SHAs are not stable and
  the branch is force-pushed. Anything built on top of it must be rebased too.
- **Issues and pull requests go upstream**, not here.
- Two of the four commits are general bug fixes that are worth upstreaming, one is a
  small generic capability that could be, and one is device tuning that never should be.

## The commits

### 1. `lock: recover from a wedged fprintd instead of re-forking PAM forever`

**Upstreamable: yes.** Files: `Modules/Lock/Pam.qml`, `Modules/Lock/LockScreenContent.qml`.

The failure this fixes: fprintd/libfprint gets into a state where the device is claimed
but every verify returns an immediate error. Upstream reacts by restarting the fprint
`PamContext` up to 200 times on a 1.5s–30s backoff. Each restart `fork()`s a PAM child
out of the multithreaded shell process, and — the important part — fprintd only clears
that state once it has been left alone long enough to hit its idle timeout and exit. So
the retry loop actively prevents the recovery it is waiting for. It is also completely
silent: the icon stays `fingerprint`, the status line says nothing, and the user just
sees a reader that does not respond.

The replacement is a three-state model — armed → degraded → user re-arm:

- A small consecutive-hard-error budget (`maxErrorTries = 4`). Past it, `degraded` is
  set, we stop talking to fprintd entirely, `fprintState` becomes `"unavailable"`, and
  the icon goes to `fingerprint_off` in the error colour with a status line pointing at
  the password field.
- `PamResult.MaxTries` is explicitly **not** the wedged case — the reader physically
  read a finger, so the stack is alive. The error budget is reset there, so a run of bad
  swipes can never be misdiagnosed as a hardware fault.
- Recovery is user-driven: clicking the lock icon while degraded (or after
  `maxFprintTries`) calls `rearm()`, which clears both budgets and the sticky status and
  re-arms. Fingerprint stays available for the rest of the lock session instead of being
  a one-shot.

There is a second, subtler fix inside it: **every** `start()` now funnels through
`armStart()` → the `fprintArm` Timer (400ms), and nothing calls `start()` directly.
Calling `start()` synchronously from a `completed()` handler forks a new PAM child while
the C++ `PamContext` is still unwinding the previous `PamConversation` through
`deleteLater()`, so two PAM children briefly race for a device that only supports one
claim — which is itself one of the ways the reader gets wedged. If a future rebase
introduces a new `start()` call site, it must go through `armStart()`.

The error backoff is also lengthened to 4s–60s: a retry costs a process fork plus a full
fprintd verify timeout, so retrying cheaply is not cheap.

### 2. `lock: do not open a fingerprint PAM session during a suspend transition`

**Upstreamable: yes.** File: `Modules/Lock/Pam.qml`.

With `lockBeforeSuspend` + `enableFprint`, DMS locks ~100ms after logind emits
`PrepareForSleep(true)`, and the new lock screen immediately opens its `"fprint"` PAM
session — D-Bus-activating fprintd in the middle of the sleep transition. Three
consequences:

1. fprintd acquires its logind sleep-delay inhibitor only in the **resume** branch of
   `handle_prepare_for_sleep_signal()`, and never retries. A fprintd started here logs
   `Failed to install a sleep delay inhibitor: ...OperationInProgress` and then runs
   inhibitor-less for its whole lifetime, so every later suspend can cut it off
   mid-verify.
2. fprintd's `ExecStartPre` writes `power/control=on` for the reader — a USB runtime
   *resume* of the device ~1.4s before the xHCI bus itself suspends. A plausible source
   of the intermittent `hcd_pci_suspend returns -16` aborts that make the kernel retry
   the suspend.
3. Nobody can present a finger while the machine is going to sleep, so the prompt is
   pure waste even when it works.

The fix mirrors upstream's own `fprintSuppressedByPrimaryPam` idiom: a readonly
`fprintSuppressedBySleep: SessionService.preparingForSleep`, ORed into every arm
precondition, plus an `onFprintSuppressedBySleepChanged` handler that re-runs
`fprint.checkAvail()` when it clears. Resume, idle-lock and manual-lock are all
unaffected — the reader re-arms the moment `preparingForSleep` goes false.

The handler also cancels `errorRetry` explicitly, because clearing the preconditions is
not sufficient on its own: a retry timer already counting down when the suspend began
would otherwise fire ~1.5s into the transition and fork a PAM child anyway.

> **Rebase hazard.** There are **four** arm sites and all four carry the guard:
> `fprint.armStart()`, `fprint.checkAvail()`, `fprint.rearm()`, and the `fprintArm`
> Timer's `onTriggered`. They are deliberately not collapsed into one helper — each is a
> distinct entry point (programmatic re-arm, state re-evaluation, user click, deferred
> start). A half-merge that extends only some of them produces a build that works
> perfectly *except* across a suspend, which is the one path nobody exercises before
> shipping.
>
> Post-rebase check — every guard line must mention both properties:
>
> ```sh
> grep -c 'root\.fprintSuppressedByPrimaryPam' quickshell/Modules/Lock/Pam.qml   # 4
> grep 'root\.fprintSuppressedByPrimaryPam' quickshell/Modules/Lock/Pam.qml \
>   | grep -vc 'fprintSuppressedBySleep'                                         # 0
> grep -c fprintSuppressedBySleep quickshell/Modules/Lock/Pam.qml                # 6
> ```
>
> (6 = the property, the `if (fprintSuppressedBySleep)` line in the change handler, and
> the four guards. `grep` is case-sensitive, so `onFprintSuppressedBySleepChanged` does
> not match.)
>
> The pass condition for this fix is a **negative**: after a suspend/resume cycle,
> `journalctl` must contain no `Failed to install a sleep delay inhibitor` from fprintd.

### 3. `bar: taller floor and full-height widgets for a 6" 1080p panel`

**Upstreamable: no — never.** Files: `Common/Theme.qml`, `Modules/DankBar/DankBarBody.qml`.

Upstream's defaults give a 36px bar with 26px widgets. On a 6" 1920x1200 panel
(~368 PPI) that is both physically tiny and a poor touch target, and none of the three
constants involved is reachable from `settings.json`.

Two independent knobs — the widget baseline sizes the **buttons**, `barHeight` sizes the
**bar** (as a floor, not a height), and the gap between them is the buttons' vertical
margin:

| Constant | Upstream | Fork | Sizes |
|---|---|---|---|
| `DankBarBody.widgetThickness` baseline | `26` | `34` | the buttons |
| `Theme.barHeight` | `48` | `50` | the bar floor |
| `effectiveBarThickness` widget term | `… + pad + 4` | `… + pad` | (margin now comes from the gap) |

```
widgetThickness       = max(20, 34 + pad * 0.6)
effectiveBarThickness = max(widgetThickness + pad, barHeight - 4 - (8 - pad))
```

| Mode | `innerPadding` | Widgets | Bar | Bound by |
|---|---|---|---|---|
| laptop | 0 | 34 | `max(34, 38)` = **38** | floor |
| tablet | 8 | 38.8 | `max(46.8, 46)` = **46.8** | widgets |
| *(upstream, laptop)* | 0 | 26 | `max(30, 36)` = *36* | floor |
| *(upstream, tablet)* | 8 | 30.8 | `max(42.8, 44)` = *44* | floor |

These are **pre-snap** values. Both expressions are wrapped in `Theme.snap(v, _dpr)`,
which rounds to the device-pixel grid, so the numbers actually rendered depend on the
output scale. At the GPD Pocket 4's `scale 2.00` tablet mode lands on **39 / 47**, not
38.8 / 46.8. Laptop mode is already integral and is exact at any scale.

Laptop mode becomes floor-bound: a 38px bar with 34px widgets centred in it — the ~2px
vertical margin a flat 26-in-36 fill never had. Tablet mode stays widget-bound and is
unchanged at ~47px; raising the floor only pads the laptop bar, which is the intent.
Combined with bar `spacing: 0` in `settings.json`, the taller bar stays flush to the
screen edge.

**Verification after a re-sync:** `bar-profile laptop` → 38px bar / 34px widgets;
`bar-profile tablet 1` → ~47px. Measuring **36 / 44** means this commit did not survive
the rebase.

#### Deliberate divergence: the dock, the OSD and the power menu

The `26` baseline is duplicated — uncoupled — far more widely than the one site this
commit patches. As of `upstream/master` there are **10 further occurrences across 8 files**:

```console
$ grep -rn '26 + ' quickshell/ --include='*.qml' | wc -l
10
```

| File | Occurrences |
|---|---|
| `Common/SettingsData.qml` | 2 |
| `Modules/DankBar/Widgets/RunningApps.qml` | 2 |
| `Modals/PowerMenuModal.qml` | 1 (an inlined copy of the whole `effectiveBarThickness` formula, `+ 4` and all) |
| `Modules/DankBar/Widgets/AppsDock.qml` | 1 |
| `Modules/Dock/DockBody.qml` | 1 |
| `Widgets/DankOSD.qml` | 1 |
| `Widgets/DankPopoutConnected.qml` | 1 |
| `Widgets/DankPopoutStandalone.qml` | 1 |

**None of them is patched.** They keep computing 26-based values, so they position
themselves as if the bar were 36/44px while it is actually 38/47px. This is not an
oversight: it is exactly the behaviour this machine has run with since the original
`sed`-patched fork, and changing it would bundle an unverified visual shift into commits
that get replayed by hand across upstream refactors for years. If any misalignment ever
becomes visible, fix it as a **separate** commit so it can be reverted on its own.

Note the two shapes are not interchangeable — `DockBody`/`DankOSD` duplicate the
`max(20, 26 + pad*0.6)` *widget* expression, while `RunningApps`/`AppsDock` duplicate the
`max(26 + pad*0.6, barHeight - 4 - (8 - pad))` *bar* expression. A future de-duplication
has to keep them distinct.

**Re-sync check:** the count above is the invariant to re-assert, not just the two
patched sites. If `grep -rc '26 + '` returns something other than 10, upstream has added
or removed a copy and this section is stale.

### 4. `cc: let plugin tiles set the square tile's icon weight`

**Upstreamable: probably.** Files: `Modules/Plugins/PluginComponent.qml`,
`Modules/ControlCenter/Components/DragDropGrid.qml`,
`Modules/ControlCenter/Widgets/SmallToggleButton.qml`. 11 lines, all additive.

A control-center tile at `width: 25` renders as `SmallToggleButton` — an icon-only
square with no label. That is the right shape for a frequently-tapped toggle, but it
leaves a plugin only `isActive` to communicate with: one bit. A plugin with *levels*
(here: a three-step night tint) has no way to say **which** level is active.

Material Symbols is a variable font and `DankIcon` already exposes — and animates — its
`wght` axis. So the fix is a passthrough, not a new widget:

| File | Change |
|---|---|
| `PluginComponent.qml` | `property int ccWidgetIconWeight: 400` |
| `DragDropGrid.qml` | `pluginSmallToggleComponent` binds `iconWeight: pluginInstance?.ccWidgetIconWeight ?? 400` |
| `SmallToggleButton.qml` | `property int iconWeight: 400`, passed to the `DankIcon` |

`400` is `DankIcon`'s own default, so every existing tile renders identically — the
property is inert until a plugin sets it.

**Why not just swap the glyph per level?** A plugin can already do that with
`ccWidgetIcon`, no fork needed. But a changing glyph reads as a changing *function*,
while a thickening stroke reads as more *of the same* function — which is what a level
is. Weight also animates continuously; a ligature swap pops.

**Re-sync check:** if upstream gives `SmallToggleButton` its own weight/emphasis
handling, or routes plugin tiles through a different component, drop this commit rather
than reconciling it — the consumer (the `nightTint` plugin) degrades to a plain on/off
square, not a broken one.

## Build and install

The fork **shadows** the `dms-shell` / `dms-shell-hyprland` packages rather than
replacing them — nothing under `/usr` is ever touched, so `pacman -Qkk dms-shell` stays
clean and the packaged shell remains a working fallback.

```sh
git submodule update --init --recursive        # quickshell/DankCommon is a symlink
                                               # into dank-qml-common; both `make build`
                                               # and `make install-shell` hard-fail
                                               # without it
make build                                     # AS YOUR USER — never sudo
sudo make install-bin install-shell install-completions install-icon install-desktop \
     PREFIX=/usr/local
```

- **Never `sudo make build`.** A root `go build` poisons `/root/go/pkg/mod` and leaves
  root-owned artifacts in the tree.
- **Skip `install-systemd`** (`Makefile:74`). It writes
  `~/.config/systemd/user/dms.service`, which *replaces* the packaged unit wholesale, is
  invisible to the `deploy` script that manages this machine's dotfiles, and makes
  rollback ambiguous. Note the bare `install` target (`Makefile:101`) chains it — which
  is why the targets above are enumerated explicitly rather than using `make install`.
- **`install-shell` never prunes** — `Makefile:60` is a plain `cp -rL`. On every
  re-install, pair it with `uninstall-shell` (`Makefile:113`) or files that upstream
  renamed or deleted will linger in the installed tree and get loaded.
- Likewise, do **not** use the bare `uninstall` target (`Makefile:145`) — it chains
  `uninstall-systemd`, which would `rm` a unit file that is not ours.

### How the fork is actually selected

Upstream master **removed** the old filesystem probe (`DMS_LOCAL_PATH` no longer exists
anywhere in the tree; `core/cmd/dms/commands_root.go` documents `-c` / `$DMS_SHELL_DIR`
as the only override) and builds with `-tags withshell`, so absent an override **the QML
is embedded in the binary**. Selection is therefore done by a systemd drop-in:

```ini
# ~/.config/systemd/user/dms.service.d/10-local-fork.conf
[Service]
ExecStart=
ExecStart=/usr/local/bin/dms run --session
Environment=DMS_SHELL_DIR=/usr/local/share/quickshell/dms
Environment=DMS_DISABLE_HOT_RELOAD=1
```

`DMS_DISABLE_HOT_RELOAD=1` is **mandatory, not optional**: it closes the window during
`uninstall-shell` → `install-shell` where the tree the live shell is watching does not
exist.

That gives a three-rung fallback ladder:

| Remove | Falls back to |
|---|---|
| the `DMS_SHELL_DIR` line | the fork binary's *embedded* UI — isolates "QML problem" from "binary problem" |
| the whole drop-in | `/usr/bin/dms` + the packaged release |
| the `/usr/local` tree | nothing left of the fork |

> **`DMS_SHELL_DIR` must never be exported globally** (e.g. from a compositor
> `environment.lua`). The packaged binary honours it too, so a global value would feed
> this fork's QML to the packaged binary after a rollback. Confining it to the drop-in
> means one `rm` reverts both halves together.

## Remotes

Conventional layout — `origin` is this fork, `upstream` is the project it forks:

```sh
origin      git@github.com:freeqaz/DankMaterialShell.git      # this fork; push here
upstream    https://github.com/AvengeMedia/DankMaterialShell  # rebase onto this
```

`master` tracks `origin/master`, so a bare `git push` goes to the fork. Re-syncing is
always explicit against `upstream` — a bare `git pull` only ever pulls the fork back.

## Re-syncing with upstream

```sh
git fetch upstream
git rebase upstream/master                     # NEVER --skip: it silently drops a commit
git submodule update --init --recursive        # upstream may have bumped the pointer
make build && sudo make uninstall-shell install-shell install-bin PREFIX=/usr/local
git push --force-with-lease                    # history is rewritten every re-sync
```

`--force-with-lease`, never a bare `--force`: the rebase gives every commit a new SHA, and
the lease is what stops you clobbering a push you had forgotten about.

Configured once, and assumed by the above:

```sh
git config pull.rebase true
git config rebase.autoStash false              # fail loudly on a dirty tree
git config rerere.enabled true                 # the same Pam.qml / DankBarBody.qml
                                               # conflicts recur every re-sync
```

If a conflict is not obvious, `git rebase --abort`, read what upstream actually did, and
retry. `--skip` resolves a conflict by dropping *our* commit and looks like success.

Then re-check the invariants before rebuilding:

```sh
grep -c fprintSuppressedBySleep quickshell/Modules/Lock/Pam.qml        # 6
grep -n 'barHeight: 50' quickshell/Common/Theme.qml                    # 1 hit
grep -n 'Math.max(20, 34' quickshell/Modules/DankBar/DankBarBody.qml   # 1 hit
```

and rebuild:

```sh
make build
sudo make uninstall-shell
sudo make install-bin install-shell install-completions install-icon install-desktop \
     PREFIX=/usr/local
systemctl --user restart dms
```

Push with `--force-with-lease`, never plain `--force`.

**Never restart DMS while the screen is locked.** `ext-session-lock-v1` keeps the screen
locked if the lock client dies, and two of these three commits touch the lock screen. Do
the first restart after any rebuild with a terminal open and a TTY one keystroke away;
`loginctl unlock-session` from a TTY is the escape hatch.
