export type ID = string

export interface Item {
  id: ID
  name: string
  sku: string
  barcode: string
  category: string
  location: string
  quantity: number
  reorderLevel: number
  unit: string
  unitCost: number
  unitPrice: number
  supplier: string
  notes: string
  /** Data URL of a photo captured or picked on the device. */
  photo: string | null
  createdAt: string
  updatedAt: string
}

export type MovementKind = 'in' | 'out' | 'adjust' | 'create' | 'edit' | 'delete'

export interface Movement {
  id: ID
  itemId: ID
  /** Denormalised so history survives deletion of the item. */
  itemName: string
  kind: MovementKind
  /** Signed change in units. Zero for edits. */
  delta: number
  before: number
  after: number
  note: string
  at: string
}

export interface Settings {
  currency: string
  companyName: string
  categories: string[]
  locations: string[]
  units: string[]
  theme: 'system' | 'light' | 'dark'
}

export interface Database {
  version: number
  items: Item[]
  movements: Movement[]
  settings: Settings
}

/** Derived stock state used for badges, filters and alerts. */
export type StockStatus = 'out' | 'low' | 'ok'

export function stockStatus(item: Item): StockStatus {
  if (item.quantity <= 0) return 'out'
  if (item.reorderLevel > 0 && item.quantity <= item.reorderLevel) return 'low'
  return 'ok'
}
