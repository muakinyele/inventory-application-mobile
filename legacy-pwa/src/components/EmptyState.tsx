import type { ReactNode } from 'react'
import { Icon, type IconName } from './Icon'

interface Props {
  icon: IconName
  title: string
  body: string
  action?: ReactNode
}

export function EmptyState({ icon, title, body, action }: Props) {
  return (
    <div className="empty">
      <div className="empty-icon">
        <Icon name={icon} size={28} />
      </div>
      <h3>{title}</h3>
      <p>{body}</p>
      {action}
    </div>
  )
}
