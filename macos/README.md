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
segmented-ring icon appears in the menu bar. Its foreground stays white so translucent
menu bars cannot incorrectly tint it black, and it has no crosshair lines.

## Install as a macOS app

The packaged `FocusTracker.app` runs independently of Terminal and remains in
the menu bar after its launching shell closes:

```sh
cp -R dist/FocusTracker.app ~/Applications/
open ~/Applications/FocusTracker.app
```

Rebuild and copy `.build/release/FocusTracker` into
`dist/FocusTracker.app/Contents/MacOS/FocusTracker` before reinstalling after
code changes.

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
At 0:00
(or **Stop & Save now**) it beeps, shows past session names for that category as
checkboxes (choose one or many, or add new ones), and provides a separate optional
Note field before filing the session.
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
