import { useMemo, useState } from 'react'
import { Navigate, useNavigate, useParams } from 'react-router-dom'
import { Screen } from '../components/Screen'
import { Icon } from '../components/Icon'
import { Sheet } from '../components/Sheet'
import { useInventory } from '../store/context'
import { stockStatus } from '../types'
import { dateTime, initials, money, number, relativeTime } from '../lib/format'

type Mode = 'in' | 'out' | 'count'

const MODE_TITLE: Record<Mode, string> = {
  in: 'Stock in',
  out: 'Stock out',
  count: 'Set counted quantity',
}

const STATUS_TEXT = {
  out: 'Out of stock',
  low: 'Below reorder level',
  ok: 'In stock',
} as const

export function ItemDetail() {
  const { id = '' } = useParams()
  const navigate = useNavigate()
  const { getItem, movements, settings, adjustStock, setStock, deleteItem, notify } = useInventory()
  const item = getItem(id)

  const [mode, setMode] = useState<Mode | null>(null)
  const [amount, setAmount] = useState('')
  const [note, setNote] = useState('')
  const [confirmDelete, setConfirmDelete] = useState(false)

  const history = useMemo(
    () => movements.filter((m) => m.itemId === id).slice(0, 30),
    [movements, id],
  )

  if (!item) return <Navigate to="/items" replace />

  const status = stockStatus(item)

  const openMode = (next: Mode) => {
    setMode(next)
    setAmount(next === 'count' ? String(item.quantity) : '')
    setNote('')
  }

  const submit = () => {
    const value = Number.parseFloat(amount)
    if (!Number.isFinite(value) || value < 0) return

    if (mode === 'count') {
      setStock(item.id, value, note || 'Stocktake')
      notify(`${item.name} counted at ${number(Math.round(value))} ${item.unit}`)
    } else if (mode) {
      const delta = mode === 'in' ? value : -value
      adjustStock(item.id, delta, note || (mode === 'in' ? 'Stock received' : 'Stock issued'))
      notify(`${item.name}: ${delta > 0 ? '+' : ''}${number(delta)} ${item.unit}`, {
        label: 'Undo',
        run: () => adjustStock(item.id, -delta, 'Undo'),
      })
    }
    setMode(null)
  }

  const remove = () => {
    setConfirmDelete(false)
    deleteItem(item.id)
    notify(`${item.name} deleted`)
    navigate('/items', { replace: true })
  }

  return (
    <Screen
      title={item.name}
      subtitle={item.sku || 'No SKU'}
      back
      actions={
        <button
          type="button"
          className="icon-button"
          onClick={() => navigate(`/items/${item.id}/edit`)}
          aria-label="Edit item"
        >
          <Icon name="edit" />
        </button>
      }
    >
      <section className="hero">
        <div className="hero-thumb" data-status={status}>
          {item.photo ? <img src={item.photo} alt={item.name} /> : initials(item.name)}
        </div>
        <div className="hero-figures">
          <span className="hero-qty">
            {number(item.quantity)}
            <small>{item.unit}</small>
          </span>
          <span className="status-pill" data-status={status}>
            <Icon name={status === 'ok' ? 'check' : 'alert'} size={14} strokeWidth={2} />
            {STATUS_TEXT[status]}
          </span>
          <span className="hero-value">
            {money(item.quantity * item.unitCost, settings.currency)} at cost
          </span>
        </div>
      </section>

      <section className="action-row">
        <button type="button" className="button primary grow" onClick={() => openMode('in')}>
          <Icon name="arrowUp" size={18} /> Stock in
        </button>
        <button type="button" className="button grow" onClick={() => openMode('out')}>
          <Icon name="arrowDown" size={18} /> Stock out
        </button>
        <button
          type="button"
          className="button"
          onClick={() => openMode('count')}
          aria-label="Set counted quantity"
        >
          <Icon name="check" size={18} />
        </button>
      </section>

      <section className="card">
        <div className="card-head">
          <h2>Details</h2>
        </div>
        <dl className="detail-grid">
          <div>
            <dt>Category</dt>
            <dd>{item.category || '—'}</dd>
          </div>
          <div>
            <dt>Location</dt>
            <dd>{item.location || '—'}</dd>
          </div>
          <div>
            <dt>Reorder level</dt>
            <dd>
              {number(item.reorderLevel)} {item.unit}
            </dd>
          </div>
          <div>
            <dt>Supplier</dt>
            <dd>{item.supplier || '—'}</dd>
          </div>
          <div>
            <dt>Unit cost</dt>
            <dd>{money(item.unitCost, settings.currency)}</dd>
          </div>
          <div>
            <dt>Sale price</dt>
            <dd>{item.unitPrice ? money(item.unitPrice, settings.currency) : '—'}</dd>
          </div>
          <div>
            <dt>Barcode</dt>
            <dd className="mono">{item.barcode || '—'}</dd>
          </div>
          <div>
            <dt>Updated</dt>
            <dd>{relativeTime(item.updatedAt)}</dd>
          </div>
        </dl>
        {item.notes && <p className="detail-notes">{item.notes}</p>}
      </section>

      <section className="card">
        <div className="card-head">
          <h2>History</h2>
        </div>
        {history.length === 0 ? (
          <p className="muted">No movements recorded for this item.</p>
        ) : (
          <ul className="feed">
            {history.map((m) => (
              <li key={m.id} className="feed-row">
                <span className="feed-icon" data-kind={m.kind}>
                  <Icon
                    name={m.delta > 0 ? 'arrowUp' : m.delta < 0 ? 'arrowDown' : 'edit'}
                    size={16}
                  />
                </span>
                <span className="feed-text">
                  <span className="feed-name">{m.note || 'Updated'}</span>
                  <span className="feed-meta">
                    {dateTime(m.at)} · {number(m.before)} → {number(m.after)}
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

      <button type="button" className="button danger full" onClick={() => setConfirmDelete(true)}>
        <Icon name="trash" size={18} /> Delete item
      </button>

      <Sheet
        open={mode !== null}
        title={mode ? MODE_TITLE[mode] : ''}
        onClose={() => setMode(null)}
        footer={
          <button
            type="button"
            className="button primary full"
            onClick={submit}
            disabled={amount.trim() === '' || !Number.isFinite(Number.parseFloat(amount))}
          >
            {mode === 'count' ? 'Save count' : 'Confirm'}
          </button>
        }
      >
        <p className="muted">
          {item.name} · currently {number(item.quantity)} {item.unit}
        </p>
        <div className="field">
          <label htmlFor="amount">{mode === 'count' ? 'Counted quantity' : 'Quantity'}</label>
          <div className="stepper">
            <button
              type="button"
              className="quick-button"
              onClick={() =>
                setAmount(String(Math.max(0, (Number.parseFloat(amount) || 0) - 1)))
              }
              aria-label="Decrease"
            >
              <Icon name="minus" size={20} />
            </button>
            <input
              id="amount"
              className="stepper-input"
              inputMode="numeric"
              value={amount}
              placeholder="0"
              onChange={(e) => setAmount(e.target.value)}
              autoFocus
            />
            <button
              type="button"
              className="quick-button"
              onClick={() => setAmount(String((Number.parseFloat(amount) || 0) + 1))}
              aria-label="Increase"
            >
              <Icon name="plus" size={20} />
            </button>
          </div>
          {mode !== 'count' && (
            <div className="chip-row">
              {[5, 10, 25, 50].map((n) => (
                <button
                  key={n}
                  type="button"
                  className="chip"
                  onClick={() => setAmount(String((Number.parseFloat(amount) || 0) + n))}
                >
                  +{n}
                </button>
              ))}
            </div>
          )}
        </div>
        <div className="field">
          <label htmlFor="note">Note (optional)</label>
          <input
            id="note"
            value={note}
            placeholder={mode === 'in' ? 'e.g. PO-2291 received' : 'e.g. Counter sale'}
            onChange={(e) => setNote(e.target.value)}
          />
        </div>
      </Sheet>

      <Sheet
        open={confirmDelete}
        title="Delete item"
        onClose={() => setConfirmDelete(false)}
        footer={
          <div className="row-gap">
            <button type="button" className="button grow" onClick={() => setConfirmDelete(false)}>
              Cancel
            </button>
            <button type="button" className="button danger grow" onClick={remove}>
              Delete
            </button>
          </div>
        }
      >
        <p>
          Remove <strong>{item.name}</strong> from the catalogue? Its movement history is kept in
          Activity.
        </p>
      </Sheet>
    </Screen>
  )
}
