import { createContext, useContext } from 'react'
import type { ID, Item, Movement, Settings } from '../types'

export type ItemDraft = Omit<Item, 'id' | 'createdAt' | 'updatedAt'>

export interface Toast {
  id: string
  message: string
  action?: { label: string; run: () => void }
}

export interface InventoryValue {
  items: Item[]
  movements: Movement[]
  settings: Settings
  getItem: (id: ID) => Item | undefined
  createItem: (draft: ItemDraft) => Item
  updateItem: (id: ID, draft: ItemDraft) => void
  deleteItem: (id: ID) => void
  /** Applies a signed change and records it in the movement log. */
  adjustStock: (id: ID, delta: number, note?: string) => void
  /** Sets an absolute count, e.g. after a physical stocktake. */
  setStock: (id: ID, quantity: number, note?: string) => void
  importItems: (drafts: Omit<Item, 'id' | 'createdAt' | 'updatedAt' | 'photo'>[]) => number
  updateSettings: (patch: Partial<Settings>) => void
  loadDemoData: () => void
  clearAll: () => void
  toasts: Toast[]
  notify: (message: string, action?: Toast['action']) => void
  dismissToast: (id: string) => void
}

export const InventoryContext = createContext<InventoryValue | null>(null)

export function useInventory(): InventoryValue {
  const value = useContext(InventoryContext)
  if (!value) throw new Error('useInventory must be used inside an InventoryProvider')
  return value
}
