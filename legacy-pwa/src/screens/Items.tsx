import { useEffect, useMemo, useState } from 'react'
import { useNavigate, useSearchParams } from 'react-router-dom'
import { Screen } from '../components/Screen'
import { Icon } from '../components/Icon'
import { ItemRow } from '../components/ItemRow'
import { EmptyState } from '../components/EmptyState'
import { Sheet } from '../components/Sheet'
import { Scanner } from '../components/Scanner'
import { useInventory } from '../store/context'
import { stockStatus, type Item, type StockStatus } from '../types'
import { money, number } from '../lib/format'

type SortKey = 'name' | 'quantity' | 'value' | 'updated'

const SORT_LABEL: Record<SortKey, string> = {
  name: 'Name (A–Z)',
  quantity: 'Quantity (low first)',
  value: 'Stock value (high first)',
  updated: 'Recently updated',
}

const STATUS_FILTERS: { key: 'all' | StockStatus; label: string }[] = [
  { key: 'all', label: 'All' },
  { key: 'low', label: 'Low stock' },
  { key: 'out', label: 'Out of stock' },
  { key: 'ok', label: 'In stock' },
]

export function Items() {
  const { items, settings, adjustStock, notify } = useInventory()
  const navigate = useNavigate()
  const [params, setParams] = useSearchParams()

  const [query, setQuery] = useState('')
  const [sort, setSort] = useState<SortKey>('name')
  const [filtersOpen, setFiltersOpen] = useState(false)
  const [scanOpen, setScanOpen] = useState(params.get('scan') === '1')

  const status = (params.get('status') ?? 'all') as 'all' | StockStatus
  const category = params.get('category') ?? ''
  const location = params.get('location') ?? ''

  // Clear the one-shot ?scan=1 so a back-navigation doesn't reopen the camera.
  useEffect(() => {
    if (params.get('scan') === '1') {
      const next = new URLSearchParams(params)
      next.delete('scan')
      setParams(next, { replace: true })
    }
  }, [params, setParams])

  const setParam = (key: string, value: string) => {
    const next = new URLSearchParams(params)
    if (value) next.set(key, value)
    else next.delete(key)
    setParams(next, { replace: true })
  }

  const filtered = useMemo(() => {
    const q = query.trim().toLowerCase()
    const result = items.filter((item) => {
      if (status !== 'all' && stockStatus(item) !== status) return false
      if (category && item.category !== category) return false
      if (location && item.location !== location) return false
      if (!q) return true
      return (
        item.name.toLowerCase().includes(q) ||
        item.sku.toLowerCase().includes(q) ||
        item.barcode.includes(q) ||
        item.supplier.toLowerCase().includes(q) ||
        item.category.toLowerCase().includes(q)
      )
    })

    const sorters: Record<SortKey, (a: Item, b: Item) => number> = {
      name: (a, b) => a.name.localeCompare(b.name),
      quantity: (a, b) => a.quantity - b.quantity,
      value: (a, b) => b.quantity * b.unitCost - a.quantity * a.unitCost,
      updated: (a, b) => b.updatedAt.localeCompare(a.updatedAt),
    }
    return [...result].sort(sorters[sort])
  }, [items, query, status, category, location, sort])

  const totals = useMemo(
    () => ({
      units: filtered.reduce((s, i) => s + i.quantity, 0),
      value: filtered.reduce((s, i) => s + i.quantity * i.unitCost, 0),
    }),
    [filtered],
  )

  const activeFilters = [status !== 'all', Boolean(category), Boolean(location)].filter(
    Boolean,
  ).length

  const handleAdjust = (item: Item, delta: number) => {
    adjustStock(item.id, delta, delta > 0 ? 'Quick add' : 'Quick remove')
    notify(`${item.name}: ${delta > 0 ? '+' : ''}${delta} ${item.unit}`, {
      label: 'Undo',
      run: () => adjustStock(item.id, -delta, 'Undo quick change'),
    })
  }

  const handleScan = (code: string) => {
    setScanOpen(false)
    const match = items.find((i) => i.barcode === code || i.sku === code)
    if (match) {
      navigate(`/items/${match.id}`)
    } else {
      notify('No item matches that code — creating a new one.')
      navigate(`/items/new?barcode=${encodeURIComponent(code)}`)
    }
  }

  const toolbar = (
    <>
      <div className="search">
        <Icon name="search" size={18} />
        <input
          type="search"
          value={query}
          placeholder="Search name, SKU, supplier"
          onChange={(e) => setQuery(e.target.value)}
          aria-label="Search items"
        />
        <button
          type="button"
          className="icon-button"
          onClick={() => setScanOpen(true)}
          aria-label="Scan barcode"
        >
          <Icon name="scan" size={18} />
        </button>
      </div>
      <div className="chip-row">
        {STATUS_FILTERS.map((f) => (
          <button
            key={f.key}
            type="button"
            className={`chip${status === f.key ? ' is-active' : ''}`}
            onClick={() => setParam('status', f.key === 'all' ? '' : f.key)}
          >
            {f.label}
          </button>
        ))}
        <button
          type="button"
          className={`chip${activeFilters > 1 || category || location ? ' is-active' : ''}`}
          onClick={() => setFiltersOpen(true)}
        >
          <Icon name="filter" size={15} />
          More
        </button>
      </div>
    </>
  )

  return (
    <Screen
      title="Items"
      subtitle={`${number(filtered.length)} shown · ${number(totals.units)} units · ${money(totals.value, settings.currency)}`}
      toolbar={toolbar}
      actions={
        <button
          type="button"
          className="icon-button"
          onClick={() => navigate('/items/new')}
          aria-label="Add item"
        >
          <Icon name="plus" />
        </button>
      }
    >
      {filtered.length === 0 ? (
        <EmptyState
          icon="search"
          title={items.length === 0 ? 'No items yet' : 'Nothing matches'}
          body={
            items.length === 0
              ? 'Add your first item to start tracking stock.'
              : 'Try a different search term or clear the filters.'
          }
          action={
            items.length === 0 ? (
              <button type="button" className="button primary" onClick={() => navigate('/items/new')}>
                Add an item
              </button>
            ) : (
              <button
                type="button"
                className="button"
                onClick={() => {
                  setQuery('')
                  setParams(new URLSearchParams(), { replace: true })
                }}
              >
                Clear filters
              </button>
            )
          }
        />
      ) : (
        <ul className="item-list">
          {filtered.map((item) => (
            <ItemRow
              key={item.id}
              item={item}
              currency={settings.currency}
              onAdjust={handleAdjust}
            />
          ))}
        </ul>
      )}

      <Sheet open={filtersOpen} title="Filter & sort" onClose={() => setFiltersOpen(false)}>
        <div className="field">
          <label htmlFor="filter-category">Category</label>
          <select
            id="filter-category"
            value={category}
            onChange={(e) => setParam('category', e.target.value)}
          >
            <option value="">All categories</option>
            {settings.categories.map((c) => (
              <option key={c} value={c}>
                {c}
              </option>
            ))}
          </select>
        </div>
        <div className="field">
          <label htmlFor="filter-location">Location</label>
          <select
            id="filter-location"
            value={location}
            onChange={(e) => setParam('location', e.target.value)}
          >
            <option value="">All locations</option>
            {settings.locations.map((l) => (
              <option key={l} value={l}>
                {l}
              </option>
            ))}
          </select>
        </div>
        <div className="field">
          <label htmlFor="filter-sort">Sort by</label>
          <select
            id="filter-sort"
            value={sort}
            onChange={(e) => setSort(e.target.value as SortKey)}
          >
            {(Object.keys(SORT_LABEL) as SortKey[]).map((key) => (
              <option key={key} value={key}>
                {SORT_LABEL[key]}
              </option>
            ))}
          </select>
        </div>
        <div className="row-gap">
          <button
            type="button"
            className="button"
            onClick={() => {
              setParams(new URLSearchParams(), { replace: true })
              setSort('name')
            }}
          >
            Reset
          </button>
          <button
            type="button"
            className="button primary grow"
            onClick={() => setFiltersOpen(false)}
          >
            Show {number(filtered.length)} items
          </button>
        </div>
      </Sheet>

      <Scanner open={scanOpen} onClose={() => setScanOpen(false)} onDetect={handleScan} />
    </Screen>
  )
}
