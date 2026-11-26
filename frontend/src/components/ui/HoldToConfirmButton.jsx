import { useEffect, useRef, useState } from 'react'
import { animate, motion, useMotionValue, useReducedMotion, useTransform } from 'motion/react'
import { Check, Trash } from '@phosphor-icons/react'

export default function HoldToConfirmButton({
  label,
  confirmedLabel = '已完成',
  onConfirm,
  duration = 850,
  icon = <Trash size={14} weight="bold" />,
  tone = 'danger',
  disabled = false,
  className = '',
}) {
  const reduced = useReducedMotion()
  const [holding, setHolding] = useState(false)
  const [done, setDone] = useState(false)
  const progress = useMotionValue(0)
  const scale = useMotionValue(1)
  const clipPath = useTransform(progress, v => `inset(0 ${((1 - Math.min(1, Math.max(0, v))) * 100).toFixed(2)}% 0 0)`)
  const fillAnimRef = useRef(null)
  const pressAnimRef = useRef(null)
  const sourceRef = useRef(null)

  useEffect(() => {
    setDone(false)
    setHolding(false)
    sourceRef.current = null
    fillAnimRef.current?.stop()
    progress.jump(0)
  }, [disabled, label, progress])

  useEffect(() => () => {
    fillAnimRef.current?.stop()
    pressAnimRef.current?.stop()
  }, [])

  const setPressScale = pressed => {
    pressAnimRef.current?.stop()
    if (reduced) {
      scale.jump(1)
      return
    }
    pressAnimRef.current = animate(scale, pressed ? 0.965 : 1, { type: 'spring', stiffness: 480, damping: 30 })
  }

  const rewind = () => {
    fillAnimRef.current?.stop()
    if (reduced) progress.jump(0)
    else fillAnimRef.current = animate(progress, 0, { type: 'spring', stiffness: 320, damping: 28 })
  }

  const finishHold = () => {
    if (!sourceRef.current) return
    sourceRef.current = null
    setHolding(false)
    setPressScale(false)
    setDone(true)
    onConfirm?.()
  }

  const beginHold = src => {
    if (done || disabled || sourceRef.current) return
    sourceRef.current = src
    setHolding(true)
    setPressScale(true)
    fillAnimRef.current?.stop()
    const remainingSec = Math.max(0.08, (1 - progress.get()) * (duration / 1000))
    fillAnimRef.current = animate(progress, 1, {
      duration: remainingSec,
      ease: 'linear',
      onComplete: finishHold,
    })
  }

  const releaseHold = () => {
    if (!sourceRef.current) return
    sourceRef.current = null
    setHolding(false)
    setPressScale(false)
    rewind()
  }

  const text = done ? confirmedLabel : label
  const activeIcon = done ? <Check size={14} weight="bold" /> : icon
  const toneSurface = tone === 'danger'
    ? 'border-error/45 bg-error/10 text-error'
    : 'border-primary/45 bg-primary/10 text-primary'
  const toneFill = tone === 'danger' ? 'bg-error text-white' : 'bg-primary text-primary-content'

  return (
    <motion.button
      type="button"
      disabled={disabled}
      aria-label={text}
      style={{ scale }}
      onPointerDown={event => {
        if (!event.isPrimary || event.button !== 0 || disabled) return
        try {
          event.currentTarget.setPointerCapture(event.pointerId)
        } catch {
          // ignore
        }
        beginHold('pointer')
      }}
      onPointerMove={event => {
        if (sourceRef.current !== 'pointer') return
        const box = event.currentTarget.getBoundingClientRect()
        const slack = 22
        if (
          event.clientX < box.left - slack ||
          event.clientX > box.right + slack ||
          event.clientY < box.top - slack ||
          event.clientY > box.bottom + slack
        ) {
          releaseHold()
        }
      }}
      onPointerUp={releaseHold}
      onPointerCancel={releaseHold}
      onLostPointerCapture={releaseHold}
      onKeyDown={event => {
        if (event.key !== ' ') return
        event.preventDefault()
        if (!event.repeat) beginHold('key')
      }}
      onKeyUp={event => {
        if (event.key !== ' ') return
        event.preventDefault()
        if (sourceRef.current === 'key') releaseHold()
      }}
      onBlur={releaseHold}
      onContextMenu={event => event.preventDefault()}
      className={`wp-hold-btn relative inline-flex h-8.5 items-center justify-center overflow-hidden rounded-full border px-3.5 text-xs font-semibold transition-colors select-none cursor-pointer disabled:cursor-not-allowed disabled:opacity-45 ${toneSurface} ${holding ? 'ring-2 ring-error/25' : ''} ${className}`}
    >
      <span className="relative z-0 inline-flex items-center gap-1.5 whitespace-nowrap">
        {activeIcon}
        <span>{text}</span>
      </span>
      <motion.span
        aria-hidden="true"
        style={{ clipPath }}
        className={`pointer-events-none absolute inset-0 z-10 inline-flex items-center justify-center gap-1.5 whitespace-nowrap ${toneFill}`}
      >
        {activeIcon}
        <span>{text}</span>
      </motion.span>
    </motion.button>
  )
}
