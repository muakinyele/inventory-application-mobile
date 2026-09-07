# Stockpile — inventory tracker

A Flutter inventory app that runs from one codebase on **Android, iOS and the
web**. Everything is stored on the device — no account, no server, and it keeps
working offline.

## Running it

```bash
flutter pub get

flutter run -d chrome          # web
flutter run -d <android-id>    # phone or emulator; see `flutter devices`
flutter test                   # 55 unit + widget tests
flutter test --platform chrome test/web_safety_test.dart   # browser-only guards
flutter analyze
dart format lib test
```

Release builds:

```bash
flutter build web --release    # -> build/web, deploy to any static host
flutter build apk --release    # -> build/app/outputs/flutter-apk
flutter build ipa              # requires Xcode
```

> **On this machine**, `xcode-select -p` points at a directory that no longer
> exists, which breaks the macOS toolchain that even `flutter test` reaches for.
> Either prefix commands with
> `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`, or fix it once
> with `sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer`.

## The interface

The layout follows an admin-console pattern: a dark navigation sidebar, a pale
canvas, and white cards with hairline borders.

**Dashboard** — four headline stats (items, low stock, out of stock, total
value), recent transactions, and what needs attention.

**Items** — a product-card grid: photo or initials banner, name, mono SKU,
colour-coded category tag, and a Price / Stock / Value row with one-tap `+`/`−`.
Search by name, SKU, barcode or supplier; filter by stock status, category and
location; sort four ways.

**Item detail** — stock in, stock out, or set a counted quantity after a
stocktake, each with an optional note. Full per-item movement history.

**Add / edit** — every field, plus a photo from the camera or library
(downscaled before it is stored).

**Activity** — the movement log grouped by day, filterable by in / out / edits,
exportable as CSV.

**Categories** — every category with its live item count and a colour swatch.
Renaming one rewrites the items that used it; deleting one leaves those items
uncategorised with their stock untouched.

**Reports** — stock value by category as a bar chart, share of value and units
held as donuts, stock in/out over the last 14 days as a diverging column chart,
and top items by value. Charts are `fl_chart`, with hover tooltips throughout.

**Alerts** — everything at or below its reorder level, with an all-clear state.

**Settings** — workspace name, currency, appearance, editable list management,
CSV import/export, JSON backup, sample catalogue, erase-everything.

**Barcode scanning** is available from Items and from the editor, using
`mobile_scanner` on Android, iOS and web, with manual entry always alongside it.

## How it is put together

```
lib/
  main.dart                    opens the repository, then runs the app
  app.dart                     router + theme wiring
  core/
    palette.dart               colour tokens as a ThemeExtension
    theme.dart                 light and dark ThemeData, plus the type ramp
    design.dart                spacing, radius and breakpoint scales
    category_colors.dart       the category swatch set
    formatters.dart            currency, number, relative-time formatting
  models/                      Item (+ stock-status rule), Movement, AppSettings
  data/
    database.dart              drift/SQLite schema (+ generated .g.dart)
    inventory_repository.dart  every read and write, in SQL
    seed_data.dart             the sample catalogue
    csv_codec.dart             RFC-4180 parse/serialise + import mapping
    export_service.dart        share sheet on mobile, download on web
    photo_service.dart         camera/library photo -> small encoded image
  state/
    inventory_controller.dart  the reducer: every mutation lives here
  ui/
    app_shell.dart             sidebar when wide, tabs + overflow on a phone
    dashboard_page.dart  items_page.dart  item_detail_page.dart
    item_editor_page.dart  activity_page.dart  categories_page.dart
    reports_page.dart  alerts_page.dart  settings_page.dart  scanner_page.dart
    widgets/                   AppSidebar, PageHeader, StatCard, ProductCard,
                               FilterChips, SectionCard, MovementTile, charts
test/                          csv, formatter, controller and widget tests
```

**A real database underneath.** Drift/SQLite with five tables — `items`,
`movements`, `categories`, `lookups`, `preferences`. Native `sqlite3` on Android,
iOS and macOS; the same engine compiled to WebAssembly over IndexedDB in the
browser (`web/sqlite3.wasm`, `web/drift_worker.js`). Timestamps are stored as
ISO-8601 text rather than drift's default Unix *seconds*, because several
movements are routinely recorded inside one second and at second precision they
tie — which makes ledger order non-deterministic and breaks trimming by age.

**One owner for state.** `InventoryController` (a `ChangeNotifier` behind
`provider`) holds the in-memory view and is the only thing that mutates it.
Reads stay synchronous so widgets build without a future; every write is applied
in memory, published, then persisted. Any mutation that touches a quantity also
appends a `Movement`, so the ledger is a by-product of the write path rather
than something each screen has to remember to record. Category edits
deliberately append nothing — the ledger records stock, not metadata. It is
capped at 500 rows, trimmed by rank in SQL, and `deleteItem` keeps the item's
movements.

**Stock never goes negative.** `adjustStock` clamps at zero; a bigger "out" than
you hold empties the bin instead of going below it.

**Writes cannot break the interaction.** Persistence is fire-and-forget: the UI
already reflects the change, so a failed write is captured on the controller
rather than thrown at the user mid-gesture. Bulk operations — reset, restore,
sample data — run in one transaction, so they can never leave the database
half-written. Category colour is an additive override map; a category with no
explicit choice takes its swatch from its position in the list, so the first few
categories land on visibly different hues.

**One navigation model, two presentations.** Below 900px the shell shows a tab
bar for the four most-used destinations plus a "More" sheet holding the rest;
at or above it, the same list becomes the fixed sidebar. The overflow sheet is
the tail of that one list, not a second navigation system. Both presentations
are asserted in `test/app_widget_test.dart`.

**Type.** Inter, bundled rather than fetched at runtime so the app still renders
correctly offline. It ships two optical sizes and the app uses both: the *Text*
cut for everything at UI sizes, and the *Display* cut — tighter apertures and
spacing — for headings and figures above roughly 20px. Four text weights and
three display weights are bundled, which is exactly what the UI uses.

**Charts follow the data's job.** A single measure across categories is a
magnitude comparison, so the bar chart uses one hue and lets the axis labels
carry identity. Share-of-total gets a donut, capped at six slices with the tail
folded into "Other", because a donut cannot be read for close values — which is
why the bar and the donut sit side by side rather than one replacing the other.
Stock in and out is movement around a baseline, so it is a diverging column
chart: receipts above zero, issues below. Every slice is legended by name and
value, so colour is never the only channel.

**Colour is checked, not eyeballed.** Tokens live in `palette.dart` and each was
measured against the surface it renders on. The reference's `#12A5A0` active
pill only reached 3.04:1 for its white label, so it is stepped to `#0B7C79`
(5.03:1). Amber is sub-3:1 on white, so warning *text* uses a darker step while
the amber stays on the icon and the wash. Status always ships colour **plus** an
icon and a label.

## Deploying the web build

`build/web` is a single-page app using **hash URLs** (`/#/items`,
`/#/items/<id>`), so it deep-links correctly on any static host with no rewrite
rules. A plain `python3 -m http.server` will serve it as-is; requesting
`/items` without the `#` returns 404 by design.

To switch to clean paths, call `usePathUrlStrategy()` in `main.dart` and
configure your host to serve `index.html` for unknown paths.

## Platform notes

- **Android** — `CAMERA` is declared and the camera is marked optional, so the
  app still installs on devices without one. `mobile_scanner` needs minSdk 23.
- **iOS** — `NSCameraUsageDescription` and `NSPhotoLibraryUsageDescription` are
  set. Building for iOS needs a working Xcode (see the note above).
- **Web** — installable (manifest + icons). The camera scanner and the install
  prompt both need a secure context, so serve over HTTPS or localhost; over
  plain HTTP on a LAN address the scanner falls back to manual entry.

## Known limits

- Data is per-device and per-browser. There is no sync; the JSON backup in
  Settings is how you move it.
- The bundled fonts add about 2.8 MB to the web build. Subsetting them to the
  glyphs actually used would cut that substantially if download size matters.
- Photos are stored inline in the database. A few hundred items with photos
  will approach the web `localStorage` quota (~5 MB); a larger photo-heavy
  catalogue wants a real database and file storage instead.
- `legacy-pwa/` holds the earlier React/Vite version of this app, kept for
  reference. It is not part of the Flutter build and can be deleted.
