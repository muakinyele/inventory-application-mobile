/**
 * Inline 24x24 stroke icons drawn in `currentColor`, so they inherit text
 * colour and stay crisp in both themes without shipping an icon library.
 */
const PATHS = {
  home: 'M3 10.5 12 3l9 7.5M5.5 9.5V20h13V9.5M9.5 20v-6h5v6',
  box: 'M3.5 7.5 12 3l8.5 4.5v9L12 21l-8.5-4.5v-9ZM3.5 7.5 12 12m0 0 8.5-4.5M12 12v9',
  activity: 'M3 12h4l2.5-6 4 13L16 12h5',
  settings:
    'M12 15a3 3 0 1 0 0-6 3 3 0 0 0 0 6Zm8-3a8 8 0 0 0-.14-1.48l2.02-1.53-2-3.46-2.38.95a8 8 0 0 0-2.56-1.48L14.5 2h-4l-.44 2.5a8 8 0 0 0-2.56 1.48L5.12 5.03l-2 3.46 2.02 1.53a8 8 0 0 0 0 2.96l-2.02 1.53 2 3.46 2.38-.95a8 8 0 0 0 2.56 1.48L10.5 22h4l.44-2.5a8 8 0 0 0 2.56-1.48l2.38.95 2-3.46-2.02-1.53c.09-.48.14-.98.14-1.48Z',
  search: 'M11 18a7 7 0 1 0 0-14 7 7 0 0 0 0 14ZM20 20l-4-4',
  plus: 'M12 5v14M5 12h14',
  minus: 'M5 12h14',
  chevronLeft: 'M15 5l-7 7 7 7',
  chevronRight: 'M9 5l7 7-7 7',
  chevronDown: 'M6 9l6 6 6-6',
  close: 'M6 6l12 12M18 6 6 18',
  check: 'M4 12.5 9 17.5 20 6.5',
  camera:
    'M4 8h3l1.5-2.5h7L17 8h3a1 1 0 0 1 1 1v9a1 1 0 0 1-1 1H4a1 1 0 0 1-1-1V9a1 1 0 0 1 1-1Zm8 9.5a3.75 3.75 0 1 0 0-7.5 3.75 3.75 0 0 0 0 7.5Z',
  scan: 'M3 8V5a2 2 0 0 1 2-2h3M16 3h3a2 2 0 0 1 2 2v3M21 16v3a2 2 0 0 1-2 2h-3M8 21H5a2 2 0 0 1-2-2v-3M3.5 12h17',
  filter: 'M4 6h16M7 12h10M10 18h4',
  arrowDown: 'M12 5v14M6 13l6 6 6-6',
  arrowUp: 'M12 19V5M6 11l6-6 6 6',
  alert: 'M12 3 1.5 21h21L12 3Zm0 6v6m0 3v.5',
  trash: 'M4 7h16M9 7V4.5h6V7M6.5 7l1 13h9l1-13M10.5 11v5M13.5 11v5',
  edit: 'M4 20h4L19 9a2.5 2.5 0 0 0-3.5-3.5L4.5 16.5 4 20ZM14.5 6.5 17.5 9.5',
  download: 'M12 3v12M7 11l5 5 5-5M4 20h16',
  upload: 'M12 16V4M7 8l5-5 5 5M4 20h16',
  moon: 'M20 14.5A8.5 8.5 0 0 1 9.5 4a8.5 8.5 0 1 0 10.5 10.5Z',
  sun: 'M12 16.5a4.5 4.5 0 1 0 0-9 4.5 4.5 0 0 0 0 9ZM12 2v2m0 16v2M2 12h2m16 0h2M4.9 4.9l1.5 1.5m11.2 11.2 1.5 1.5M19.1 4.9l-1.5 1.5M6.4 17.6l-1.5 1.5',
  tag: 'M3 11.5V4.5A1.5 1.5 0 0 1 4.5 3h7l9.5 9.5-8 8L3 11.5Zm4.5-3.5h.01',
  pin: 'M12 21s7-6.2 7-11a7 7 0 1 0-14 0c0 4.8 7 11 7 11Zm0-8.5a2.5 2.5 0 1 0 0-5 2.5 2.5 0 0 0 0 5Z',
  truck: 'M3 16V6h11v10M14 9h3.5l3 3.5V16M3 16h1.5m5 0H14m3 0h3M6.5 19a2 2 0 1 0 0-4 2 2 0 0 0 0 4Zm11 0a2 2 0 1 0 0-4 2 2 0 0 0 0 4Z',
  chart: 'M4 20V10m5 10V4m5 16v-7m5 7V8',
  sort: 'M7 4v16m0 0-3-3m3 3 3-3M17 20V4m0 0-3 3m3-3 3 3',
  refresh: 'M20 12a8 8 0 1 1-2.5-5.8M20 3v4h-4',
  info: 'M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18Zm0-13v.5m0 3V16',
  layers: 'M12 3 3 8l9 5 9-5-9-5ZM3 13l9 5 9-5M3 17.5l9 5 9-5',
} as const

export type IconName = keyof typeof PATHS

interface Props {
  name: IconName
  size?: number
  strokeWidth?: number
  className?: string
}

export function Icon({ name, size = 22, strokeWidth = 1.7, className }: Props) {
  return (
    <svg
      className={className}
      width={size}
      height={size}
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth={strokeWidth}
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
      focusable="false"
    >
      <path d={PATHS[name]} />
    </svg>
  )
}
