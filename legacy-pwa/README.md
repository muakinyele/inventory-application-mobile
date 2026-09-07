# Stockpile — mobile inventory tracker

A mobile-first inventory app you install to your phone's home screen. It runs as
an installable PWA: everything lives in the browser on the device, with no
account, no server and no network round-trip. Works offline once installed.

## Running it

```bash
npm install
npm run dev        # http://localhost:5173
npm run build      # production bundle + service worker into dist/
npm run preview    # serve the built app
npm run lint
```

To try it on a phone on the same Wi-Fi, run `npm run dev` and open the
`Network:` URL it prints. Note that the camera scanner and "Add to home screen"
need a secure context, so on a phone use `npm run build && npm run preview` behind
HTTPS, or deploy `dist/` to any static host.

## What it does

**Dashboard** — stock value at cost, units on hand, a count of everything at or
below its reorder level, a ranked breakdown of stock value by category, and the
most recent movements.

**Items** — search by name, SKU, barcode or supplier; filter by stock status,
category and location; sort by name, quantity, value or recency. Every row has
one-tap `+`/`−` with an undo toast.

**Item detail** — stock in, stock out, or set a counted quantity after a
stocktake, each with an optional note. Full per-item movement history.

**Add / edit** — name, SKU, barcode, category, location, quantity, unit, reorder
level, unit cost, sale price, supplier, notes and a photo taken with the phone
camera (downscaled before it is stored).

**Barcode scanning** — uses the browser's native `BarcodeDetector` where it
exists (Chrome on Android). A scan jumps to the matching item, or starts a new
item pre-filled with the code. Everywhere else it falls back to typing the code.

**Activity** — the movement log grouped by day, filterable by in / out / edits,
exportable as CSV.

**Settings** — workspace name, currency, light/dark/system appearance, editable
category / location / unit lists, CSV import and export, a full JSON backup, a
sample catalogue, and an erase-everything action.

## How it is put together

```
src/
  types.ts               Item, Movement, Settings + the stock-status rule
  lib/
    storage.ts           localStorage read/write, corruption-tolerant
    seed.ts              the sample catalogue
    format.ts            currency, number, relative-time formatting
    csv.ts               RFC-4180 parse/serialise, import mapping, download
    image.ts             camera photo -> small JPEG data URL
  store/
    context.ts           the context object + useInventory hook
    inventory.tsx        the reducer and every mutation, in one provider
  components/            Screen, TabBar, Sheet, Scanner, Icon, ItemRow, ...
  screens/               Dashboard, Items, ItemDetail, ItemEditor, Activity, Settings
```

**State.** One reducer owns the whole database (items, movements, settings) and
writes it to `localStorage` after every change. Every mutation that touches a
quantity also appends a `Movement`, so the history is a by-product of the write
path rather than something screens have to remember to record. The log is capped
at 500 entries to stay inside the storage quota. `deleteItem` keeps the item's
movements — history in Activity survives the item.

**Stock never goes negative.** `adjustStock` clamps at zero; a bigger "out" than
you have empties the bin instead of going below it.

**Storage is treated as unreliable.** Reads tolerate missing, corrupt or
half-shaped payloads and fall back to a fresh database; writes swallow quota and
private-window errors so the in-memory session stays correct either way.

**Design tokens.** Light values are defined on bare `:root`; the dark set is
repeated under both `prefers-color-scheme` and `[data-theme]` so the in-app
Appearance setting wins in either direction. Colours come from a
contrast-validated palette — a single blue for the category bars (one series, so
one hue and no legend, with every bar directly labelled), and reserved
green/amber/red for stock status, always paired with an icon and a label so
colour never carries the meaning alone.

## Known limits

- Data is per-device and per-browser. There is no sync; the JSON backup in
  Settings is the way to move it.
- Photos are stored inline in `localStorage` as downscaled JPEGs. A few hundred
  items with photos will approach the ~5 MB quota; a larger catalogue wants
  IndexedDB instead.
- `BarcodeDetector` is Chrome/Android-only today. Elsewhere the scanner degrades
  to manual code entry.
