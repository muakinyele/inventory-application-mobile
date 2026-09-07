import { useCallback, useEffect, useMemo, useReducer, useState, type ReactNode } from 'react'
import type { Database, ID, Item, Movement, MovementKind, Settings } from '../types'
import { emptyDatabase, loadDatabase, resetDatabase, saveDatabase } from '../lib/storage'
import {
  InventoryContext,
  type InventoryValue,
  type ItemDraft,
  type Toast,
} from './context'

function uid(): string {
  if (typeof crypto !== 'undefined' && 'randomUUID' in crypto) return crypto.randomUUID()
  return `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 10)}`
}

function movement(
  item: Pick<Item, 'id' | 'name'>,
  kind: MovementKind,
  before: number,
  after: number,
  note: string,
): Movement {
  return {
    id: uid(),
    itemId: item.id,
    itemName: item.name,
    kind,
    delta: after - before,
    before,
    after,
    note,
    at: new Date().toISOString(),
  }
}

type Action =
  | { type: 'put-item'; item: Item; movement: Movement }
  | { type: 'delete-item'; id: ID; movement: Movement }
  | { type: 'bulk-add'; items: Item[]; movements: Movement[] }
  | { type: 'patch-settings'; patch: Partial<Settings> }
  | { type: 'replace'; db: Database }

const MAX_MOVEMENTS = 500

function withMovement(db: Database, m: Movement): Movement[] {
  return [m, ...db.movements].slice(0, MAX_MOVEMENTS)
}

function reducer(db: Database, action: Action): Database {
  switch (action.type) {
    case 'put-item': {
      const exists = db.items.some((i) => i.id === action.item.id)
      const items = exists
        ? db.items.map((i) => (i.id === action.item.id ? action.item : i))
        : [action.item, ...db.items]
      return { ...db, items, movements: withMovement(db, action.movement) }
    }
    case 'delete-item':
      return {
        ...db,
        items: db.items.filter((i) => i.id !== action.id),
        movements: withMovement(db, action.movement),
      }
    case 'bulk-add':
      return {
        ...db,
        items: [...action.items, ...db.items],
        movements: [...action.movements, ...db.movements].slice(0, MAX_MOVEMENTS),
      }
    case 'patch-settings':
      return { ...db, settings: { ...db.settings, ...action.patch } }
    case 'replace':
      return action.db
    default:
      return db
  }
}

export function InventoryProvider({ children }: { children: ReactNode }) {
  const [db, dispatch] = useReducer(reducer, undefined, loadDatabase)
  const [toasts, setToasts] = useState<Toast[]>([])

  useEffect(() => {
    saveDatabase(db)
  }, [db])

  const dismissToast = useCallback((id: string) => {
    setToasts((current) => current.filter((t) => t.id !== id))
  }, [])

  const notify = useCallback(
    (message: string, action?: Toast['action']) => {
      const id = uid()
      setToasts((current) => [...current.slice(-2), { id, message, action }])
      setTimeout(() => dismissToast(id), 4000)
    },
    [dismissToast],
  )

  const value = useMemo<InventoryValue>(() => {
    const getItem = (id: ID) => db.items.find((i) => i.id === id)

    /** Merges any new category/location/unit into settings so pickers stay in sync. */
    const learnOptions = (draft: ItemDraft) => {
      const patch: Partial<Settings> = {}
      if (draft.category && !db.settings.categories.includes(draft.category)) {
        patch.categories = [...db.settings.categories, draft.category]
      }
      if (draft.location && !db.settings.locations.includes(draft.location)) {
        patch.locations = [...db.settings.locations, draft.location]
      }
      if (draft.unit && !db.settings.units.includes(draft.unit)) {
        patch.units = [...db.settings.units, draft.unit]
      }
      if (Object.keys(patch).length > 0) dispatch({ type: 'patch-settings', patch })
    }

    return {
      items: db.items,
      movements: db.movements,
      settings: db.settings,
      getItem,

      createItem(draft) {
        const now = new Date().toISOString()
        const item: Item = { ...draft, id: uid(), createdAt: now, updatedAt: now }
        learnOptions(draft)
        dispatch({
          type: 'put-item',
          item,
          movement: movement(item, 'create', 0, item.quantity, 'Item created'),
        })
        return item
      },

      updateItem(id, draft) {
        const existing = getItem(id)
        if (!existing) return
        const item: Item = { ...existing, ...draft, updatedAt: new Date().toISOString() }
        learnOptions(draft)
        const changedQty = existing.quantity !== item.quantity
        dispatch({
          type: 'put-item',
          item,
          movement: movement(
            item,
            changedQty ? 'adjust' : 'edit',
            existing.quantity,
            item.quantity,
            changedQty ? 'Quantity changed while editing' : 'Details updated',
          ),
        })
      },

      deleteItem(id) {
        const existing = getItem(id)
        if (!existing) return
        dispatch({
          type: 'delete-item',
          id,
          movement: movement(existing, 'delete', existing.quantity, 0, 'Item deleted'),
        })
      },

      adjustStock(id, delta, note = '') {
        const existing = getItem(id)
        if (!existing || delta === 0) return
        // Stock can never go below zero; a bigger "out" simply empties the bin.
        const after = Math.max(0, existing.quantity + delta)
        if (after === existing.quantity) return
        const item: Item = { ...existing, quantity: after, updatedAt: new Date().toISOString() }
        dispatch({
          type: 'put-item',
          item,
          movement: movement(item, delta > 0 ? 'in' : 'out', existing.quantity, after, note),
        })
      },

      setStock(id, quantity, note = 'Stocktake') {
        const existing = getItem(id)
        if (!existing) return
        const after = Math.max(0, Math.round(quantity))
        if (after === existing.quantity) return
        const item: Item = { ...existing, quantity: after, updatedAt: new Date().toISOString() }
        dispatch({
          type: 'put-item',
          item,
          movement: movement(item, 'adjust', existing.quantity, after, note),
        })
      },

      importItems(drafts) {
        const now = new Date().toISOString()
        const items: Item[] = drafts.map((d) => ({
          ...d,
          photo: null,
          id: uid(),
          createdAt: now,
          updatedAt: now,
        }))
        const movements = items.map((item) =>
          movement(item, 'create', 0, item.quantity, 'Imported from CSV'),
        )
        const categories = new Set(db.settings.categories)
        const locations = new Set(db.settings.locations)
        const units = new Set(db.settings.units)
        items.forEach((i) => {
          if (i.category) categories.add(i.category)
          if (i.location) locations.add(i.location)
          if (i.unit) units.add(i.unit)
        })
        dispatch({ type: 'bulk-add', items, movements })
        dispatch({
          type: 'patch-settings',
          patch: {
            categories: [...categories],
            locations: [...locations],
            units: [...units],
          },
        })
        return items.length
      },

      updateSettings(patch) {
        dispatch({ type: 'patch-settings', patch })
      },

      loadDemoData() {
        dispatch({ type: 'replace', db: resetDatabase() })
      },

      clearAll() {
        dispatch({ type: 'replace', db: emptyDatabase() })
      },

      toasts,
      notify,
      dismissToast,
    }
  }, [db, toasts, notify, dismissToast])

  return <InventoryContext.Provider value={value}>{children}</InventoryContext.Provider>
}
