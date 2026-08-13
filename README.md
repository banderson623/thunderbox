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
4. **Start / Stop** per service — one button that reflects what the service is doing. If a
   service crashes or exits non-zero it turns **red (Failed)**; press Start to try again.
5. **Console** (terminal icon) opens a per-service window with live stdout/stderr —
   **errors in red** — that you can copy or clear. Output is always captured in the background;
   the window is just hidden until you open it.

Your service list and order persist across launches. **Nothing auto-starts on launch. Quitting
the app stops every running service.**

## Ports

Two services that want the same port is the most boring way for a dev environment to break,
so Thunderbox treats it as a first-class case rather than an exit code.

- **Before launching**, if the service's port is already bound, Thunderbox doesn't start it.
  The row turns **amber (Port in use)** and names the process holding it — including *which
  other Thunderbox service* it is, when the pid belongs to one of ours. From there you can
  **stop the holder and start**, **move to a free port**, or just **open what's already
  answering**, which is often what you wanted.
- **Two services declaring the same port** are flagged in the header before either one runs.
- **When a launch fails anyway** — a port Thunderbox never parsed out of the command — it
  reads the failure. `EADDRINUSE`, `Address already in use`, and plain-English variants are
  all recognised.

### Overriding the port

There's no universal environment variable. `PORT` is the de-facto standard and much of the
Node/Ruby world honours it, but plenty of projects pick their own name to avoid colliding with
an exported `PORT` — a fair trade that costs discoverability. So Thunderbox looks at the
project instead of guessing:

1. **The error message.** Tools that print the fix (`… start this one on another port with
   BOOK_READER_PORT=4322`) hand over the whole remedy, and it becomes a one-click button.
2. **`.env` / `.env.example`** in the project folder, which name the variables outright.
3. **The source** — `process.env.X_PORT`, `os.environ["X_PORT"]`, `os.getenv(…)` — along with
   the fallback literal next to them (`?? 4321`), which is the project's real default.
4. **Framework defaults** for the tools that ignore `PORT`: `STREAMLIT_SERVER_PORT`,
   `UVICORN_PORT`, `FLASK_RUN_PORT`, `JUPYTER_PORT`, `NUXT_PORT`.

**Edit…** shows what was found in a picker, with the file it came from. Pick one, give it a
value, and it's set for that service on every launch — over the top of your shell environment,
so an exported `PORT` in `~/.zshrc` can't beat it. Tick **Move to the next free port if this
one's taken** and conflicts resolve silently instead of stopping you.

The **Environment** section of the same sheet sets any other variables the service needs.

## Reaching servers from your phone (LAN)

**The dashboard.** Thunderbox serves its own status page on the network at
`http://<your-mac>.local:4141` (first free port of 4141–4143, 4151). Click the **Phone**
button in the header for a QR code — scan it once, **Add to Home Screen**, and it installs
as a real home-screen web app: the Thunderbox app icon (served straight from the running
app, no extra assets), its own name, full-screen with no Safari chrome. From then on one
tap from anywhere in the house shows every service, its state and RAM, with links to the
ones that are reachable. The page is read-only and refreshes itself; starting and stopping
stays on the Mac.

**Per-server links.** When a server is running, Thunderbox checks how it's *actually* bound —
a banner saying `http://localhost:3000` doesn't tell you whether the socket is on `127.0.0.1`
or `0.0.0.0`, so it asks `lsof` instead of trusting the text:

- **Reachable from the network** → the row grows a second link,
  `http://<your-mac>.local:<port>` — your Mac's Bonjour name, which every Apple device on
  the network resolves and which stays stable across reboots and DHCP changes. Next to it,
  a **QR button** shows a code you can scan with your phone's camera to open the server
  directly. Thunderbox also **broadcasts the service over Bonjour** (`_http._tcp`) under its
  service name, so network-browser apps can discover it.
- **Bound to `127.0.0.1`** → the row says *"localhost only — phones and other devices can't
  reach it"*, and offers **Expose on LAN**.

### Expose on LAN

You can restart the server listening on `0.0.0.0` — most take `--host 0.0.0.0` or
`HOST=0.0.0.0` — but that's a different flag or variable for every framework (`vite --host`,
`next -H`, `uvicorn --host`, `STREAMLIT_SERVER_ADDRESS=`), and it means a restart.

**Expose on LAN** — the button on the row, the context menu, or the switch in **Edit…** —
skips all of that. Thunderbox runs a **TCP relay**: it listens on every interface and forwards
to `localhost:<port>`. The server keeps binding loopback and needs no changes at all.

- The relay listens on the service's port **+ 10000** (4321 → 14321). It can't reuse the
  service's own port — the server already holds that one.
- It works on a process that's *already running*, and switches off again without a restart.
- The relayed address is advertised over Bonjour and gets the same `.local` link and QR code
  as a natively-reachable server.
- It relays at the TCP layer, so `Host` headers, WebSocket upgrades and SSE pass through intact.
- The relay stops when the service stops, and when you switch it off.

Worth knowing before you flip it on:

- **There's no authentication in front of it.** Anyone on the network — coffee shop, hotel,
  conference wifi — can reach the service. It's off by default and per-service on purpose.
- macOS asks **once** whether Thunderbox may accept incoming connections. Because the relay
  belongs to Thunderbox rather than to `node`, you answer that prompt one time instead of for
  every framework's binary. (Without the relay, check **System Settings → Network → Firewall**
  and allow incoming connections for the server's own runtime when macOS asks.)
- `http://192.168.x.x` and `http://<your-mac>.local` are **not secure contexts** the way
  `http://localhost` is, so service workers, camera/mic and geolocation behave differently on
  a phone than they do on your Mac. That's the browser's rule, not Thunderbox's.
- Dev servers with host checking (Vite, webpack-dev-server) may reject a non-localhost `Host`
  header. Add the address to `server.allowedHosts` / `allowedHosts` in that project's config.

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
- Per-service variables from **Edit…** are applied last, so they win over anything your
  `~/.zshrc` exported.

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
Tests/ThunderboxTests/       OutputParser + ScriptScanner tests (swift test)
initial-decision.md          Why everything is the way it is
```

## License

MIT — see [LICENSE](LICENSE).
