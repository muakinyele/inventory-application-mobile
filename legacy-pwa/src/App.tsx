import { useEffect } from 'react'
import { Navigate, Route, Routes, useLocation } from 'react-router-dom'
import { TabBar } from './components/TabBar'
import { Toaster } from './components/Toaster'
import { Dashboard } from './screens/Dashboard'
import { Items } from './screens/Items'
import { ItemDetail } from './screens/ItemDetail'
import { ItemEditor } from './screens/ItemEditor'
import { Activity } from './screens/Activity'
import { Settings } from './screens/Settings'
import { useInventory } from './store/context'

const TAB_ROUTES = ['/', '/items', '/activity', '/settings']

export function App() {
  const { settings } = useInventory()
  const location = useLocation()
  const showTabs = TAB_ROUTES.includes(location.pathname)

  useEffect(() => {
    const root = document.documentElement
    if (settings.theme === 'system') root.removeAttribute('data-theme')
    else root.setAttribute('data-theme', settings.theme)
  }, [settings.theme])

  // Sub-screens should open at the top rather than inheriting the list's scroll.
  useEffect(() => {
    document.querySelector('.screen-body')?.scrollTo(0, 0)
  }, [location.pathname])

  return (
    <div className={`app${showTabs ? ' has-tabs' : ''}`}>
      <Routes>
        <Route path="/" element={<Dashboard />} />
        <Route path="/items" element={<Items />} />
        <Route path="/items/new" element={<ItemEditor />} />
        <Route path="/items/:id" element={<ItemDetail />} />
        <Route path="/items/:id/edit" element={<ItemEditor />} />
        <Route path="/activity" element={<Activity />} />
        <Route path="/settings" element={<Settings />} />
        <Route path="*" element={<Navigate to="/" replace />} />
      </Routes>
      {showTabs && <TabBar />}
      <Toaster />
    </div>
  )
}
