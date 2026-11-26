import { useLayoutEffect, useRef, useState } from 'react'
import { animate, motion, useMotionValue, useReducedMotion, useTransform } from 'motion/react'
import { CaretLeft, CaretRight } from '@phosphor-icons/react'

const clamp = (val, low, high) => Math.min(high, Math.max(low, val))
const rubber = (dist, limit = 9) => Math.sign(dist) * (1 - 1 / (Math.abs(dist) * 0.55 / limit + 1)) * limit
const moveSpring = { type: 'spring', stiffness: 460, damping: 34, restDelta: 0.01, restSpeed: 0.05 }

export default function ImageCompareSlider({
  beforeSrc,
  afterSrc,
  beforeLabel = '保留最优',
  afterLabel = '候选副本',
  defaultPosition = 50,
  aspectRatio = '16 / 9',
  canvasRatio = null,
  fitContainer = false,
  surfaceClassName = 'border-base-300/80 bg-black/85',
  className = '',
}) {
  const reduced = useReducedMotion()
  const stageWrapRef = useRef(null)
  const rootRef = useRef(null)
  const handleRef = useRef(null)
  const dragRef = useRef(null)
  const pressedHandleRef = useRef(false)
  const [percent, setPercent] = useState(defaultPosition)
  const [dragging, setDragging] = useState(false)
  const [boxWidth, setBoxWidth] = useState(600)
  const [wrapSize, setWrapSize] = useState({ width: 0, height: 0 })

  const pos = useMotionValue(defaultPosition)
  const lag = useMotionValue(0)
  const shown = useTransform(() => clamp(pos.get() + lag.get(), -3, 103))
  const clipPath = useTransform(() => {
    const p = clamp(shown.get(), 0, 100)
    return `inset(0 ${(100 - p).toFixed(3)}% 0 0)`
  })
  const pivotLeft = useTransform(() => `${clamp(shown.get(), 0, 100).toFixed(3)}%`)
  const handleLeft = useTransform(() => {
    const w = Math.max(120, boxWidth)
    const rawPx = (clamp(shown.get(), 0, 100) / 100) * w
    const inset = dragging ? 26 : 20
    return `${clamp(rawPx, inset, Math.max(inset, w - inset)).toFixed(2)}px`
  })
  const beforeOpacity = useTransform(() => clamp((clamp(shown.get(), 0, 100) / 100 * boxWidth - 96) / 28, 0, 1))
  const afterOpacity = useTransform(() => clamp((boxWidth - 96 - clamp(shown.get(), 0, 100) / 100 * boxWidth) / 28, 0, 1))

  useLayoutEffect(() => {
    const root = rootRef.current
    if (!root || typeof ResizeObserver === 'undefined') return undefined
    const measure = () => setBoxWidth(root.clientWidth || 600)
    const observer = new ResizeObserver(measure)
    observer.observe(root)
    measure()
    return () => observer.disconnect()
  }, [fitContainer, wrapSize.width, wrapSize.height])

  useLayoutEffect(() => {
    if (!fitContainer) return undefined
    const wrap = stageWrapRef.current
    if (!wrap || typeof ResizeObserver === 'undefined') return undefined
    const measure = () => setWrapSize({ width: wrap.clientWidth || 0, height: wrap.clientHeight || 0 })
    const observer = new ResizeObserver(measure)
    observer.observe(wrap)
    measure()
    return () => observer.disconnect()
  }, [fitContainer])

  const percentAt = clientX => {
    const rect = rootRef.current?.getBoundingClientRect()
    if (!rect || !rect.width) return 50
    return ((clientX - rect.left) / rect.width) * 100
  }

  const commit = next => {
    const clamped = Number(clamp(next, 0, 100).toFixed(2))
    setPercent(Math.round(clamped))
    return clamped
  }

  const follow = (state, at, first = false) => {
    const width = rootRef.current?.clientWidth || 600
    const raw = at - state.grab
    const edge = clamp(raw, 0, 100)
    const placed = reduced ? edge : edge + (rubber(((raw - edge) / 100) * width) / width) * 100
    state.raw = raw
    if (first && state.press && !reduced) {
      const from = pos.get()
      pos.jump(placed)
      lag.jump(from - placed)
      animate(lag, 0, moveSpring)
    } else {
      pos.set(placed)
    }
    commit(edge)
  }

  const onPointerDown = event => {
    if (event.button !== 0 || !event.isPrimary || !rootRef.current) return
    event.stopPropagation()
    const onHandle = Boolean(event.target.closest?.('[data-compare-handle]'))
    pressedHandleRef.current = onHandle
    try {
      event.currentTarget.setPointerCapture(event.pointerId)
    } catch {
      // ignore
    }
    const at = percentAt(event.clientX)
    const from = pos.get() + lag.get()
    const state = {
      pointer: event.pointerId,
      grab: onHandle ? at - from : 0,
      press: !onHandle,
      started: true,
      raw: at,
    }
    lag.jump(0)
    pos.jump(from)
    dragRef.current = state
    setDragging(true)
    follow(state, at, true)
  }

  const onPointerMove = event => {
    const state = dragRef.current
    if (!state || state.pointer !== event.pointerId) return
    event.stopPropagation()
    follow(state, percentAt(event.clientX))
  }

  const onPointerEnd = event => {
    const state = dragRef.current
    if (!state || state.pointer !== event.pointerId) return
    event.stopPropagation()
    dragRef.current = null
    setDragging(false)
    const from = pos.get() + lag.get()
    const target = clamp(lag.get() !== 0 ? state.raw : from, 0, 100)
    lag.jump(0)
    pos.jump(from)
    if (reduced) pos.jump(target)
    else animate(pos, target, moveSpring)
    commit(target)
  }

  const jumpTo = next => {
    const clamped = commit(next)
    lag.jump(0)
    if (reduced) pos.jump(clamped)
    else animate(pos, clamped, moveSpring)
  }

  const onKeyDown = event => {
    const step = event.shiftKey ? 10 : 1
    if (event.key === 'ArrowLeft') {
      event.preventDefault()
      jumpTo(percent - step)
    } else if (event.key === 'ArrowRight') {
      event.preventDefault()
      jumpTo(percent + step)
    } else if (event.key === 'Home') {
      event.preventDefault()
      jumpTo(100)
    } else if (event.key === 'End') {
      event.preventDefault()
      jumpTo(0)
    }
  }

  const numericRatio = Number.isFinite(canvasRatio) && canvasRatio > 0 ? canvasRatio : 16 / 9
  const fittedStyle = (() => {
    if (!fitContainer) return { aspectRatio }
    if (wrapSize.width <= 0 || wrapSize.height <= 0) {
      return { width: '100%', height: '100%' }
    }
    if (wrapSize.width / wrapSize.height > numericRatio) {
      const h = Math.max(120, Math.floor(wrapSize.height))
      const w = Math.max(120, Math.floor(h * numericRatio))
      return { width: `${w}px`, height: `${h}px` }
    }
    const w = Math.max(120, Math.floor(wrapSize.width))
    const h = Math.max(90, Math.floor(w / numericRatio))
    return { width: `${w}px`, height: `${h}px` }
  })()

  const frameNode = (
    <div
      ref={rootRef}
      style={fittedStyle}
      onPointerDown={onPointerDown}
      onPointerMove={onPointerMove}
      onPointerUp={onPointerEnd}
      onPointerCancel={onPointerEnd}
      onLostPointerCapture={onPointerEnd}
      onMouseDown={e => {
        e.preventDefault()
        e.stopPropagation()
      }}
      onDragStart={e => e.preventDefault()}
      onDoubleClick={e => {
        e.stopPropagation()
        if (pressedHandleRef.current) jumpTo(50)
      }}
      className={`wp-compare-frame relative ${fitContainer ? '' : 'w-full'} touch-none overflow-hidden rounded-2xl border select-none cursor-ew-resize ${surfaceClassName} ${className}`}
    >
      <img src={afterSrc} alt={afterLabel} draggable={false} className="absolute inset-0 h-full w-full object-contain" />
      <motion.div className="absolute inset-0" style={{ clipPath }}>
        <img src={beforeSrc} alt={beforeLabel} draggable={false} className="h-full w-full object-contain" />
      </motion.div>

      <motion.span
        style={{ opacity: beforeOpacity }}
        className="pointer-events-none absolute top-3 left-3 rounded-full bg-emerald-600/90 px-2.5 py-1 text-[11px] font-semibold text-white shadow backdrop-blur-md"
      >
        {beforeLabel}
      </motion.span>
      <motion.span
        style={{ opacity: afterOpacity }}
        className="pointer-events-none absolute top-3 right-3 rounded-full bg-black/72 px-2.5 py-1 text-[11px] font-semibold text-white shadow backdrop-blur-md"
      >
        {afterLabel}
      </motion.span>

      <motion.div
        style={{ left: pivotLeft }}
        className="pointer-events-none absolute inset-y-0 -translate-x-1/2"
      >
        <div className="h-full w-0.5 bg-white/90 shadow-[0_0_8px_rgba(0,0,0,0.65)]" />
      </motion.div>

      <motion.div
        ref={handleRef}
        data-compare-handle=""
        role="slider"
        tabIndex={0}
        aria-label="左右对比滑块"
        aria-valuemin={0}
        aria-valuemax={100}
        aria-valuenow={percent}
        onKeyDown={onKeyDown}
        style={{ left: handleLeft }}
        animate={{ width: dragging ? 48 : 36, height: dragging ? 32 : 36 }}
        transition={reduced ? { duration: 0 } : { type: 'spring', stiffness: 450, damping: 28 }}
        className="pointer-events-auto absolute top-1/2 flex -translate-x-1/2 -translate-y-1/2 items-center justify-center gap-0.5 rounded-full border border-white/35 bg-black/75 text-white shadow-lg backdrop-blur-md outline-none focus-visible:ring-2 focus-visible:ring-primary"
      >
        <CaretLeft size={13} weight="bold" />
        <CaretRight size={13} weight="bold" />
      </motion.div>
    </div>
  )

  if (fitContainer) {
    return (
      <div ref={stageWrapRef} className="flex h-full w-full items-center justify-center overflow-hidden">
        {frameNode}
      </div>
    )
  }

  return frameNode
}
