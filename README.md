# Server Modules

An iPhone and iPad app (SwiftUI, iOS 17+) for the home-server apps:

| Tab | Server | What you can do |
|---|---|---|
| Miner | [miner](https://github.com/jdogskizzle/miner) control panel | Live status (hashrate, $/day, GPU power and temperature, shares), pause/resume, power mode, pin a coin or go back to automatic, compare prices now, start or cancel a benchmark, coin ranking |
| Music | [musicflow](https://github.com/jdogskizzle/musicflow) web app | Artists with missing albums, search Soulseek for them, review and pick a source per album, *Download and finish*, re-tag (with or without a new cover), activity with progress, retry/cancel/dismiss and logs, import a folder from the downloads, wanted format, disk space, Jellyfin scan |
| Minecraft | [mcpanel](https://github.com/jdogskizzle/mcpanel) | Servers with players, version, CPU and memory; start, stop, restart, back up, restore a backup; change type, version, Java or memory; start-at-boot; add a server; task logs |
| Ledger | [ledger](https://github.com/jdogskizzle/ledger) | Fund balance and payback progress, mining estimate, wishlist with progress and ETA (mark as bought), payouts / purchases / already spent with add, edit and delete, BTC price lookup, payback share, server specs |

Each tab talks to its server's existing JSON API, the same one its web page uses, so
nothing needs to change on the servers.

## Build

1. Open `ServerModules.xcodeproj` in Xcode 16 or later.
2. Select the **ServerModules** target, then *Signing & Capabilities*, and pick your team
   (a free Apple ID works for installing on your own phone). Change the bundle ID if Xcode
   says it's taken.
3. Run on your iPhone or a simulator.

Source files live in folders that Xcode picks up by itself, so a new `.swift` file in
`ServerModules/` is part of the app without touching the project. If the project file
ever gives trouble, `xcodegen` regenerates it from `project.yml`.

## TestFlight

Every push to `main` builds the app and uploads it to TestFlight
(`.github/workflows/testflight.yml`); *Actions → TestFlight → Run workflow* does it by
hand. Each upload's build number is the workflow's run number. Other branches only get
the simulator build check (`build.yml`).

One-time setup:

1. **Apple Developer Program** (paid) at developer.apple.com.
2. **Bundle ID**: developer.apple.com → Certificates, IDs & Profiles → Identifiers → +,
   App IDs, App, explicit ID `com.jdogskizzle.ServerModule`.
3. **App record**: App Store Connect → Apps → + New App, iOS, that bundle ID, any name
   and SKU.
4. **API key**: App Store Connect → Users and Access → Integrations → App Store Connect
   API → Team Keys → +, access **Admin**. Note the key ID and the issuer ID, and download
   the `.p8` file (it can only be downloaded once).
5. **Repository secrets** (GitHub → Settings → Secrets and variables → Actions):
   `APPLE_TEAM_ID` (developer.apple.com → Account → Membership details), `ASC_KEY_ID`,
   `ASC_ISSUER_ID`, and `ASC_KEY_P8` (the whole text of the `.p8` file, including the
   BEGIN/END lines).
6. **Testers**: App Store Connect → the app → TestFlight → Internal Testing → add a group
   with yourself in it, and turn on automatic distribution so new builds reach you.

## Set up

Open **Settings** in the app and fill in each server's address. Hide a tab you don't
use with its *Show tab* switch.

| Server | Address | Notes |
|---|---|---|
| Miner | `http://<host>:8095` | `CONTROL_PORT` in the miner's `.env` |
| Music | `http://<host>:8000` or `https://<proxy>/musicflow` | either directly or through your proxy's `/musicflow/` path |
| Minecraft | `https://<proxy>/mcpanel` (or whatever path you use) | mcpanel has no published port; use your reverse proxy |
| Ledger | `http://<host>:8000` or `https://<proxy>/ledger` | `PORT` in the ledger's `.env` |

None of these apps have a login of their own. Reach them on your home network or over a
VPN such as Tailscale, or through a reverse proxy that asks for a login. For that last
case, each server has a **Login** setting: username and password (HTTP Basic), a bearer
token, or a custom header (e.g. a Cloudflare Access service token). Passwords and tokens
are kept in the iOS Keychain on the device. *Test connection* checks the address and login.

`Support/Info.plist` allows plain `http://` to any host, since the servers usually run
without TLS at home. Remove `NSAllowsArbitraryLoads` once everything is behind https.

## Layout

```
ServerModules/
  App/            app entry, tabs, Settings screens
  Core/           API client, JSON helpers, server settings, Keychain
  Shared/         formatting and small reusable views (stat tiles, banners, polling)
  Modules/
    Miner/        models for /api/status, the miner screen
    MusicFlow/    artists, album search and picking, activity, import
    MCPanel/      servers, server detail, version change, add server, tasks
    Ledger/       dashboard, tables, forms, server specs
Support/Info.plist
```

Each module has a store (an `@Observable` class holding the server's data and doing its
requests) and SwiftUI views on top. Screens refresh on a timer while they're on screen
and the app is in the foreground, and on pull-to-refresh.

## License

MIT
