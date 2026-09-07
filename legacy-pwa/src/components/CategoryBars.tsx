import { money } from '../lib/format'

export interface CategorySlice {
  label: string
  value: number
  units: number
}

interface Props {
  data: CategorySlice[]
  currency: string
}

/**
 * Ranked horizontal bars for one measure (stock value) across categories.
 * One series, so one hue and no legend — the row labels carry identity and
 * every bar is directly labelled with its value.
 */
export function CategoryBars({ data, currency }: Props) {
  const max = Math.max(...data.map((d) => d.value), 1)

  return (
    <div className="bars">
      {data.map((slice) => (
        <div className="bar-row" key={slice.label}>
          <div className="bar-head">
            <span className="bar-label">{slice.label}</span>
            <span className="bar-value">{money(slice.value, currency)}</span>
          </div>
          <div className="bar-track">
            <div
              className="bar-fill"
              style={{ width: `${Math.max((slice.value / max) * 100, 1.5)}%` }}
            />
          </div>
        </div>
      ))}
    </div>
  )
}
