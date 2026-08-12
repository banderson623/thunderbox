# Thunderbox

**Fire up your local crap.**

Thunderbox is a tiny Mac app for starting, stopping, and keeping an eye on all the local services that make your projects go.

Point it at your project folders and Thunderbox sniffs out runnable scripts, npm commands, and local web servers. Your services are collected into one tidy control panel where you can fire them up, shut them down, restart the ones that blew up, and jump straight to whatever port they're squatting on.

No terminal farm. No remembering which command starts which thing. No wondering whether that server from three hours ago is still lurking somewhere.

Each service gets its own name, icon, status, URL, memory usage, and hidden terminal. When something goes sideways, crack open the terminal and inspect the exhaust.

Thunderbox starts nothing until you tell it to. And when Thunderbox quits, it flushes everything.

> **Thunderbox** — Local development. One convenient seat.

---

## Build & run

```bash
./build-app.sh          # -> build/Thunderbox.app
open build/Thunderbox.app
```

`build-app.sh` compiles a release binary and assembles `build/Thunderbox.app` (icon +
Info.plist, signed with your first available identity). Requires the Xcode/Swift toolchain.

To build and install into `/Applications` in one step (quits any running copy, replaces it):

```bash
./install.sh
```

To build a distributable disk image:

```bash
./make-dmg.sh   # -> build/Thunderbox.dmg
```

## Using it

1. **Add Folder…** — pick a project. Thunderbox scans it (and its immediate subfolders) for
   `package.json` scripts, `*.sh` files, and Python files that actually start a server, decides
   which ones are web servers, and lists servers first with a `server` badge. Tick the ones you
   want (servers are pre-ticked).
2. Or **Add Command…** (or the pencil / **Edit…** on any row) to type or change a command by
   hand — name, folder, the exact command, whether it's a web server, and a **project icon**
   (choose an image or paste one). Use this when scanning didn't find the right script.
3. The main window is your control panel: each row shows the project name, its command, an icon,
   status, and — once running — its detected **URL** (clickable), **RAM**, and state. Drag rows
   to reorder them.
4. **Start / Stop / Restart** per service. If a service crashes or exits non-zero it turns
   **red (Failed)** and offers **Restart**.
5. **Console** (terminal icon) opens a per-service window with live stdout/stderr —
   **errors in red** — that you can copy or clear. Output is always captured in the background;
   the window is just hidden until you open it.

Your service list and order persist across launches. **Nothing auto-starts on launch. Quitting
the app stops every running service.**

## How services run

Each service launches as:

```
perl -e 'setsid(); exec @ARGV'  →  /bin/zsh -ilc "cd <folder> && <command>"
```

- `zsh -ilc` sources your `~/.zshrc`, so `nvm`, `rye`, and your full `PATH` are all available
  exactly as in your normal terminal.
- `setsid` puts each service in its **own process group**, so Thunderbox can tear down the
  entire tree (npm → node → webpack, or zsh → flask → workers) with a single signal — no
  orphaned servers.
- `PYTHONUNBUFFERED=1` is set so Python servers' startup banners/URLs appear immediately.

## Releases

The GitHub Actions workflow in [`.github/workflows/release.yml`](.github/workflows/release.yml)
builds the app on a macOS runner, packages `Thunderbox.dmg`, and publishes it two ways:

- **Versioned release** — push a tag like `v1.0` and it becomes the official GitHub Release:
  ```bash
  git tag v1.0 && git push origin v1.0
  ```
- **Rolling `latest`** — every push to `main` rebuilds the DMG and updates a `latest`
  **prerelease**, so there's always a current build to grab without cutting a version.

### Signing & notarization

`build-app.sh` signs with the first available identity: a **Developer ID Application** cert if
you have one, otherwise your **Apple Development** cert, otherwise ad-hoc. Only a Developer ID
build can be **notarized** for distribution outside the App Store; anything else will trip
Gatekeeper on other people's Macs (they'd right-click → Open to run it).

To produce a notarized DMG you need a *Developer ID Application* certificate (create one in
**Xcode → Settings → Accounts → Manage Certificates → + → Developer ID Application**). Then:

- **Locally:** store notarization creds once and build —
  ```bash
  xcrun notarytool store-credentials thunderbox --apple-id you@example.com --team-id L84DYWJ93D
  NOTARY_PROFILE=thunderbox ./make-dmg.sh
  ```
- **In CI:** add these repo **secrets** and the workflow signs + notarizes automatically
  (without them it still builds an ad-hoc DMG):

  | Secret | What it is |
  |---|---|
  | `MACOS_CERT_P12` | base64 of your Developer ID Application `.p12` export |
  | `MACOS_CERT_PASSWORD` | password for that `.p12` |
  | `NOTARY_APPLE_ID` | Apple ID email for notarization |
  | `NOTARY_PASSWORD` | app-specific password for that Apple ID |
  | `NOTARY_TEAM_ID` | team id (e.g. `L84DYWJ93D`) |

  Export the cert as base64 with:
  ```bash
  base64 -i DeveloperID.p12 | pbcopy
  ```

## Layout

```
Sources/Thunderbox/
  ThunderboxApp.swift        App entry, quit-time cleanup, About window
  Models/                    Service model, RunState, ScriptCandidate
  Core/ServiceStore.swift    Persistence, runner registry, icons, stop-all-on-quit
  Core/ServiceRunner.swift   Per-service process group, log capture, URL/RAM detection
  Core/ScriptScanner.swift   Folder scan (npm / shell / python), server heuristic
  Core/OutputParser.swift    ANSI stripping + URL/port detection
  Core/ImageIntake.swift     Choose/paste an image for a project icon
  Views/                     ContentView, ServiceRow, AddFolderSheet, ServiceEditor,
                             ConsoleView, AboutView, Theme
build-app.sh                 Compile + bundle Thunderbox.app
make-dmg.sh                  Build + package Thunderbox.dmg
assets/gen-icon.swift        Placeholder icon generator
initial-decision.md          Why everything is the way it is
```

## License

MIT — see [LICENSE](LICENSE).
