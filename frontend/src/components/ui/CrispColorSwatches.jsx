function parseHexLuminance(hex) {
  const cleaned = String(hex || '').trim().replace(/^#/, '')
  if (!/^[0-9a-f]{6}$/i.test(cleaned)) return 128
  const r = Number.parseInt(cleaned.slice(0, 2), 16)
  const g = Number.parseInt(cleaned.slice(2, 4), 16)
  const b = Number.parseInt(cleaned.slice(4, 6), 16)
  return 0.299 * r + 0.587 * g + 0.114 * b
}

export default function CrispColorSwatches({
  items = [],
  value = null,
  size = 26,
  className = '',
  ariaLabel = '颜色选择',
  onSelect,
  onHoverItem,
}) {
  return (
    <div
      role="radiogroup"
      aria-label={ariaLabel}
      className={`flex flex-wrap items-center gap-2.5 ${className}`}
    >
      {items.map(item => {
        const selected = String(value || '').toLowerCase() === String(item.value || '').toLowerCase()
        const lum = parseHexLuminance(item.color)
        const baseEdgeShadow = lum > 185
          ? 'inset 0 0 0 1px rgba(15, 23, 42, 0.16)'
          : lum < 42
            ? 'inset 0 0 0 1px rgba(255, 255, 255, 0.28)'
            : 'inset 0 0 0 1px rgba(0, 0, 0, 0.08)'
        const ringTone = lum > 210 || lum < 36 ? 'var(--color-primary)' : item.color
        const boxShadow = selected
          ? `${baseEdgeShadow}, 0 0 0 2px var(--color-base-100), 0 0 0 4px ${ringTone}`
          : baseEdgeShadow

        return (
          <button
            key={item.value}
            type="button"
            role="radio"
            aria-checked={selected}
            aria-label={item.label || item.color}
            onClick={() => onSelect?.(item.value, item)}
            onMouseEnter={() => onHoverItem?.(item.value)}
            onMouseLeave={() => onHoverItem?.(null)}
            style={{
              width: size,
              height: size,
              backgroundColor: item.color,
              boxShadow,
            }}
            className="inline-flex shrink-0 cursor-pointer items-center justify-center rounded-full border-0 p-0 transition-transform duration-150 hover:scale-110 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary"
          />
        )
      })}
    </div>
  )
}
