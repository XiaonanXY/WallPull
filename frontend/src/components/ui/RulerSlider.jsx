import { useEffect, useRef, useState } from 'react'
import { animate, motion, useMotionValue, useReducedMotion, useTransform } from 'motion/react'
import RollingDigits from './RollingDigits.jsx'

const clamp = (v, lo, hi) => Math.min(hi, Math.max(lo, v))
const rubber = (dist, limit = 34) => Math.sign(dist) * (1 - 1 / (Math.abs(dist) * 0.55 / limit + 1)) * limit
const glideSpring = { type: 'spring', stiffness: 420, damping: 32 }

export default function RulerSlider({
  label = '缩放比例',
  value = 100,
  onChange,
  onCommit,
  min = 100,
  max = 400,
  step = 5,
  majorEvery = 5,
  spacing = 8,
  unit = '%',
  disabled = false,
  className = '',
}) {
  const reduced = useReducedMotion()
  const viewportRef = useRef(null)
  const dragRef = useRef(null)
  const animRef = useRef(null)
  const wheelTimerRef = useRef(null)
  const [dragging, setDragging] = useState(false)

  const perUnit = spacing / step
  const snap = raw => clamp(Math.round((raw - min) / step) * step + min, min, max)
  const snappedValue = snap(value)
  const latestRef = useRef(snappedValue)

  const pos = useMotionValue(snappedValue)
  const tapeX = useTransform(pos, at => -(at - min) * perUnit)

  useEffect(() => {
    if (snappedValue !== latestRef.current && !dragRef.current) {
      latestRef.current = snappedValue
      animRef.current?.stop()
      if (reduced) pos.jump(snappedValue)
      else animRef.current = animate(pos, snappedValue, glideSpring)
    }
  }, [pos, reduced, snappedValue])

  useEffect(() => () => {
    animRef.current?.stop()
    if (wheelTimerRef.current) globalThis.clearTimeout(wheelTimerRef.current)
  }, [])

  const emit = next => {
    if (next === latestRef.current) return
    latestRef.current = next
    onChange?.(next)
  }

  const glideTo = next => {
    const target = snap(next)
    animRef.current?.stop()
    emit(target)
    if (reduced) pos.jump(target)
    else animRef.current = animate(pos, target, glideSpring)
    onCommit?.(target)
  }

  const wheelHandlerRef = useRef(null)
  wheelHandlerRef.current = event => {
    event.stopPropagation()
    if (Math.abs(event.deltaX) <= Math.abs(event.deltaY)) return
    event.preventDefault()
    animRef.current?.stop()
    const next = clamp(pos.get() + event.deltaX / perUnit, min, max)
    pos.set(next)
    emit(snap(next))
    if (wheelTimerRef.current) globalThis.clearTimeout(wheelTimerRef.current)
    wheelTimerRef.current = globalThis.setTimeout(() => glideTo(pos.get()), 110)
  }

  useEffect(() => {
    const el = viewportRef.current
    if (!el || disabled) return undefined
    const onWheel = event => wheelHandlerRef.current?.(event)
    el.addEventListener('wheel', onWheel, { passive: false })
    return () => el.removeEventListener('wheel', onWheel)
  }, [disabled])

  const majors = []
  const majorStep = step * majorEvery
  for (let v = min; v <= max; v += majorStep) {
    majors.push(v)
  }

  return (
    <div className={`wp-ruler-root inline-flex items-center gap-2.5 rounded-full border border-base-300/80 bg-base-100/88 px-3 py-1 shadow-lg backdrop-blur-xl ${className}`}>
      <span className="shrink-0 text-[11px] font-medium text-base-content/60">{label}</span>
      <div
        ref={viewportRef}
        role="slider"
        tabIndex={disabled ? -1 : 0}
        aria-label={label}
        aria-valuemin={min}
        aria-valuemax={max}
        aria-valuenow={snappedValue}
        onPointerDown={event => {
          event.stopPropagation()
          if (disabled || event.button !== 0 || !event.isPrimary) return
          animRef.current?.stop()
          try {
            event.currentTarget.setPointerCapture(event.pointerId)
          } catch {
            // ignore
          }
          dragRef.current = { pointer: event.pointerId, x: event.clientX, from: pos.get(), moved: false }
        }}
        onDoubleClick={event => event.stopPropagation()}
        onPointerMove={event => {
          const state = dragRef.current
          if (!state || state.pointer !== event.pointerId) return
          const dx = event.clientX - state.x
          if (!state.moved && Math.abs(dx) < 3) return
          state.moved = true
          setDragging(true)
          const raw = state.from - dx / perUnit
          const edge = clamp(raw, min, max)
          const placed = reduced ? edge : edge + rubber((raw - edge) * perUnit) / perUnit
          pos.set(placed)
          emit(snap(edge))
        }}
        onPointerUp={event => {
          const state = dragRef.current
          if (!state || state.pointer !== event.pointerId) return
          dragRef.current = null
          setDragging(false)
          if (!state.moved) {
            const rect = viewportRef.current?.getBoundingClientRect()
            if (rect) {
              const offsetVal = (event.clientX - (rect.left + rect.width / 2)) / perUnit
              glideTo(pos.get() + offsetVal)
            }
            return
          }
          glideTo(pos.get())
        }}
        onPointerCancel={() => {
          dragRef.current = null
          setDragging(false)
          glideTo(pos.get())
        }}
        onKeyDown={event => {
          if (disabled) return
          if (event.key === 'ArrowRight' || event.key === 'ArrowUp') {
            event.preventDefault()
            glideTo(latestRef.current + (event.shiftKey ? majorStep : step))
          } else if (event.key === 'ArrowLeft' || event.key === 'ArrowDown') {
            event.preventDefault()
            glideTo(latestRef.current - (event.shiftKey ? majorStep : step))
          } else if (event.key === 'Home') {
            event.preventDefault()
            glideTo(min)
          } else if (event.key === 'End') {
            event.preventDefault()
            glideTo(max)
          }
        }}
        className={`relative h-7 w-40 touch-none overflow-hidden outline-none select-none ${dragging ? 'cursor-grabbing' : 'cursor-grab'}`}
        style={{
          maskImage: 'linear-gradient(90deg, transparent 0%, black 18%, black 82%, transparent 100%)',
          WebkitMaskImage: 'linear-gradient(90deg, transparent 0%, black 18%, black 82%, transparent 100%)',
        }}
      >
        <motion.div
          style={{
            x: tapeX,
            width: (max - min) * perUnit + 1,
            left: '50%',
          }}
          className="wp-ruler-tape pointer-events-none absolute top-0 h-full"
        >
          <span
            className="absolute inset-x-0 bottom-0.5 h-2.5 opacity-45"
            style={{
              backgroundImage: `repeating-linear-gradient(90deg, currentColor 0 1px, transparent 1px ${spacing}px)`,
            }}
          />
          {majors.map(mark => (
            <span
              key={mark}
              style={{ left: (mark - min) * perUnit }}
              className="absolute bottom-0 flex -translate-x-1/2 flex-col items-center"
            >
              <span className="text-[9px] leading-none font-medium text-base-content/55 tabular-nums">{mark}</span>
              <span className="mt-0.5 h-3 w-[1.5px] bg-base-content/55" />
            </span>
          ))}
        </motion.div>
        <span
          aria-hidden="true"
          className="pointer-events-none absolute top-0 bottom-0 left-1/2 w-[2px] -translate-x-1/2 rounded-full bg-primary shadow-[0_0_6px_var(--color-primary)]"
        />
      </div>
      <span className="min-w-11 text-right text-xs font-bold text-primary">
        <RollingDigits value={`${snappedValue}${unit}`} />
      </span>
    </div>
  )
}
