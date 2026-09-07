import type { Item, Movement } from '../types'

function daysAgo(n: number): string {
  return new Date(Date.now() - n * 86_400_000).toISOString()
}

interface SeedSpec {
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
  notes?: string
}

const SPECS: SeedSpec[] = [
  {
    name: 'USB-C Cable 2m',
    sku: 'CBL-USBC-2M',
    barcode: '8801234567890',
    category: 'Accessories',
    location: 'Main Warehouse',
    quantity: 148,
    reorderLevel: 40,
    unit: 'pcs',
    unitCost: 2.4,
    unitPrice: 7.99,
    supplier: 'Nexa Components',
  },
  {
    name: 'Wireless Mouse',
    sku: 'ACC-MSE-01',
    barcode: '8801234567906',
    category: 'Electronics',
    location: 'Store Front',
    quantity: 12,
    reorderLevel: 15,
    unit: 'pcs',
    unitCost: 9.5,
    unitPrice: 24.0,
    supplier: 'Nexa Components',
    notes: 'Slow mover — review pricing next quarter.',
  },
  {
    name: '27" Monitor',
    sku: 'ELC-MON-27',
    barcode: '8801234567913',
    category: 'Electronics',
    location: 'Main Warehouse',
    quantity: 6,
    reorderLevel: 4,
    unit: 'pcs',
    unitCost: 129.0,
    unitPrice: 219.0,
    supplier: 'Vertex Displays',
  },
  {
    name: 'Shipping Box (M)',
    sku: 'PKG-BOX-M',
    barcode: '8801234567920',
    category: 'Packaging',
    location: 'Main Warehouse',
    quantity: 0,
    reorderLevel: 100,
    unit: 'pack',
    unitCost: 0.42,
    unitPrice: 0,
    supplier: 'BoxHouse Ltd',
    notes: 'Reorder in packs of 250.',
  },
  {
    name: 'Bubble Wrap Roll',
    sku: 'PKG-BWR-50',
    barcode: '8801234567937',
    category: 'Packaging',
    location: 'Main Warehouse',
    quantity: 23,
    reorderLevel: 10,
    unit: 'roll',
    unitCost: 6.75,
    unitPrice: 0,
    supplier: 'BoxHouse Ltd',
  },
  {
    name: 'A4 Paper Ream',
    sku: 'OFF-PPR-A4',
    barcode: '8801234567944',
    category: 'Office',
    location: 'Store Front',
    quantity: 34,
    reorderLevel: 12,
    unit: 'pack',
    unitCost: 3.2,
    unitPrice: 5.5,
    supplier: 'Clarke Office Supply',
  },
  {
    name: 'Thermal Label 4x6',
    sku: 'OFF-LBL-46',
    barcode: '8801234567951',
    category: 'Office',
    location: 'Van 1',
    quantity: 8,
    reorderLevel: 20,
    unit: 'box',
    unitCost: 11.0,
    unitPrice: 0,
    supplier: 'Clarke Office Supply',
  },
  {
    name: 'Aluminium Sheet 1mm',
    sku: 'RAW-ALU-1MM',
    barcode: '8801234567968',
    category: 'Raw Materials',
    location: 'Main Warehouse',
    quantity: 62,
    reorderLevel: 25,
    unit: 'pcs',
    unitCost: 14.8,
    unitPrice: 0,
    supplier: 'Meridian Metals',
  },
  {
    name: 'Laptop Stand',
    sku: 'ACC-STD-01',
    barcode: '8801234567975',
    category: 'Accessories',
    location: 'Store Front',
    quantity: 19,
    reorderLevel: 8,
    unit: 'pcs',
    unitCost: 12.0,
    unitPrice: 29.99,
    supplier: 'Vertex Displays',
  },
  {
    name: 'Cleaning Solution 1L',
    sku: 'OFF-CLN-1L',
    barcode: '8801234567982',
    category: 'Office',
    location: 'Van 1',
    quantity: 3,
    reorderLevel: 6,
    unit: 'litre',
    unitCost: 4.1,
    unitPrice: 0,
    supplier: 'Clarke Office Supply',
  },
]

/** Stable ids so seeded movements can reference seeded items. */
function idFor(index: number): string {
  return `seed-${index + 1}`
}

export function seedItems(): Item[] {
  return SPECS.map((spec, i) => ({
    id: idFor(i),
    name: spec.name,
    sku: spec.sku,
    barcode: spec.barcode,
    category: spec.category,
    location: spec.location,
    quantity: spec.quantity,
    reorderLevel: spec.reorderLevel,
    unit: spec.unit,
    unitCost: spec.unitCost,
    unitPrice: spec.unitPrice,
    supplier: spec.supplier,
    notes: spec.notes ?? '',
    photo: null,
    createdAt: daysAgo(60 - i),
    updatedAt: daysAgo(i % 9),
  }))
}

interface MovementSpec {
  item: number
  kind: 'in' | 'out'
  delta: number
  after: number
  note: string
  days: number
}

const MOVEMENTS: MovementSpec[] = [
  { item: 3, kind: 'out', delta: -60, after: 0, note: 'Bulk pick for Q3 shipments', days: 1 },
  { item: 1, kind: 'out', delta: -3, after: 12, note: 'Counter sale', days: 1 },
  { item: 0, kind: 'in', delta: 100, after: 148, note: 'PO-2291 received', days: 2 },
  { item: 9, kind: 'out', delta: -2, after: 3, note: 'Van restock', days: 3 },
  { item: 6, kind: 'out', delta: -4, after: 8, note: 'Labels for outbound batch', days: 4 },
  { item: 2, kind: 'in', delta: 6, after: 6, note: 'PO-2288 received', days: 6 },
  { item: 8, kind: 'out', delta: -5, after: 19, note: 'Store transfer', days: 7 },
  { item: 5, kind: 'in', delta: 20, after: 34, note: 'PO-2284 received', days: 9 },
]

export function seedMovements(): Movement[] {
  return MOVEMENTS.map((m, i) => ({
    id: `seed-mv-${i + 1}`,
    itemId: idFor(m.item),
    itemName: SPECS[m.item].name,
    kind: m.kind,
    delta: m.delta,
    before: m.after - m.delta,
    after: m.after,
    note: m.note,
    at: daysAgo(m.days),
  }))
}
