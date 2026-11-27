import { useId, useRef } from 'react'
import { LayoutGroup, motion, useReducedMotion } from 'motion/react'
import { arcMotion } from './arcMotion.js'
import './ArcSegmentedControl.css'

/**
 * Adapted from arc-library segmented-control.
 * Matches WallPull's sunken frosted capsule track + gliding spring pill with theme-aware active ink.
 */
export default function ArcSegmentedControl({
  options = [],
  value,
  onValueChange,
  label,
  className = '',
}) {
  const id = useId()
  const reduced = Boolean(useReducedMotion())
  const trackRef = useRef(null)

  const selectedIndex = Math.max(0, options.findIndex(option => option.value === value))

  const handleKeyDown = event => {
    const last = options.length - 1
    if (last < 0) return
    const target =
      event.key === 'ArrowRight' || event.key === 'ArrowDown'
        ? (selectedIndex === last ? 0 : selectedIndex + 1)
        : event.key === 'ArrowLeft' || event.key === 'ArrowUp'
          ? (selectedIndex === 0 ? last : selectedIndex - 1)
          : event.key === 'Home'
            ? 0
            : event.key === 'End'
              ? last
              : -1
    if (target < 0 || !options[target]) return
    event.preventDefault()
    const nextValue = options[target].value
    onValueChange?.(nextValue)
    const buttons = trackRef.current?.querySelectorAll('button[data-arc-segment]')
    buttons?.[target]?.focus({ preventScroll: true })
  }

  return (
    <div
      className={`arc-segmented ${className}`.trim()}
      role="radiogroup"
      aria-label={label}
    >
      <LayoutGroup id={id}>
        <div ref={trackRef} className="arc-segmented__track">
          {options.map((option, index) => {
            const active = value === option.value
            return (
              <button
                key={option.value}
                type="button"
                role="radio"
                data-arc-segment=""
                data-value={option.value}
                aria-checked={active}
                tabIndex={index === selectedIndex ? 0 : -1}
                className="arc-segmented__button"
                onClick={() => onValueChange?.(option.value)}
                onKeyDown={handleKeyDown}
              >
                {active ? (
                  <motion.span
                    className="arc-segmented__selection"
                    layoutId="arc-seg-selection"
                    transition={reduced ? { duration: 0 } : arcMotion.spring.morph}
                    aria-hidden="true"
                  />
                ) : null}
                <span className="arc-segmented__label">
                  {option.label}
                </span>
              </button>
            )
          })}
        </div>
      </LayoutGroup>
    </div>
  )
}
