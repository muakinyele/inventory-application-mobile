import { useMemo } from 'react'
import { Link, useNavigate } from 'react-router-dom'
import { Screen } from '../components/Screen'
import { Icon, type IconName } from '../components/Icon'
import { CategoryBars, type CategorySlice } from '../components/CategoryBars'
import { EmptyState } from '../components/EmptyState'
import { useInventory } from '../store/context'
import { stockStatus } from '../types'
import { money, moneyCompact, number, relativeTime } from '../lib/format'

const QUICK_ACTIONS: { to: string; label: string; icon: IconName }[] = [
  { to: '/items/new', label: 'New item', icon: 'plus' },
  { to: '/items?scan=1', label: 'Scan', icon: 'scan' },
  { to: '/items?status=low', label: 'Reorder', icon: 'alert' },
  { to: '/activity', label: 'History', icon: 'activity' },
]

export function Dashboard() {
  const { items, movements, settings } = useInventory()
  const navigate = useNavigate()
  const currency = settings.currency

  const stats = useMemo(() => {
    const units = items.reduce((sum, i) => sum + i.quantity, 0)
    const value = items.reduce((sum, i) => sum + i.quantity * i.unitCost, 0)
    const attention = items
      .filter((i) => stockStatus(i) !== 'ok')
      .sort((a, b) => {
        const rank = (q: number) => (q <= 0 ? 0 : 1)
        return rank(a.quantity) - rank(b.quantity) || a.quantity - b.quantity
      })
    return { units, value, attention }
  }, [items])

  const byCategory = useMemo<CategorySlice[]>(() => {
    const map = new Map<string, CategorySlice>()
    for (const item of items) {
      const label = item.category || 'Uncategorised'
      const slice = map.get(label) ?? { label, value: 0, units: 0 }
      slice.value += item.quantity * item.unitCost
      slice.units += item.quantity
      map.set(label, slice)
    }
    return [...map.values()].sort((a, b) => b.value - a.value).slice(0, 6)
  }, [items])

  const recent = movements.slice(0, 5)

  if (items.length === 0) {
    return (
      <Screen title={settings.companyName} subtitle="Inventory overview">
        <EmptyState
          icon="box"
          title="No stock yet"
          body="Add your first item, or load the sample catalogue from Settings to see how the app works."
          action={
            <button type="button" className="button primary" onClick={() => navigate('/items/new')}>
              Add an item
            </button>
          }
        />
      </Screen>
    )
  }

  return (
    <Screen title={settings.companyName} subtitle="Inventory overview">
      <section className="stat-grid">
        <div className="stat">
          <span className="stat-label">Stock value</span>
          <span className="stat-value">{moneyCompact(stats.value, currency)}</span>
          <span className="stat-foot">at cost</span>
        </div>
        <div className="stat">
          <span className="stat-label">Units on hand</span>
          <span className="stat-value">{number(stats.units)}</span>
          <span className="stat-foot">across {items.length} items</span>
        </div>
        <div className="stat" data-tone={stats.attention.length > 0 ? 'warn' : undefined}>
          <span className="stat-label">Needs reorder</span>
          <span className="stat-value">{stats.attention.length}</span>
          <span className="stat-foot">at or below level</span>
        </div>
        <div className="stat">
          <span className="stat-label">Categories</span>
          <span className="stat-value">{byCategory.length}</span>
          <span className="stat-foot">in use</span>
        </div>
      </section>

      <section className="quick-grid">
        {QUICK_ACTIONS.map((action) => (
          <Link key={action.label} to={action.to} className="quick">
            <Icon name={action.icon} size={20} />
            <span>{action.label}</span>
          </Link>
        ))}
      </section>

      {stats.attention.length > 0 && (
        <section className="card">
          <div className="card-head">
            <h2>Needs attention</h2>
            <Link to="/items?status=low" className="card-link">
              See all
            </Link>
          </div>
          <ul className="alert-list">
            {stats.attention.slice(0, 4).map((item) => {
              const status = stockStatus(item)
              return (
                <li key={item.id}>
                  <Link to={`/items/${item.id}`} className="alert">
                    <span className="alert-dot" data-status={status} aria-hidden="true" />
                    <span className="alert-text">
                      <span className="alert-name">{item.name}</span>
                      <span className="alert-meta">
                        {status === 'out'
                          ? 'Out of stock'
                          : `${number(item.quantity)} left · level ${number(item.reorderLevel)}`}
                      </span>
                    </span>
                    <Icon name="chevronRight" size={18} />
                  </Link>
                </li>
              )
            })}
          </ul>
        </section>
      )}

      <section className="card">
        <div className="card-head">
          <h2>Stock value by category</h2>
        </div>
        <CategoryBars data={byCategory} currency={currency} />
      </section>

      <section className="card">
        <div className="card-head">
          <h2>Recent movements</h2>
          <Link to="/activity" className="card-link">
            See all
          </Link>
        </div>
        {recent.length === 0 ? (
          <p className="muted">Nothing recorded yet.</p>
        ) : (
          <ul className="feed">
            {recent.map((m) => (
              <li key={m.id} className="feed-row">
                <span className="feed-icon" data-kind={m.kind}>
                  <Icon
                    name={m.delta > 0 ? 'arrowUp' : m.delta < 0 ? 'arrowDown' : 'edit'}
                    size={16}
                  />
                </span>
                <span className="feed-text">
                  <span className="feed-name">{m.itemName}</span>
                  <span className="feed-meta">
                    {m.note || 'Updated'} · {relativeTime(m.at)}
                  </span>
                </span>
                {m.delta !== 0 && (
                  <span className="feed-delta" data-kind={m.delta > 0 ? 'in' : 'out'}>
                    {m.delta > 0 ? '+' : ''}
                    {number(m.delta)}
                  </span>
                )}
              </li>
            ))}
          </ul>
        )}
      </section>

      <p className="footnote">
        Total retail value {money(items.reduce((s, i) => s + i.quantity * i.unitPrice, 0), currency)}
      </p>
    </Screen>
  )
}
