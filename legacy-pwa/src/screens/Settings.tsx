import { useRef, useState } from 'react'
import { Screen } from '../components/Screen'
import { Icon } from '../components/Icon'
import { Sheet } from '../components/Sheet'
import { useInventory } from '../store/context'
import { csvToItems, downloadFile, itemsToCsv } from '../lib/csv'
import { number } from '../lib/format'
import type { Settings as SettingsShape } from '../types'

const CURRENCIES = ['USD', 'EUR', 'GBP', 'NGN', 'CAD', 'AUD', 'ZAR', 'INR', 'KES', 'GHS']

type ListKey = 'categories' | 'locations' | 'units'

const LIST_TITLE: Record<ListKey, string> = {
  categories: 'Categories',
  locations: 'Locations',
  units: 'Units',
}

export function Settings() {
  const { items, movements, settings, updateSettings, importItems, loadDemoData, clearAll, notify } =
    useInventory()
  const fileRef = useRef<HTMLInputElement>(null)
  const [listKey, setListKey] = useState<ListKey | null>(null)
  const [newEntry, setNewEntry] = useState('')
  const [confirmClear, setConfirmClear] = useState(false)

  const exportItems = () => {
    if (items.length === 0) {
      notify('Nothing to export yet.')
      return
    }
    downloadFile('inventory-items.csv', itemsToCsv(items), 'text/csv')
    notify(`${number(items.length)} items exported`)
  }

  const exportBackup = () => {
    downloadFile(
      'inventory-backup.json',
      JSON.stringify({ version: 1, items, movements, settings }, null, 2),
      'application/json',
    )
    notify('Backup downloaded')
  }

  const handleImport = async (file: File | undefined) => {
    if (!file) return
    try {
      const text = await file.text()
      const { items: drafts, errors } = csvToItems(text)
      if (drafts.length === 0) {
        notify(errors[0] ?? 'No rows could be imported.')
        return
      }
      const count = importItems(drafts)
      notify(
        errors.length > 0
          ? `Imported ${number(count)} items, skipped ${errors.length}`
          : `Imported ${number(count)} items`,
      )
    } catch {
      notify('That file could not be read.')
    }
  }

  const addEntry = () => {
    const value = newEntry.trim()
    if (!listKey || !value) return
    const current = settings[listKey]
    if (current.includes(value)) {
      notify('That entry already exists.')
      return
    }
    updateSettings({ [listKey]: [...current, value] } as Partial<SettingsShape>)
    setNewEntry('')
  }

  const removeEntry = (value: string) => {
    if (!listKey) return
    updateSettings({
      [listKey]: settings[listKey].filter((v) => v !== value),
    } as Partial<SettingsShape>)
  }

  return (
    <Screen title="Settings" subtitle={`${number(items.length)} items tracked`}>
      <section className="card">
        <div className="card-head">
          <h2>Workspace</h2>
        </div>
        <div className="field">
          <label htmlFor="company">Workspace name</label>
          <input
            id="company"
            value={settings.companyName}
            onChange={(e) => updateSettings({ companyName: e.target.value })}
          />
        </div>
        <div className="field">
          <label htmlFor="currency">Currency</label>
          <select
            id="currency"
            value={settings.currency}
            onChange={(e) => updateSettings({ currency: e.target.value })}
          >
            {CURRENCIES.map((c) => (
              <option key={c} value={c}>
                {c}
              </option>
            ))}
          </select>
        </div>
        <div className="field">
          <label htmlFor="theme">Appearance</label>
          <select
            id="theme"
            value={settings.theme}
            onChange={(e) => updateSettings({ theme: e.target.value as SettingsShape['theme'] })}
          >
            <option value="system">Match device</option>
            <option value="light">Light</option>
            <option value="dark">Dark</option>
          </select>
        </div>
      </section>

      <section className="card">
        <div className="card-head">
          <h2>Lists</h2>
        </div>
        <ul className="menu">
          {(Object.keys(LIST_TITLE) as ListKey[]).map((key) => (
            <li key={key}>
              <button type="button" className="menu-row" onClick={() => setListKey(key)}>
                <Icon name={key === 'locations' ? 'pin' : key === 'units' ? 'layers' : 'tag'} size={20} />
                <span className="menu-label">{LIST_TITLE[key]}</span>
                <span className="menu-note">{settings[key].length}</span>
                <Icon name="chevronRight" size={18} />
              </button>
            </li>
          ))}
        </ul>
      </section>

      <section className="card">
        <div className="card-head">
          <h2>Data</h2>
        </div>
        <ul className="menu">
          <li>
            <button type="button" className="menu-row" onClick={exportItems}>
              <Icon name="download" size={20} />
              <span className="menu-label">Export items (CSV)</span>
            </button>
          </li>
          <li>
            <button type="button" className="menu-row" onClick={() => fileRef.current?.click()}>
              <Icon name="upload" size={20} />
              <span className="menu-label">Import items (CSV)</span>
            </button>
          </li>
          <li>
            <button type="button" className="menu-row" onClick={exportBackup}>
              <Icon name="layers" size={20} />
              <span className="menu-label">Download full backup (JSON)</span>
            </button>
          </li>
          <li>
            <button type="button" className="menu-row" onClick={loadDemoData}>
              <Icon name="refresh" size={20} />
              <span className="menu-label">Load sample catalogue</span>
            </button>
          </li>
          <li>
            <button
              type="button"
              className="menu-row danger"
              onClick={() => setConfirmClear(true)}
            >
              <Icon name="trash" size={20} />
              <span className="menu-label">Erase all data</span>
            </button>
          </li>
        </ul>
        <input
          ref={fileRef}
          type="file"
          accept=".csv,text/csv"
          hidden
          onChange={(e) => {
            void handleImport(e.target.files?.[0])
            e.target.value = ''
          }}
        />
        <p className="field-hint">
          A CSV import needs a <code>name</code> column; <code>sku</code>, <code>quantity</code>,{' '}
          <code>unitCost</code> and the rest are optional. Export a file first to see the shape.
        </p>
      </section>

      <section className="card">
        <div className="card-head">
          <h2>About</h2>
        </div>
        <p className="muted">
          Everything is stored on this device only — no account, no server. Add the app to your home
          screen from the browser menu to use it full-screen and offline.
        </p>
      </section>

      <Sheet
        open={listKey !== null}
        title={listKey ? LIST_TITLE[listKey] : ''}
        onClose={() => {
          setListKey(null)
          setNewEntry('')
        }}
      >
        <div className="field">
          <div className="row-gap">
            <input
              value={newEntry}
              placeholder="Add a new entry"
              onChange={(e) => setNewEntry(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === 'Enter') {
                  e.preventDefault()
                  addEntry()
                }
              }}
              aria-label="New entry"
            />
            <button type="button" className="button" onClick={addEntry} disabled={!newEntry.trim()}>
              Add
            </button>
          </div>
        </div>
        <ul className="chip-list">
          {listKey &&
            settings[listKey].map((value) => (
              <li key={value} className="chip static">
                {value}
                <button
                  type="button"
                  onClick={() => removeEntry(value)}
                  aria-label={`Remove ${value}`}
                >
                  <Icon name="close" size={14} strokeWidth={2.2} />
                </button>
              </li>
            ))}
        </ul>
        <p className="field-hint">
          Removing an entry only takes it out of the picker — items already using it keep their
          value.
        </p>
      </Sheet>

      <Sheet
        open={confirmClear}
        title="Erase all data"
        onClose={() => setConfirmClear(false)}
        footer={
          <div className="row-gap">
            <button type="button" className="button grow" onClick={() => setConfirmClear(false)}>
              Cancel
            </button>
            <button
              type="button"
              className="button danger grow"
              onClick={() => {
                clearAll()
                setConfirmClear(false)
                notify('All data erased')
              }}
            >
              Erase everything
            </button>
          </div>
        }
      >
        <p>
          This deletes every item and all movement history on this device. Download a backup first
          if you might want it back.
        </p>
      </Sheet>
    </Screen>
  )
}
