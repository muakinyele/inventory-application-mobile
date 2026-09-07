import type { Item, Movement } from '../types'

const ITEM_COLUMNS = [
  'name',
  'sku',
  'barcode',
  'category',
  'location',
  'quantity',
  'reorderLevel',
  'unit',
  'unitCost',
  'unitPrice',
  'supplier',
  'notes',
] as const

function escapeCell(value: unknown): string {
  const s = value == null ? '' : String(value)
  return /[",\n\r]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s
}

export function itemsToCsv(items: Item[]): string {
  const rows = items.map((item) => ITEM_COLUMNS.map((c) => escapeCell(item[c])).join(','))
  return [ITEM_COLUMNS.join(','), ...rows].join('\n')
}

export function movementsToCsv(movements: Movement[]): string {
  const header = ['date', 'item', 'type', 'change', 'before', 'after', 'note']
  const rows = movements.map((m) =>
    [m.at, m.itemName, m.kind, m.delta, m.before, m.after, m.note].map(escapeCell).join(','),
  )
  return [header.join(','), ...rows].join('\n')
}

/** Minimal RFC-4180 parser: handles quoted cells, escaped quotes and CRLF. */
export function parseCsv(text: string): string[][] {
  const rows: string[][] = []
  let row: string[] = []
  let cell = ''
  let quoted = false

  for (let i = 0; i < text.length; i++) {
    const ch = text[i]

    if (quoted) {
      if (ch === '"') {
        if (text[i + 1] === '"') {
          cell += '"'
          i++
        } else {
          quoted = false
        }
      } else {
        cell += ch
      }
      continue
    }

    if (ch === '"') {
      quoted = true
    } else if (ch === ',') {
      row.push(cell)
      cell = ''
    } else if (ch === '\n' || ch === '\r') {
      // Swallow the LF of a CRLF pair.
      if (ch === '\r' && text[i + 1] === '\n') i++
      row.push(cell)
      rows.push(row)
      row = []
      cell = ''
    } else {
      cell += ch
    }
  }

  if (cell !== '' || row.length > 0) {
    row.push(cell)
    rows.push(row)
  }
  return rows.filter((r) => r.some((c) => c.trim() !== ''))
}

export interface ImportResult {
  items: Omit<Item, 'id' | 'createdAt' | 'updatedAt' | 'photo'>[]
  errors: string[]
}

/**
 * Maps a CSV to draft items by header name. Unknown columns are ignored and
 * missing ones fall back to sensible defaults, so a hand-made sheet still works.
 */
export function csvToItems(text: string): ImportResult {
  const rows = parseCsv(text)
  const errors: string[] = []
  if (rows.length < 2) {
    return { items: [], errors: ['The file has no data rows.'] }
  }

  const header = rows[0].map((h) => h.trim().toLowerCase().replace(/[\s_-]/g, ''))
  const indexOf = (name: string) => header.indexOf(name.toLowerCase())
  const col = {
    name: indexOf('name'),
    sku: indexOf('sku'),
    barcode: indexOf('barcode'),
    category: indexOf('category'),
    location: indexOf('location'),
    quantity: indexOf('quantity'),
    reorderLevel: indexOf('reorderlevel'),
    unit: indexOf('unit'),
    unitCost: indexOf('unitcost'),
    unitPrice: indexOf('unitprice'),
    supplier: indexOf('supplier'),
    notes: indexOf('notes'),
  }

  if (col.name === -1) {
    return { items: [], errors: ['No "name" column found. That column is required.'] }
  }

  const cell = (row: string[], i: number) => (i === -1 ? '' : (row[i] ?? '').trim())
  const num = (row: string[], i: number) => {
    const raw = cell(row, i).replace(/[^0-9.-]/g, '')
    const n = Number.parseFloat(raw)
    return Number.isFinite(n) ? n : 0
  }

  const items: ImportResult['items'] = []
  rows.slice(1).forEach((row, i) => {
    const name = cell(row, col.name)
    if (!name) {
      errors.push(`Row ${i + 2}: skipped, no name.`)
      return
    }
    items.push({
      name,
      sku: cell(row, col.sku),
      barcode: cell(row, col.barcode),
      category: cell(row, col.category),
      location: cell(row, col.location),
      quantity: num(row, col.quantity),
      reorderLevel: num(row, col.reorderLevel),
      unit: cell(row, col.unit) || 'pcs',
      unitCost: num(row, col.unitCost),
      unitPrice: num(row, col.unitPrice),
      supplier: cell(row, col.supplier),
      notes: cell(row, col.notes),
    })
  })

  return { items, errors }
}

export function downloadFile(filename: string, contents: string, mime: string): void {
  const blob = new Blob([contents], { type: `${mime};charset=utf-8` })
  const url = URL.createObjectURL(blob)
  const a = document.createElement('a')
  a.href = url
  a.download = filename
  document.body.appendChild(a)
  a.click()
  a.remove()
  // Revoke on the next tick so Safari has time to start the download.
  setTimeout(() => URL.revokeObjectURL(url), 1000)
}
