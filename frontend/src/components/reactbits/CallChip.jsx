import { useCallback, useEffect, useLayoutEffect, useRef, useState } from 'react'
import {
  ArrowsClockwise,
  Check,
  File,
  MagnifyingGlass,
  PencilSimple,
  Sparkle,
  TerminalWindow,
} from '@phosphor-icons/react'
import './CallChip.css'

const HOLD_AT = 0.9
const SHAKE = [0, -1, 1, -0.66, 0.66, -0.33, 0]
const WORDS = { running: 'running', done: 'done', error: 'failed', idle: 'queued' }

const fmt = ms => (ms < 10000 ? `${Math.round(ms)} ms` : `${(ms / 1000).toFixed(1)} s`)
const reduceMotion = () => globalThis.matchMedia?.('(prefers-reduced-motion: reduce)').matches ?? false
const glyphOf = s => (s === 'done' ? 'check' : s === 'error' ? 'retry' : 'tool')

export default function CallChip({
  icon = 'sparkle',
  name = 'WallPull',
  argument = '',
  status = 'done',
  expectedMs = 2200,
  size = 38,
  radius = 999,
  color = 'currentColor',
  surfaceColor = '#27272a',
  progressColor = 'currentColor',
  progressOpacity = 0.08,
  doneColor = '#22c55e',
  errorColor = '#ef4444',
  washOpacity = 0.16,
  shake = 6,
  showTimer = false,
  actionLabel = null,
  onAction = null,
  onRetry = null,
  className = '',
  style,
}) {
  const rootRef = useRef(null)
  const fillRef = useRef(null)
  const timerRef = useRef(null)
  const mountedRef = useRef(false)
  const fraction = useRef(0)
  const clock = useRef({ ms: 0 })
  const shakeAnim = useRef(null)
  const statusRef = useRef(status)
  statusRef.current = status
  const [mounted, setMounted] = useState(false)
  const [pressed, setPressed] = useState(false)
  const [announce, setAnnounce] = useState('')
  const roll = useRef({ cur: glyphOf(status), prev: null })
  if (glyphOf(status) !== roll.current.cur) {
    roll.current = { cur: glyphOf(status), prev: roll.current.cur }
  }

  const setFraction = useCallback((f, instant) => {
    const fill = fillRef.current
    if (!fill) return
    fraction.current = f
    if (instant) fill.style.transition = 'none'
    fill.style.transform = `scaleX(${f})`
    if (instant) {
      void fill.getBoundingClientRect()
      fill.style.transition = ''
    }
  }, [])

  const apply = useCallback((s, animateChange) => {
    if (s === 'running') {
      shakeAnim.current?.cancel()
      setFraction(0, true)
      if (animateChange) setFraction(HOLD_AT, false)
    } else if (s === 'done') {
      setFraction(1, !animateChange)
    } else if (s === 'error') {
      const fill = fillRef.current
      const live = fill ? new DOMMatrix(getComputedStyle(fill).transform).a : fraction.current
      setFraction(Math.min(1, Math.max(0, live)), true)
      if (animateChange && shake > 0 && !reduceMotion() && rootRef.current) {
        shakeAnim.current = rootRef.current.animate(
          SHAKE.map(k => ({
            transform: `translateX(${k * shake}px)`,
            easing: 'cubic-bezier(0.77, 0, 0.175, 1)',
          })),
          { duration: 450, composite: 'add' },
        )
      }
    } else {
      setFraction(0, true)
    }
  }, [setFraction, shake])

  useEffect(() => {
    mountedRef.current = true
    setMounted(true)
    apply(statusRef.current, statusRef.current === 'running')
    return () => {
      mountedRef.current = false
      shakeAnim.current?.cancel()
    }
  }, [apply])

  useLayoutEffect(() => {
    if (mountedRef.current) apply(status, true)
  }, [apply, status])

  useEffect(() => {
    const write = ms => {
      clock.current.ms = ms
      if (timerRef.current) timerRef.current.textContent = fmt(ms)
    }
    if (status !== 'running') {
      if ((status === 'idle' || !clock.current.ms) && timerRef.current) timerRef.current.textContent = '—'
      return undefined
    }
    const startedAt = performance.now()
    write(0)
    if (reduceMotion()) {
      const id = globalThis.setInterval(() => write(performance.now() - startedAt), 100)
      return () => {
        globalThis.clearInterval(id)
        write(performance.now() - startedAt)
      }
    }
    let raf = 0
    const tick = () => {
      write(performance.now() - startedAt)
      raf = requestAnimationFrame(tick)
    }
    tick()
    return () => {
      cancelAnimationFrame(raf)
      write(performance.now() - startedAt)
    }
  }, [status])

  useEffect(() => {
    const ms = showTimer && clock.current.ms ? Math.round(clock.current.ms) : 0
    const when = status === 'done' && ms ? ` in ${ms} ms` : status === 'error' && ms ? ` after ${ms} ms` : ''
    setAnnounce(`${name} ${argument}, ${WORDS[status] ?? status}${when}`)
  }, [argument, name, showTimer, status])

  const font = Math.max(12, Math.round(size * 0.36))
  const glyphState = g => (g === roll.current.cur ? 'in' : g === roll.current.prev ? 'out' : undefined)
  const iconSize = font + 2

  const renderToolIcon = () => {
    if (typeof icon !== 'string') return icon
    if (icon === 'terminal') return <TerminalWindow size={iconSize} weight="bold" />
    if (icon === 'file') return <File size={iconSize} weight="bold" />
    if (icon === 'search') return <MagnifyingGlass size={iconSize} weight="bold" />
    if (icon === 'edit') return <PencilSimple size={iconSize} weight="bold" />
    return <Sparkle size={iconSize} weight="fill" />
  }

  return (
    <span
      ref={rootRef}
      role="status"
      aria-busy={status === 'running' || undefined}
      data-status={status}
      data-mounted={mounted ? '' : undefined}
      data-pressed={pressed ? '' : undefined}
      className={`call-chip${className ? ` ${className}` : ''}`}
      style={{
        '--cc-size': `${size}px`,
        '--cc-font': `${font}px`,
        '--cc-pad': `${Math.round(size * 0.38)}px`,
        '--cc-gap': `${Math.round(font * 0.6)}px`,
        '--cc-radius': `${radius}px`,
        '--cc-color': color,
        '--cc-surface': surfaceColor,
        '--cc-progress': progressColor,
        '--cc-progress-pct': `${progressOpacity * 100}%`,
        '--cc-done': doneColor,
        '--cc-error': errorColor,
        '--cc-wash-pct': `${washOpacity * 100}%`,
        '--cc-expected': `${expectedMs}ms`,
        ...style,
      }}
    >
      <span ref={fillRef} className="call-chip__fill" aria-hidden="true" />
      <span className="call-chip__slot" aria-hidden="true">
        <span className="call-chip__glyph" data-state={glyphState('tool')}>
          {renderToolIcon()}
        </span>
        <span className="call-chip__glyph" data-state={glyphState('check')}>
          <Check size={iconSize} weight="bold" />
        </span>
        <span className="call-chip__glyph" data-state={glyphState('retry')}>
          <ArrowsClockwise size={iconSize} weight="bold" />
        </span>
      </span>
      {name ? (
        <span className="call-chip__name" aria-hidden="true">
          {name}
        </span>
      ) : null}
      {argument ? (
        <span className="call-chip__arg" aria-hidden="true">
          {argument}
        </span>
      ) : null}
      {showTimer ? (
        <span ref={timerRef} className="call-chip__timer" aria-hidden="true">
          0 ms
        </span>
      ) : null}
      {actionLabel && onAction ? (
        <button
          type="button"
          className="call-chip__action"
          onClick={event => {
            event.stopPropagation()
            onAction()
          }}
        >
          {actionLabel}
        </button>
      ) : null}
      {status === 'error' && onRetry ? (
        <button
          type="button"
          className="call-chip__retry"
          aria-label={`重试 ${name} ${argument}`}
          onClick={() => onRetry()}
          onPointerDown={() => setPressed(true)}
          onPointerUp={() => setPressed(false)}
          onPointerCancel={() => setPressed(false)}
        />
      ) : null}
      <span className="call-chip__sr">{announce}</span>
    </span>
  )
}
