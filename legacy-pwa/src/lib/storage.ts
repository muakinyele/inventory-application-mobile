import type { Database, Settings } from '../types'
import { seedItems, seedMovements } from './seed'

const KEY = 'inventory-tracker/db/v1'

export const DEFAULT_SETTINGS: Settings = {
  currency: 'USD',
  companyName: 'My Inventory',
  categories: ['Electronics', 'Accessories', 'Packaging', 'Office', 'Raw Materials'],
  locations: ['Main Warehouse', 'Store Front', 'Van 1'],
  units: ['pcs', 'box', 'kg', 'litre', 'pack', 'roll'],
  theme: 'system',
}

function freshDatabase(): Database {
  return {
    version: 1,
    items: seedItems(),
    movements: seedMovements(),
    settings: DEFAULT_SETTINGS,
  }
}

/**
 * Reads the database, tolerating a missing, corrupt or partially-shaped
 * payload — a bad value in localStorage should never blank the app.
 */
export function loadDatabase(): Database {
  let raw: string | null = null
  try {
    raw = localStorage.getItem(KEY)
  } catch {
    return freshDatabase()
  }
  if (!raw) return freshDatabase()

  try {
    const parsed = JSON.parse(raw) as Partial<Database>
    return {
      version: 1,
      items: Array.isArray(parsed.items) ? parsed.items : [],
      movements: Array.isArray(parsed.movements) ? parsed.movements : [],
      settings: { ...DEFAULT_SETTINGS, ...(parsed.settings ?? {}) },
    }
  } catch {
    return freshDatabase()
  }
}

export function saveDatabase(db: Database): void {
  try {
    localStorage.setItem(KEY, JSON.stringify(db))
  } catch {
    // Quota exceeded or storage blocked (private window). The in-memory
    // state stays correct for this session; nothing else we can do here.
  }
}

export function resetDatabase(): Database {
  const db = freshDatabase()
  saveDatabase(db)
  return db
}

export function emptyDatabase(): Database {
  const db: Database = { version: 1, items: [], movements: [], settings: DEFAULT_SETTINGS }
  saveDatabase(db)
  return db
}
