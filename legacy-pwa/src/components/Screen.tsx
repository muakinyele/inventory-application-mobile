import { useNavigate } from 'react-router-dom'
import type { ReactNode } from 'react'
import { Icon } from './Icon'

interface Props {
  title: string
  subtitle?: string
  /** Shows a back chevron that pops the history stack. */
  back?: boolean
  actions?: ReactNode
  /** Rendered under the title bar and pinned while the body scrolls. */
  toolbar?: ReactNode
  children: ReactNode
}

export function Screen({ title, subtitle, back, actions, toolbar, children }: Props) {
  const navigate = useNavigate()

  return (
    <div className="screen">
      <header className="appbar">
        <div className="appbar-row">
          {back && (
            <button
              type="button"
              className="icon-button appbar-back"
              onClick={() => navigate(-1)}
              aria-label="Go back"
            >
              <Icon name="chevronLeft" />
            </button>
          )}
          <div className="appbar-titles">
            <h1 className="appbar-title">{title}</h1>
            {subtitle && <p className="appbar-subtitle">{subtitle}</p>}
          </div>
          {actions && <div className="appbar-actions">{actions}</div>}
        </div>
        {toolbar && <div className="appbar-toolbar">{toolbar}</div>}
      </header>
      <main className="screen-body">{children}</main>
    </div>
  )
}
