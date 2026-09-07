import { useRef, useState, type FormEvent } from 'react'
import { Navigate, useNavigate, useParams, useSearchParams } from 'react-router-dom'
import { Screen } from '../components/Screen'
import { Icon } from '../components/Icon'
import { Scanner } from '../components/Scanner'
import { useInventory, type ItemDraft } from '../store/context'
import { fileToThumbnail } from '../lib/image'
import { initials } from '../lib/format'

type NumberField = 'quantity' | 'reorderLevel' | 'unitCost' | 'unitPrice'

/** Zero shows as an empty box so there is nothing to clear before typing. */
function asText(value: number | undefined): string {
  return value ? String(value) : ''
}

/** `null` means "typed something that isn't a number"; blank means zero. */
function asNumber(raw: string): number | null {
  const trimmed = raw.trim()
  if (trimmed === '') return 0
  const parsed = Number(trimmed)
  return Number.isFinite(parsed) ? parsed : null
}

function emptyDraft(barcode: string, unit: string): ItemDraft {
  return {
    name: '',
    sku: '',
    barcode,
    category: '',
    location: '',
    quantity: 0,
    reorderLevel: 0,
    unit,
    unitCost: 0,
    unitPrice: 0,
    supplier: '',
    notes: '',
    photo: null,
  }
}

export function ItemEditor() {
  const { id } = useParams()
  const navigate = useNavigate()
  const [params] = useSearchParams()
  const { getItem, createItem, updateItem, settings, notify } = useInventory()

  const existing = id ? getItem(id) : undefined
  const [draft, setDraft] = useState<ItemDraft>(() =>
    existing
      ? { ...existing }
      : emptyDraft(params.get('barcode') ?? '', settings.units[0] ?? 'pcs'),
  )
  // Numeric fields keep their raw text so the box can be genuinely empty and
  // mid-typing values like "0." survive; they are parsed once, on submit.
  const [numbers, setNumbers] = useState<Record<NumberField, string>>(() => ({
    quantity: asText(existing?.quantity),
    reorderLevel: asText(existing?.reorderLevel),
    unitCost: asText(existing?.unitCost),
    unitPrice: asText(existing?.unitPrice),
  }))
  const [errors, setErrors] = useState<Record<string, string>>({})
  const [scanOpen, setScanOpen] = useState(false)
  const fileRef = useRef<HTMLInputElement>(null)

  if (id && !existing) return <Navigate to="/items" replace />

  const set = <K extends keyof ItemDraft>(key: K, value: ItemDraft[K]) => {
    setDraft((d) => ({ ...d, [key]: value }))
  }

  const setNumber = (key: NumberField, raw: string) => {
    setNumbers((n) => ({ ...n, [key]: raw }))
  }

  const pickPhoto = async (file: File | undefined) => {
    if (!file) return
    try {
      set('photo', await fileToThumbnail(file))
    } catch (e) {
      notify(e instanceof Error ? e.message : 'Could not use that photo.')
    }
  }

  const submit = (e: FormEvent) => {
    e.preventDefault()
    const parsed = {
      quantity: asNumber(numbers.quantity),
      reorderLevel: asNumber(numbers.reorderLevel),
      unitCost: asNumber(numbers.unitCost),
      unitPrice: asNumber(numbers.unitPrice),
    }

    const next: Record<string, string> = {}
    if (!draft.name.trim()) next.name = 'Give the item a name.'
    if (parsed.quantity === null) next.quantity = 'Enter a number, or leave it blank for zero.'
    else if (parsed.quantity < 0) next.quantity = 'Quantity cannot be negative.'
    if (parsed.unitCost === null) next.unitCost = 'Enter an amount, or leave it blank.'
    else if (parsed.unitCost < 0) next.unitCost = 'Cost cannot be negative.'
    setErrors(next)
    if (Object.keys(next).length > 0) return

    const clean: ItemDraft = {
      ...draft,
      quantity: parsed.quantity ?? 0,
      reorderLevel: Math.max(0, parsed.reorderLevel ?? 0),
      unitCost: Math.max(0, parsed.unitCost ?? 0),
      unitPrice: Math.max(0, parsed.unitPrice ?? 0),
      name: draft.name.trim(),
      sku: draft.sku.trim(),
      barcode: draft.barcode.trim(),
      category: draft.category.trim(),
      location: draft.location.trim(),
      supplier: draft.supplier.trim(),
      unit: draft.unit.trim() || 'pcs',
      notes: draft.notes.trim(),
    }

    if (existing) {
      updateItem(existing.id, clean)
      notify(`${clean.name} updated`)
      navigate(`/items/${existing.id}`, { replace: true })
    } else {
      const created = createItem(clean)
      notify(`${clean.name} added`)
      navigate(`/items/${created.id}`, { replace: true })
    }
  }

  return (
    <Screen title={existing ? 'Edit item' : 'New item'} back>
      <form className="form" onSubmit={submit} noValidate>
        <div className="photo-picker">
          <button
            type="button"
            className="photo-preview"
            onClick={() => fileRef.current?.click()}
            aria-label="Add a photo"
          >
            {draft.photo ? (
              <img src={draft.photo} alt="" />
            ) : draft.name ? (
              initials(draft.name)
            ) : (
              <Icon name="camera" size={26} />
            )}
          </button>
          <div className="photo-actions">
            <button type="button" className="button" onClick={() => fileRef.current?.click()}>
              {draft.photo ? 'Replace photo' : 'Add photo'}
            </button>
            {draft.photo && (
              <button type="button" className="button ghost" onClick={() => set('photo', null)}>
                Remove
              </button>
            )}
          </div>
          <input
            ref={fileRef}
            type="file"
            accept="image/*"
            capture="environment"
            hidden
            onChange={(e) => {
              void pickPhoto(e.target.files?.[0])
              e.target.value = ''
            }}
          />
        </div>

        <div className="field">
          <label htmlFor="name">Item name</label>
          <input
            id="name"
            value={draft.name}
            placeholder="e.g. USB-C Cable 2m"
            onChange={(e) => set('name', e.target.value)}
            aria-invalid={Boolean(errors.name)}
          />
          {errors.name && <span className="field-error">{errors.name}</span>}
        </div>

        <div className="field-pair">
          <div className="field">
            <label htmlFor="sku">SKU</label>
            <input
              id="sku"
              value={draft.sku}
              placeholder="CBL-USBC-2M"
              onChange={(e) => set('sku', e.target.value)}
            />
          </div>
          <div className="field">
            <label htmlFor="barcode">Barcode</label>
            <div className="row-gap">
              <input
                id="barcode"
                value={draft.barcode}
                inputMode="numeric"
                placeholder="Scan or type"
                onChange={(e) => set('barcode', e.target.value)}
              />
              <button
                type="button"
                className="icon-button bordered"
                onClick={() => setScanOpen(true)}
                aria-label="Scan barcode"
              >
                <Icon name="scan" size={18} />
              </button>
            </div>
          </div>
        </div>

        <div className="field-pair">
          <div className="field">
            <label htmlFor="category">Category</label>
            <input
              id="category"
              list="category-options"
              value={draft.category}
              placeholder="Electronics"
              onChange={(e) => set('category', e.target.value)}
            />
            <datalist id="category-options">
              {settings.categories.map((c) => (
                <option key={c} value={c} />
              ))}
            </datalist>
          </div>
          <div className="field">
            <label htmlFor="location">Location</label>
            <input
              id="location"
              list="location-options"
              value={draft.location}
              placeholder="Main Warehouse"
              onChange={(e) => set('location', e.target.value)}
            />
            <datalist id="location-options">
              {settings.locations.map((l) => (
                <option key={l} value={l} />
              ))}
            </datalist>
          </div>
        </div>

        <div className="field-pair">
          <div className="field">
            <label htmlFor="quantity">Quantity on hand</label>
            <input
              id="quantity"
              inputMode="numeric"
              value={numbers.quantity}
              placeholder="0"
              onChange={(e) => setNumber('quantity', e.target.value)}
              aria-invalid={Boolean(errors.quantity)}
            />
            {errors.quantity && <span className="field-error">{errors.quantity}</span>}
          </div>
          <div className="field">
            <label htmlFor="unit">Unit</label>
            <input
              id="unit"
              list="unit-options"
              value={draft.unit}
              onChange={(e) => set('unit', e.target.value)}
            />
            <datalist id="unit-options">
              {settings.units.map((u) => (
                <option key={u} value={u} />
              ))}
            </datalist>
          </div>
        </div>

        <div className="field">
          <label htmlFor="reorderLevel">Reorder level</label>
          <input
            id="reorderLevel"
            inputMode="numeric"
            value={numbers.reorderLevel}
            placeholder="0"
            onChange={(e) => setNumber('reorderLevel', e.target.value)}
          />
          <span className="field-hint">
            The app flags the item once stock drops to this number. Use 0 to never flag it.
          </span>
        </div>

        <div className="field-pair">
          <div className="field">
            <label htmlFor="unitCost">Unit cost ({settings.currency})</label>
            <input
              id="unitCost"
              inputMode="decimal"
              value={numbers.unitCost}
              placeholder="0.00"
              onChange={(e) => setNumber('unitCost', e.target.value)}
              aria-invalid={Boolean(errors.unitCost)}
            />
            {errors.unitCost && <span className="field-error">{errors.unitCost}</span>}
          </div>
          <div className="field">
            <label htmlFor="unitPrice">Sale price ({settings.currency})</label>
            <input
              id="unitPrice"
              inputMode="decimal"
              value={numbers.unitPrice}
              placeholder="0.00"
              onChange={(e) => setNumber('unitPrice', e.target.value)}
            />
          </div>
        </div>

        <div className="field">
          <label htmlFor="supplier">Supplier</label>
          <input
            id="supplier"
            value={draft.supplier}
            placeholder="Who you buy it from"
            onChange={(e) => set('supplier', e.target.value)}
          />
        </div>

        <div className="field">
          <label htmlFor="notes">Notes</label>
          <textarea
            id="notes"
            rows={3}
            value={draft.notes}
            placeholder="Anything worth remembering about this item"
            onChange={(e) => set('notes', e.target.value)}
          />
        </div>

        <div className="form-actions">
          <button type="button" className="button grow" onClick={() => navigate(-1)}>
            Cancel
          </button>
          <button type="submit" className="button primary grow">
            {existing ? 'Save changes' : 'Add item'}
          </button>
        </div>
      </form>

      <Scanner
        open={scanOpen}
        onClose={() => setScanOpen(false)}
        onDetect={(code) => {
          set('barcode', code)
          setScanOpen(false)
        }}
      />
    </Screen>
  )
}
