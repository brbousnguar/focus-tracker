# Focus Tracker — macOS app

A native window focus timer with a companion menu-bar countdown. The app opens on
a Clock-style Timer tab, remains available in the Dock and Command-Tab, and also
provides Dashboard and Sessions tabs. Sessions can use the configured remote
database or a fully local editable JSON store. Remote mode retains the offline
log and retry outbox.

The production icon source is `Resources/AppIcon.png`. Its complete macOS icon
set lives in `Resources/Assets.xcassets/AppIcon.appiconset`; Apple's `actool`
compiles that catalog into the packaged `Assets.car` and `AppIcon.icns`, referenced
by the bundle's `CFBundleIconName` and `CFBundleIconFile` settings. The source keeps
the white rounded tile opaque and makes only its exterior corners transparent for
the native Dock and Command-Tab silhouette.

## Build & run
```sh
cd macos
swift build -c release
.build/release/FocusTracker      # or: swift run
```
A FocusTracker window opens and a compact transparent white version of the app's
segmented-ring icon appears in the menu bar. Running the bare `.build` binary
shows a generic executable icon in the Dock; for the real app icon during local
use, build and open a lightweight bundle instead:

```sh
./scripts/dev-app.sh                       # from the repo root
open macos/dist/FocusTracker.app
``` Its foreground stays white so translucent
menu bars cannot incorrectly tint it black, and it has no crosshair lines.

## Test

From the repository root:

```sh
swift test --package-path macos --parallel
```

The XCTest suite covers configuration decoding and defaults, structured and
legacy session-description formats, duration and payload calculation, and timer
state transitions. The real packaged executable also provides
`--smoke-test` for headless CI launch verification; it validates bundle metadata
and initializes the timer model without opening or modifying user data.

`.github/workflows/ci-macos.yml` is intentionally macOS-specific. On pushes to
`main` and macOS-related pull requests it tests, creates the universal app and
DMG, runs that packaged smoke check, and verifies architectures, code signing,
the disk image, and its checksum. Other native platforms should use separate
workflow files so their SDKs and release rules remain independent.

## Install as a macOS app

Users install the public release through the standard macOS disk-image flow:

1. Download `FocusTracker.dmg` from the repository's latest release.
2. Open the disk image.
3. Drag FocusTracker onto the Applications alias.
4. Try to open FocusTracker from Applications.
5. For an unsigned community build, macOS blocks the first attempt. Open
   **System Settings → Privacy & Security**, scroll to Security, select
   **Open Anyway** for FocusTracker, and confirm. This is required only once.

The packaged app runs independently of Terminal and remains in the menu bar
after its launching shell closes. To create a universal development DMG:

```sh
cd ..
VERSION=1.0.0 BUILD_NUMBER=1 ./scripts/package-macos.sh
```

This builds Apple silicon and Intel executables, combines them into one app,
compiles the production icon, signs the bundle, and creates
`macos/dist/FocusTracker.dmg` with an Applications alias. Without
`MACOS_SIGNING_IDENTITY`, the script uses an ad-hoc development signature; do
not describe that package as Apple-verified.

## Publish a free community release

No paid Apple membership is required. Push a semantic-version tag:

```sh
git tag v1.0.0
git push origin v1.0.0
```

If no Apple credentials are configured, `.github/workflows/release-macos.yml`
publishes the universal ad-hoc signed DMG and its SHA-256 checksum as an unsigned
community release. The release notes and installation instructions clearly
explain the one-time Gatekeeper approval.

## Optional: publish a trusted release

Distribution outside the Mac App Store requires an Apple Developer Program
membership, a **Developer ID Application** certificate, and Apple notarization.

1. [Enroll in the Apple Developer Program](https://developer.apple.com/programs/enroll/)
   and wait for Apple to approve the membership.
2. On the Mac, open **Keychain Access → Certificate Assistant → Request a
   Certificate from a Certificate Authority**. Enter the Apple Account email,
   choose **Saved to disk**, and save the `.certSigningRequest` file.
3. Open [Certificates, Identifiers & Profiles](https://developer.apple.com/account/resources/certificates/list),
   add a certificate, select **Developer ID Application**, and upload the CSR.
4. Download the `.cer` from Apple and double-click it. Under **Keychain Access →
   login → My Certificates**, verify that the certificate expands to show its
   private key.
5. Export that certificate and private key as a password-protected `.p12`.

Then add these GitHub repository secrets under **Settings → Secrets and
variables → Actions**:

- `MACOS_CERTIFICATE_BASE64` — base64-encoded contents of the exported `.p12`
- `MACOS_CERTIFICATE_PASSWORD` — password used when exporting the `.p12`
- `APPLE_ID` — Apple Account used for notarization
- `APPLE_TEAM_ID` — ten-character Apple Developer team identifier
- `APPLE_APP_SPECIFIC_PASSWORD` — app-specific password for the Apple Account

Keep the certificate, its password, and notarization credentials out of Git.
After configuring all five secrets, publish the next semantic-version tag:

```sh
git tag v1.0.0
git push origin v1.0.0
```

The same workflow detects the complete credentials, signs the universal app with
the Developer ID certificate, notarizes and staples the DMG, verifies it with
Gatekeeper, and creates a trusted GitHub Release. The README download button
always points to the `FocusTracker.dmg` asset from the latest release.

## First-run config
On first launch it creates:
`~/Library/Application Support/FocusTracker/config.json`

```json
{
  "storageBackend": "firebase",
  "supabaseUrl": "https://xxxx.supabase.co/rest/v1/sessions",
  "apiKey": "<supabase anon public key>",
  "device": "mac",
  "sessionMinutes": 30
}
```
The recommended interface is the gear button in the app window. Choose
**Firebase** to keep the existing remote URL and API key; both current values are
prefilled. The URL is forced left-to-right. The key is masked unless the eye is
being pressed and held, and releasing it hides the key immediately without
resizing the fixed-width input. Choose
**Local storage** to use
`~/Library/Application Support/FocusTracker/local-sessions.json` without remote
credentials. Existing configs without `storageBackend` default to `firebase`;
new installations default to `local`. Switching does not copy sessions between
backends. The app removes the old legacy `categories` key when it normalizes the
configuration.

## Daily use
The default **Timer** tab shows a circular countdown set to 30 minutes from
`sessionMinutes`. Choose a duration, database category, one or more category-linked
session names, and an optional note. Use **Start**, **Pause/Resume**, **Restart**,
or **Cancel**. While it runs, the same countdown and controls are available from
the menu-bar focus control. A completed window timer saves the chosen details automatically.

You can also click the menu-bar focus icon → click a database category to start immediately; the
menu bar shows the countdown and asks for session details when it finishes.
The menu overlay uses native macOS symbols for Timer, Dashboard, Sessions, session
controls, category actions, and Settings. **Settings…** replaces the legacy
**Open config file** and **Reload config** developer entries and opens the same
gear settings sheet used by the main window.
Use **Refresh categories** after a change made outside the app. When the database
is empty, choose **Add category with session…** to open Sessions and create the
first dashboard row.
While the timer runs, use **Add/Edit sessions & note…** to choose past session
names and write a note during the session; whatever you enter is filed
automatically when the timer ends. At 0:00 a 10-second alarm chime plays. If no
details were entered during the session, the past-session-name checkboxes and
optional Note field appear so you can fill them in before filing (choosing one or
many, or adding new ones). **Stop & Save now** ends and saves early.
**Cancel (discard)** throws the session away.

## Dashboard
Menu-bar focus icon → **Dashboard** opens the native SwiftUI monthly overview (Swift Charts),
with previous/next month navigation, monthly focus/session/day/category tiles,
category totals, and a **Day / Month** chart-granularity control. Day displays a
category-stacked bar for each date in the selected month; Month displays the 12
months ending with the selected month. Menu-bar focus icon → **Sessions** opens the
same window directly on its per-day list, where an exact calendar date filters
the sessions. The in-window segmented control switches between both views even
when the window is already open; it also includes the default **Timer** tab. The
gear button opens storage, timer-default, and device settings.
FocusTracker remains available in Command-Tab and the Dock after closing its
window, and clicking the Dock icon restores it. Use **Add session**, **Edit**, or the trash button
to create, update, or remove entries. Start/end time, category, session names,
note, and device are editable; changes update the selected local or remote
backend and dashboard values immediately.
The category control is a picker rather than free text: it displays the three
most-used categories first, with every other category found in Supabase available
from **More categories**. The **Sessions** control suggests the three most-used
session names for the selected category, permits multiple choices, and loads the
rest from **More sessions**. **Note** remains free text for occurrence-specific
detail. Existing databases without the `session_names` column are detected and
supported automatically. **New category** and **New session** reveal compact
quick-add fields, place keyboard focus in the new field immediately, and select
the new values for saving with the row. Session names support Command-V through
the standard macOS Edit menu and include a dedicated **Paste** button.
Category colors are consistent across session badges, picker controls, and the
overview chart. AI uses yellow; other categories receive distinct palette colors.
The overview's daily and monthly bars are stacked by category and include a
matching color legend.
When adding a row, **Finish** and **Duration** replace the editable Start/End pair.
Duration defaults to `sessionMinutes` (30 minutes in the default config), and the
read-only Start preview recalculates immediately. Editing an existing row retains
explicit Start and End controls for corrections.
**Refresh** re-pulls. Light/dark automatic.
(Launch with `--open-dashboard` to open it straight away.)

## Data files (in the config folder)
- `config.json`   — settings
- `sessions.jsonl` — permanent local log of every saved session
- `outbox.json`   — sessions not yet confirmed by the server (auto-retried)

## Run at login (optional)
System Settings → General → Login Items → add `FocusTracker.app` from your
Applications folder.

## Notes
- Built as a Swift Package executable and packaged in a lightweight `.app`
  bundle; no `.xcodeproj` to maintain.
- The app uses regular macOS window activation so it stays reachable from the
  Dock and Command-Tab; the status item remains available for quick timer control.
