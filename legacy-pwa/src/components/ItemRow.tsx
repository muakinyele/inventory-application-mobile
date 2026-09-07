import { Link } from 'react-router-dom'
import type { Item } from '../types'
import { stockStatus } from '../types'
import { initials, money, number } from '../lib/format'
import { Icon } from './Icon'

const STATUS_LABEL = { out: 'Out of stock', low: 'Low', ok: 'In stock' } as const

interface Props {
  item: Item
  currency: string
  /** Optional quick +/- controls, shown on the items list. */
  onAdjust?: (item: Item, delta: number) => void
}

export function ItemRow({ item, currency, onAdjust }: Props) {
  const status = stockStatus(item)

  return (
    <li className="item-row">
      <Link to={`/items/${item.id}`} className="item-main">
        <span className="item-thumb" data-status={status}>
          {item.photo ? <img src={item.photo} alt="" /> : initials(item.name)}
        </span>
        <span className="item-text">
          <span className="item-name">{item.name}</span>
          <span className="item-meta">
            {item.sku || 'No SKU'}
            {item.location && ` · ${item.location}`}
          </span>
        </span>
        <span className="item-stock">
          <span className="item-qty" data-status={status}>
            {number(item.quantity)}
            <small>{item.unit}</small>
          </span>
          <span className="item-value">{money(item.quantity * item.unitCost, currency)}</span>
        </span>
      </Link>

      {onAdjust ? (
        <div className="item-quick">
          <button
            type="button"
            className="quick-button"
            onClick={() => onAdjust(item, -1)}
            disabled={item.quantity <= 0}
            aria-label={`Remove one ${item.name}`}
          >
            <Icon name="minus" size={18} />
          </button>
          <button
            type="button"
            className="quick-button"
            onClick={() => onAdjust(item, 1)}
            aria-label={`Add one ${item.name}`}
          >
            <Icon name="plus" size={18} />
          </button>
        </div>
      ) : (
        status !== 'ok' && (
          <span className="item-flag" data-status={status}>
            {STATUS_LABEL[status]}
          </span>
        )
      )}
    </li>
  )
}
