# Thunderbox — Initial Decisions

_Author: Claude (autonomous). Date: 2026-08-12. The user was away and asked me to make
all decisions and record them here._

## What Thunderbox is
A small native macOS app that discovers runnable scripts (npm scripts, shell scripts,
custom commands) across one or more project folders, presents each as a one-button
service, runs each in its own isolated process group, and specializes in **web servers**:
detecting their URL/port, showing RAM, reporting failures, and offering restart.

## Tech stack — decided
- **Native SwiftUI + AppKit**, not Electron/Tauri. Reasons: "small Mac app", real
  native process control, accurate per-process RAM, clean guaranteed shutdown on quit,
  no runtime deps. Toolchain present: Xcode 26.4.1 / Swift.
- **Swift Package Manager executable** + a `build-app.sh` that assembles `Thunderbox.app`
  (Info.plist + icon). No `.xcodeproj` — fully reproducible from the CLI (`swift build`).
- **Swift language mode: v5** (set in Package.swift) to avoid Swift 6 strict-concurrency
  churn on a Foundation `Process`-heavy app. Deliberate.
- Minimum macOS: 14 (needed for value-based `openWindow` multi-window console).

## How scripts are launched — decided (the crux)
The user requires each script to inherit their default zsh environment so `nvm` and `rye`
resolve. Verified: `nvm` and `rye` are initialized in `~/.zshrc` (interactive), so a plain
login shell is not enough. Launch recipe (verified to expose node/npm/rye):

    /usr/bin/perl -e 'use POSIX qw(setsid); setsid(); exec @ARGV or die $!' \
        /bin/zsh -ilc "cd <folder> && exec <command>"   (stdin < /dev/null)

- `zsh -ilc` = interactive+login → sources `.zshrc` → nvm + rye + full PATH.
- `perl … setsid()` puts the job in its **own session/process group** (pgid == pid), so the
  entire process tree (npm → node → webpack, or zsh → flask) can be killed with `kill(-pid)`.
  macOS has no `setsid(1)` binary; the perl one-liner is the dependency-free equivalent.
- stdin is `/dev/null` so interactive shells never block on a prompt.

## Feature decisions
- **Discovery** (Add Folder…): scans the folder (root + shallow subdirs) and surfaces
  candidates from (1) `package.json` `scripts`, (2) `*.sh` files, and (3) a manual
  "custom command" entry (covers e.g. soc2's `python3 scripts/status.py` from its README,
  which isn't a script file). User picks which candidates to add.
- **Server heuristic + ordering**: each candidate is scored for "starts a web server" by
  scanning its command (npm scripts follow `run-p`/`run-s`/`npm-run-all` into sibling
  scripts; `.sh` files are read) for tokens: vite, webpack serve / webpack-dev-server,
  next/nuxt/astro/remix/gatsby dev, nodemon, ts-node-dev, flask run, uvicorn, gunicorn,
  rails server, serve, http-server, live-server, concurrently, php -S, http.server,
  `-p`/`--port`/`PORT=`, listen; script names dev/start/serve/develop/preview boost.
  In the add sheet and main list, **servers sort to the top** and get a badge; a
  "servers only" filter is offered.
- **URL/port detection at runtime**: regex over live output for `http(s)://localhost|
  127.0.0.1|0.0.0.0|[::1](:port)`, plus "listening/running/ready on port N", vite/webpack/
  flask banners. `0.0.0.0` is normalized to `localhost` for a clickable link. Also
  pre-seeds a port parsed from the command (`-p N`, `--port N`, `PORT=N`).
- **State machine**: idle → starting → running → (stopped | failed). `failed` = nonzero
  exit or crash; `stopped` = clean exit / user stop. Restart offered on failed & stopped.
- **RAM**: every 2s, `ps -o rss= -g <pgid>` summed → MB, shown per running service.
- **Console**: output is always captured to a capped ring buffer (~5000 lines) in the
  background; a per-service **console window** is opened on demand (hidden by default).
  ANSI escapes are stripped; **stdout = default color, stderr = red** (the color coding).
  Clickable detected URL in the header.
- **Persistence**: `~/Library/Application Support/Thunderbox/services.json`. Stores the
  service definitions only. **No running state persisted** → on launch nothing auto-starts.
- **Quit**: `applicationShouldTerminate` stops every running service (SIGTERM to the group,
  5s grace, then SIGKILL) before the app exits. Requirement: quit kills all servers.

## Icon
The icon you pasted lives only in our chat as an image — it is not a file on disk, so I
can't embed those exact pixels. I generated a themed placeholder (dark rounded square,
terminal prompt) via `assets/gen-icon.swift`. To use the real outhouse icon:
drop it at `assets/icon.png` (1024×1024) and rerun `./build-app.sh` — the build converts
whatever `assets/icon.png` is present into `Thunderbox.icns` automatically.

## Decisions made while verifying (worth calling out)
- **No `exec` before the command.** I first prefixed the command with `exec` so the tracked
  PID would be the server itself. But `exec A && B` makes the shell replace itself with `A`
  and silently drops `&& B` — which would break any compound custom command and swallow exit
  codes. Because `setsid` already guarantees group-kill tears down the whole tree, `exec`
  bought nothing. Dropped it: now zsh runs `cd <dir> && <command>`, compound commands work,
  and the real exit code propagates (verified: `export X=1 && python … exit 3` → Failed(3)).
- **`PYTHONUNBUFFERED=1` in the child env.** Python block-buffers stdout/stderr when it's a
  pipe (not a tty), so a server's "Serving on …/URL" banner never arrived. Rather than switch
  to a PTY (which merges stdout+stderr and would kill the stderr=red distinction the user
  asked for), I keep separate pipes and set `PYTHONUNBUFFERED` so Python output is prompt.
  Node/vite/webpack already flush to pipes promptly (verified). Trade-off accepted: a rare
  C program that block-buffers stdout may show its banner late; runtime URL detection plus the
  command-parsed port cover the common cases.
- **Verification done headlessly.** This automation context lacks Screen-Recording and
  Accessibility (TCC) permissions, so I could not screenshot or click the live GUI. Instead I
  drove the *actual* `ServiceRunner` end-to-end: start → state=Running → URL detected (seeded
  port + refined from live output) → RAM sampled (17→20 MB) → stop → Stopped → process group
  confirmed dead. Also verified Failed(code) vs clean Stopped, and the script scanner/URL
  regex against all four reference projects. The bundled app launches and stays alive (scene
  loads and `services.json` parses without crashing). When you open it yourself, macOS will
  ask once for the permissions it needs.

## Round 2 (follow-up requests)
- **Woods theme.** Added `Theme.swift` — a deep pine/moss palette pulled straight from the
  icon: background gradient from dark moss `#1A2117` → near-black pine `#0B0F0B` with a faint
  green "clearing" glow; row/panel surfaces a lifted translucent green-black; **console** an
  even darker terminal-glass `#090E0A`. Accents: phosphor **green** `#75DB78` (running, links
  to start), warm **amber/brass** `#F5B852` (URLs, starting, system log notes), ember **red**
  `#F06B5C` (failed, stderr). Text is warm off-white on muted sage. App is pinned to dark
  appearance. The main list moved from `List` to a `ScrollView` of rounded cards so the
  background reads cleanly; running cards get a green edge glow.
- **Larger type.** Applied `.dynamicTypeSize(.xLarge)` at the root of both windows, bumping
  every semantic font (`.body`/`.caption`/…) up one notch across the whole UI, and raised the
  fixed console monospace from 11.5 → 13pt.
- **Add / Edit command screen** (`ServiceEditor.swift`). Reached three ways: the header
  **Add Command…** button, each row's **pencil** button, and the row context menu **Edit…**.
  Fields: name, folder (with Choose…), the command (monospaced, multi-line), and an
  "is a web server" switch that auto-guesses from the command but can be overridden. This is
  the escape hatch for when folder-scanning doesn't surface the right script (e.g. soc2's
  `python3 scripts/status.py`). Editing persists immediately; Remove is available inline.
- **Real icon.** You dropped `icon.png` in the project root; `build-app.sh` now prefers
  `./icon.png` (falling back to `assets/icon.png`, then the generated placeholder) and it's
  baked into `Thunderbox.icns`.

## Round 3 (follow-ups)
- **Drag-to-reorder + manual order.** The list is a native `List` with `.onMove`; order is
  now user-owned and persisted, so the old servers-first auto-sort was removed (it only seeds
  the order of a freshly scanned folder now). Reordering also works under "Servers only" —
  hidden rows keep their absolute slots (id-mapping, unit-tested on filtered/unfiltered).
- **Reveal in Finder** context-menu item — reveals the folder, selecting the script file when
  the command points at a local one (`./run.sh`).
- **Python server discovery.** Scans `*.py` (root + immediate subdirs) but only surfaces files
  that actually *start* a server — i.e. contain a launch call (`serve_forever`, `app.run(`,
  `uvicorn.run`, `make_server(`, `runserver`, `socketserver.`, …) or a runner-launched import
  (`import streamlit` → `streamlit run x.py`). Merely importing flask/fastapi/etc. is **not**
  enough — that was flooding results with library modules (`logging.py`, `schemas.py`). Runs
  from the scanned root with a repo-root-relative path (`python3 scripts/browse.py`), matching
  convention. Verified on `~/Projects/soc2/scripts/browse.py` (found, port 8777 auto-parsed
  from its argparse default) with zero utility-script noise; `flask run`-style app modules
  like hyperspace `main.py` are intentionally left to shell/npm discovery (its `run.sh`).
  New `ServiceKind.python` gets a "python" badge.
- **In-window app icon.** The header badge is now the bundled `favicon.png` (your pixel-art
  mark), clipped to a rounded app-tile, replacing the SF Symbol leaf. `build-app.sh` copies
  `favicon.png` into the bundle; `AppMark` loads it with an SF Symbol fallback.

## Round 4 (follow-ups)
- **Top-level name = folder name.** A service's big title is now the project/folder name
  (`reference-client`), and the specific command moved to the subtitle (monospaced), so
  multiple scripts from one folder stay distinguishable. The Add sheet still labels candidates
  by *script* (so you choose by script but manage by project); the folder path is on hover.
  Custom/edited services default their name to the folder name too. Existing demo services
  were renamed in place (order/ids preserved).
- **Per-project icons.** Each service can have a custom icon, set by **choosing an image file
  or pasting one** (screenshot, copied image, or copied image file). Icons are stored as
  downscaled (≤256px) PNGs under `…/Thunderbox/icons/<id>.png`, cached in memory, and shown as
  a rounded leading avatar in each row with the status dot as a glowing corner badge (a
  placeholder tile shows when none is set). Set it from the **Edit** screen's icon well, or the
  row's right-click **Icon ▸ Choose Image… / Paste Image / Remove Icon**. Deleting a service
  removes its icon file. `ImageIntake` handles clipboard/file intake; `ServiceStore` handles
  persistence + an `iconVersion` publish so rows refresh live.
- **Header badge removed.** An in-window favicon badge next to the title was tried and then
  removed at the user's request — the header now shows just the "Thunderbox" title. (The Dock/
  Finder app icon, built from `icon.png` → `Thunderbox.icns`, is unaffected.)

## Round 5 (follow-ups)
- **Warmer background.** Shifted the base from near-black green woods to a lifted warm
  blue-slate/indigo (bottom luminance ~0.05 → ~0.11), tint moved off green toward indigo;
  cards, console glass, and secondary text re-tuned to match. Still blue, less black.
- **Custom About box.** `Thunderbox ▸ About Thunderbox` now opens a themed window (replacing
  the standard `.appInfo`) showing the app icon over the copy *"Local development. / One
  convenient seat."* and the version. Implemented as a single `Window(id: "about")` opened via
  `openWindow` from a menu command. (Couldn't click-test it here — Accessibility permission
  isn't granted to this automation context — but it compiles and the app runs clean.)
- **App icon → `icon-day.png`.** `build-app.sh` now prefers `icon-day.png` for `Thunderbox.icns`;
  the About box pulls the same icon via `NSApp.applicationIconImage`.

## Round 6 (follow-ups)
- **Real code signing.** `build-app.sh` no longer ad-hoc signs: it auto-selects the first
  available identity — Developer ID Application → Apple Development → ad-hoc — and adds hardened
  runtime + secure timestamp only for a Developer ID build (required for notarization).
  Override with `SIGN_IDENTITY`. NB: the keychain currently has only *Apple Development* and
  *Apple Distribution* (App Store) certs — **no Developer ID**, so builds sign for this Mac but
  aren't Gatekeeper-valid elsewhere until a Developer ID Application cert is created.
- **DMG + notarization plumbing.** `make-dmg.sh` builds the app, packages a drag-to-install
  `Thunderbox.dmg`, and — only when notarization creds are present (`NOTARY_PROFILE`, or
  `NOTARY_APPLE_ID`/`NOTARY_PASSWORD`/`NOTARY_TEAM_ID`) and the app is Developer-ID-signed —
  submits to `notarytool` and staples. Otherwise it cleanly skips. The release workflow imports
  a Developer ID cert from repo secrets (`MACOS_CERT_P12`/`MACOS_CERT_PASSWORD`) into a temp
  keychain and passes notary secrets, all gated so it still builds an ad-hoc DMG without them.
  README documents the cert + secrets setup. (Plumbing is dormant until the cert exists.)
- **Quit teardown hardened.** `stopAllForQuit()` now derives its kill list from the live runner
  processes (`ServiceRunner.livePID`) rather than UI state, so every running server's process
  group is SIGTERM'd (4s grace → SIGKILL) before the app exits — no server can outlive a quit.

## Explicitly out of scope (kept small on purpose)
Full ANSI terminal emulation (interactive TUIs); editing a service's env vars in-app
(they inherit zsh); recursive deep folder crawl; code signing/notarization (local use).
