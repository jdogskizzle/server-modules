# Server Modules

An iPhone and iPad app (SwiftUI, iOS 17+) for the home-server apps. **Home** lists every
service with a live one-line status (what's recording, what's mining, the fund balance…);
tap one for its full screen. **Settings** holds each server's address and login.

| Service | Server | What you can do |
|---|---|---|
| DVR | [dvr-guard](https://github.com/jdogskizzle/dvr-guard) status page | What's recording, what's scheduled (cancel or stop), recent recordings with missing seconds and tuner overlaps, followed games, and what each tuned channel is serving |
| TV ad mute | [admute](https://github.com/jdogskizzle/admute) studio | Live: the open channel, whether it's muting, the logo match and ads muted; recent mute events; recordings (start a survey); **review** a recording like the studio's review mode (check each mute as right / wrong / partly, then look for missed ads), with the studio's HLS video (muted where the mute is, so you hear what a viewer heard) and exact frames to pick the start and end; labels (delete, side-by-side, notes); train the scene check; jobs with logs and Stop; the studio itself for tuning |
| Miner | [miner](https://github.com/jdogskizzle/miner) control panel | Live status (hashrate, $/day, GPU power and temperature, shares), pause/resume, power mode, pin a coin or go back to automatic, compare prices now, start or cancel a benchmark, coin ranking |
| Music | [musicflow](https://github.com/jdogskizzle/musicflow) web app | Artists with missing albums, search Soulseek for them, review and pick a source per album, *Download and finish*, re-tag (with or without a new cover), activity with progress, retry/cancel/dismiss and logs, import a folder from the downloads, wanted format, disk space, Jellyfin scan |
| Minecraft | [mcpanel](https://github.com/jdogskizzle/mcpanel) | Servers with players, version, CPU and memory; start, stop, restart, back up, restore a backup; change type, version, Java or memory; start-at-boot; add a server; task logs |
| Dashboards | [Grafana](https://grafana.com) | Your dashboards (starred first, by folder, searchable), each opened inside the app with a time-range picker, signed in with the same session |
| Ledger | [ledger](https://github.com/jdogskizzle/ledger) | Fund balance and payback progress, mining estimate, wishlist with progress and ETA (mark as bought), payouts / purchases / already spent with add, edit and delete, BTC price lookup, payback share, server specs |

Each service talks to its server's existing JSON API, the same one its web page uses, so
nothing needs to change on the servers. Grafana dashboards are drawn by Grafana itself, in
a web view that shares the app's sign-in.

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

Open **Settings** in the app and fill in each server's address. Hide a service you don't
use with its *Show on Home* switch.

| Server | Address | Notes |
|---|---|---|
| Miner | `http://<host>:8095` | `CONTROL_PORT` in the miner's `.env` |
| Music | `http://<host>:8000` or `https://<proxy>/musicflow` | either directly or through your proxy's `/musicflow/` path |
| Minecraft | `https://<proxy>/mcpanel` (or whatever path you use) | mcpanel has no published port; use your reverse proxy |
| Ledger | `http://<host>:8000` or `https://<proxy>/ledger` | `PORT` in the ledger's `.env` |
| DVR | `https://<proxy>/dvr` | dvr-guard has no published port; its status page behind your proxy |
| TV ad mute | `https://<proxy>/admute` | admute's studio (no published port) behind your proxy |
| Dashboards | `http://<host>:3000` or `https://<proxy>/grafana` | Grafana; sign in with a Grafana user (a viewer is enough) |

Each server has its own sign-in page ([formlogin](https://github.com/jdogskizzle/formlogin)).
Set each one's **Login** to **Sign-in page** and enter the same username and password as
in the browser (`<APP>_USERNAME` and the password behind `<APP>_PASSWORD_HASH`). The app
posts them to the server's `login` page, keeps the 30-day session cookie in the Keychain,
and signs in again by itself when the session runs out. For Grafana, **Sign-in page** is
Grafana's own login (users that only sign in through single sign-on can't be used). After a wrong password it stops
trying until you change the login, because formlogin locks an address out for 15 minutes
after 5 failures. *Test connection* signs in with what's on screen without saving anything.

The other login types are for a reverse proxy that asks for a login before the app
(HTTP Basic, a bearer token, or a custom header such as a Cloudflare Access service
token). *None* is for a server whose sign-in is turned off (`<APP>_AUTH=off`).
Passwords, tokens and session cookies stay in the iOS Keychain on the device.

`Support/Info.plist` allows plain `http://` to any host, since the servers usually run
without TLS at home. Remove `NSAllowsArbitraryLoads` once everything is behind https.

## Layout

```
ServerModules/
  App/            app entry, Home (service list and status lines), Settings
  Core/           API client, JSON helpers, server settings, Keychain
  Shared/         formatting and small reusable views (stat tiles, banners, polling)
  Modules/
    Miner/        models for /api/status, the miner screen
    MusicFlow/    artists, album search and picking, activity, import
    MCPanel/      servers, server detail, version change, add server, tasks
    Ledger/       dashboard, tables, forms, server specs
    Grafana/      dashboard list and the in-app dashboard viewer
    DVR/          dvr-guard: recording now, schedule, recent, tuners
    Admute/       admute studio: live, events, recordings, jobs
Support/Info.plist
```

Each module has a store (an `@Observable` class holding the server's data and doing its
requests) and SwiftUI views on top. Screens refresh on a timer while they're on screen
and the app is in the foreground, and on pull-to-refresh.

## License

MIT
