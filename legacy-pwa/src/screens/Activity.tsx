import { useMemo, useState } from 'react'
import { Link } from 'react-router-dom'
import { Screen } from '../components/Screen'
import { Icon } from '../components/Icon'
import { EmptyState } from '../components/EmptyState'
import { useInventory } from '../store/context'
import { dateTime, dayLabel, number } from '../lib/format'
import { downloadFile, movementsToCsv } from '../lib/csv'
import type { Movement } from '../types'

type Filter = 'all' | 'in' | 'out' | 'other'

const FILTERS: { key: Filter; label: string }[] = [
  { key: 'all', label: 'All' },
  { key: 'in', label: 'Stock in' },
  { key: 'out', label: 'Stock out' },
  { key: 'other', label: 'Edits' },
]

function matches(m: Movement, filter: Filter): boolean {
  if (filter === 'all') return true
  if (filter === 'in') return m.delta > 0
  if (filter === 'out') return m.delta < 0
  return m.delta === 0
}

export function Activity() {
  const { movements, notify } = useInventory()
  const [filter, setFilter] = useState<Filter>('all')

  const groups = useMemo(() => {
    const filtered = movements.filter((m) => matches(m, filter))
    const map = new Map<string, Movement[]>()
    for (const m of filtered) {
      const key = dayLabel(m.at)
      const list = map.get(key)
      if (list) list.push(m)
      else map.set(key, [m])
    }
    return [...map.entries()]
  }, [movements, filter])

  const totals = useMemo(
    () =>
      movements.reduce(
        (acc, m) => {
          if (m.delta > 0) acc.in += m.delta
          if (m.delta < 0) acc.out -= m.delta
          return acc
        },
        { in: 0, out: 0 },
      ),
    [movements],
  )

  const exportCsv = () => {
    if (movements.length === 0) return
    downloadFile('stock-movements.csv', movementsToCsv(movements), 'text/csv')
    notify('Movement history exported')
  }

  return (
    <Screen
      title="Activity"
      subtitle={`${number(totals.in)} units in · ${number(totals.out)} units out`}
      actions={
        <button
          type="button"
          className="icon-button"
          onClick={exportCsv}
          disabled={movements.length === 0}
          aria-label="Export history"
        >
          <Icon name="download" />
        </button>
      }
      toolbar={
        <div className="chip-row">
          {FILTERS.map((f) => (
            <button
              key={f.key}
              type="button"
              className={`chip${filter === f.key ? ' is-active' : ''}`}
              onClick={() => setFilter(f.key)}
            >
              {f.label}
            </button>
          ))}
        </div>
      }
    >
      {groups.length === 0 ? (
        <EmptyState
          icon="activity"
          title="No movements"
          body="Stock changes you record — receipts, sales, stocktakes and edits — show up here."
        />
      ) : (
        groups.map(([day, entries]) => (
          <section className="card" key={day}>
            <div className="card-head">
              <h2>{day}</h2>
              <span className="card-note">{entries.length}</span>
            </div>
            <ul className="feed">
              {entries.map((m) => (
                <li key={m.id} className="feed-row">
                  <span className="feed-icon" data-kind={m.kind}>
                    <Icon
                      name={m.delta > 0 ? 'arrowUp' : m.delta < 0 ? 'arrowDown' : 'edit'}
                      size={16}
                    />
                  </span>
                  <span className="feed-text">
                    <Link to={`/items/${m.itemId}`} className="feed-name">
                      {m.itemName}
                    </Link>
                    <span className="feed-meta">
                      {m.note || 'Updated'} · {dateTime(m.at)}
                    </span>
                  </span>
                  <span className="feed-right">
                    {m.delta !== 0 && (
                      <span className="feed-delta" data-kind={m.delta > 0 ? 'in' : 'out'}>
                        {m.delta > 0 ? '+' : ''}
                        {number(m.delta)}
                      </span>
                    )}
                    <span className="feed-after">{number(m.after)}</span>
                  </span>
                </li>
              ))}
            </ul>
          </section>
        ))
      )}
    </Screen>
  )
}
