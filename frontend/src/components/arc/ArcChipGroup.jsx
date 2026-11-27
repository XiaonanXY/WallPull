import { useEffect, useId, useLayoutEffect, useRef, useState } from 'react'
import { LayoutGroup, animate, motion, useMotionValue, useReducedMotion, useTransform } from 'motion/react'
import { arcMotion } from './arcMotion.js'
import './ArcChipGroup.css'

/** Width allocated to the animated checkmark glyph + gap inside a selected chip. */
const CHECK_SLOT = 17

/**
 * Adapted from arc-library chip-group.
 * Trails the visible pill edge smoothly on a spring while the layout width updates in one frame,
 * so neighbouring chips glide without snapping and the SVG check draws itself in step.
 */
function useWidthLag(nodeRef, key, reduce) {
  const lag = useMotionValue(0)
  const widthRef = useRef(null)

  useLayoutEffect(() => {
    const element = nodeRef.current
    if (!element) return
    const next = element.offsetWidth
    const previous = widthRef.current
    widthRef.current = next
    if (previous === null || previous === next) return
    if (reduce) {
      lag.jump(0)
      return
    }
    const velocity = lag.getVelocity()
    lag.jump(lag.get() + previous - next)
    animate(lag, 0, { ...arcMotion.spring.morph, velocity })
  }, [key, lag, nodeRef, reduce])

  useEffect(() => {
    const element = nodeRef.current
    if (!element || typeof ResizeObserver === 'undefined') return undefined
    const observer = new ResizeObserver(() => {
      widthRef.current = element.offsetWidth
    })
    observer.observe(element)
    return () => observer.disconnect()
  }, [nodeRef])

  return lag
}

function ArcChip({ option, selected, tabbable, reduce, fullWidth, onSelect, onFocusChip }) {
  const bodyRef = useRef(null)
  const lag = useWidthLag(bodyRef, String(selected), reduce || fullWidth)
  const slotRef = useRef(selected ? CHECK_SLOT : 0)
  const grown = useMotionValue(selected ? 1 : 0)
  const edge = useTransform(lag, value => -value)
  const checkScale = useTransform(grown, value => Math.min(value, 1.08))
  const checkOpacity = useTransform(grown, value => Math.min(1, value * 1.4))
  const checkDraw = useTransform(grown, value => Math.min(1, Math.max(0.001, value)))

  useLayoutEffect(() => {
    slotRef.current = selected ? CHECK_SLOT : 0
    if (fullWidth) {
      if (reduce) {
        grown.jump(selected ? 1 : 0)
        return undefined
      }
      const controls = animate(grown, selected ? 1 : 0, arcMotion.spring.snappy)
      return () => controls.stop()
    }
    const update = () => {
      grown.set(Math.max(0, (slotRef.current + lag.get()) / CHECK_SLOT))
    }
    update()
    return lag.on('change', update)
  }, [fullWidth, grown, lag, reduce, selected])

  return (
    <motion.button
      type="button"
      className={`arc-chip ${fullWidth ? 'arc-chip--grid' : ''}`.trim()}
      data-arc-chip={option.value}
      aria-pressed={selected}
      tabIndex={tabbable ? 0 : -1}
      onClick={() => onSelect(option.value)}
      onFocus={() => onFocusChip(option.value)}
      layout={fullWidth ? undefined : 'position'}
      transition={fullWidth ? undefined : { layout: reduce ? { duration: 0 } : arcMotion.spring.morph }}
    >
      <span ref={bodyRef} className="arc-chip__body" data-selected={selected}>
        <motion.span
          className="arc-chip__surface"
          style={fullWidth ? undefined : { right: edge }}
          aria-hidden="true"
        />
        <span className="arc-chip__inner">
          {selected || !fullWidth ? (
            <motion.span
              className={`arc-chip__check ${fullWidth ? 'arc-chip__check--inline' : ''}`.trim()}
              style={{ scale: checkScale, opacity: checkOpacity }}
              aria-hidden="true"
            >
              <svg
                width="12"
                height="12"
                viewBox="0 0 24 24"
                fill="none"
                stroke="currentColor"
                strokeWidth="2.8"
                strokeLinecap="round"
                strokeLinejoin="round"
              >
                <motion.path d="M4.5 12.5 9.8 17.8 19.5 6.8" style={{ pathLength: checkDraw }} />
              </svg>
            </motion.span>
          ) : null}
          {!fullWidth ? <span className="arc-chip__slot" aria-hidden="true" /> : null}
          {option.icon && !selected ? (
            <span className="arc-chip__icon" aria-hidden="true">
              {option.icon}
            </span>
          ) : null}
          <motion.span className="arc-chip__label" style={fullWidth ? undefined : { x: lag }}>
            {option.label}
          </motion.span>
        </span>
      </span>
    </motion.button>
  )
}

export default function ArcChipGroup({
  options = [],
  value = '',
  onValueChange,
  label,
  fallbackValue = null,
  columns = 0,
  className = '',
}) {
  const id = useId()
  const reduce = Boolean(useReducedMotion())
  const [focused, setFocused] = useState(null)

  const keys = options.map(o => o.value)
  const tabStop = (focused && keys.includes(focused) ? focused : null) ??
    (keys.includes(value) ? value : keys[0] ?? null)

  const handleSelect = next => {
    if (next === value) {
      if (fallbackValue !== null && fallbackValue !== value) {
        onValueChange?.(fallbackValue)
      }
      return
    }
    onValueChange?.(next)
  }

  const handleKeyDown = event => {
    const buttons = Array.from(
      event.currentTarget.querySelectorAll('button[data-arc-chip]'),
    )
    const index = buttons.indexOf(document.activeElement)
    if (index < 0) return
    const last = buttons.length - 1
    const moves = {
      ArrowRight: index === last ? 0 : index + 1,
      ArrowDown: index === last ? 0 : index + 1,
      ArrowLeft: index === 0 ? last : index - 1,
      ArrowUp: index === 0 ? last : index - 1,
      Home: 0,
      End: last,
    }
    if (!(event.key in moves)) return
    event.preventDefault()
    buttons[moves[event.key]]?.focus({ preventScroll: true })
  }

  const isGrid = columns > 0
  return (
    <LayoutGroup id={id}>
      <div
        className={`arc-chip-group ${isGrid ? 'arc-chip-group--grid' : ''} ${className}`.trim()}
        style={isGrid ? { gridTemplateColumns: `repeat(${columns}, minmax(0, 1fr))` } : undefined}
        role="group"
        aria-label={label}
        onKeyDown={handleKeyDown}
      >
        {options.map(option => (
          <ArcChip
            key={option.value}
            option={option}
            selected={value === option.value}
            tabbable={tabStop === option.value}
            reduce={reduce}
            fullWidth={isGrid}
            onSelect={handleSelect}
            onFocusChip={setFocused}
          />
        ))}
      </div>
    </LayoutGroup>
  )
}
