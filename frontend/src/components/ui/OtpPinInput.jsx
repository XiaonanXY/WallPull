import { useEffect, useId, useRef, useState } from 'react'
import { AnimatePresence, motion, useAnimate, useReducedMotion } from 'motion/react'

export default function OtpPinInput({
  length = 4,
  value = '',
  onChange,
  onComplete,
  error = '',
  autoFocus = true,
  disabled = false,
  label = '配对码',
  className = '',
}) {
  const generatedId = useId()
  const reduced = useReducedMotion()
  const [scope, animate] = useAnimate()
  const inputRefs = useRef([])
  const lastErrorRef = useRef(error)
  const completedRef = useRef('')
  const [ring, setRing] = useState({ x: 0, width: 0, shown: false, glide: false })

  const values = Array.from({ length }, (_, idx) => value[idx] ?? '')
  const focusAt = idx => {
    inputRefs.current[Math.max(0, Math.min(idx, length - 1))]?.focus()
  }
  const sanitize = next => String(next ?? '').replace(/\D/g, '')

  useEffect(() => {
    if (autoFocus) {
      const id = globalThis.requestAnimationFrame(() => inputRefs.current[0]?.focus())
      return () => globalThis.cancelAnimationFrame(id)
    }
    return undefined
  }, [autoFocus])

  useEffect(() => {
    const row = scope.current
    if (!row || typeof ResizeObserver === 'undefined') return undefined
    const observer = new ResizeObserver(() => {
      const slot = row.contains(document.activeElement) ? document.activeElement?.parentElement : null
      if (slot) {
        setRing(curr => (curr.x === slot.offsetLeft && curr.width === slot.offsetWidth
          ? curr
          : { ...curr, x: slot.offsetLeft, width: slot.offsetWidth, glide: false }))
      }
    })
    observer.observe(row)
    return () => observer.disconnect()
  }, [scope])

  useEffect(() => {
    if (error && error !== lastErrorRef.current && !reduced && scope.current) {
      animate(scope.current, { x: [0, -7, 6, -4, 3, 0] }, { duration: 0.34, ease: [0.22, 1, 0.36, 1] })
    }
    lastErrorRef.current = error
  }, [animate, error, reduced, scope])

  useEffect(() => {
    if (value.length === length && value !== completedRef.current) {
      completedRef.current = value
      onComplete?.(value)
    } else if (value.length < length) {
      completedRef.current = ''
    }
  }, [length, onComplete, value])

  const emitJoined = arr => {
    onChange?.(arr.join('').slice(0, length))
  }

  const handleChange = (idx, event) => {
    const raw = sanitize(event.target.value)
    if (raw.length <= 1) {
      const clean = raw.slice(-1)
      const next = values.slice()
      next[idx] = clean
      emitJoined(next)
      if (clean && idx < length - 1) focusAt(idx + 1)
      return
    }
    const next = values.slice()
    raw.slice(0, length - idx).split('').forEach((ch, offset) => {
      next[idx + offset] = ch
    })
    emitJoined(next)
    focusAt(Math.min(idx + raw.length, length - 1))
  }

  const handlePaste = (idx, event) => {
    event.preventDefault()
    const pasted = sanitize(event.clipboardData?.getData('text')).slice(0, length - idx)
    if (!pasted) return
    const next = values.slice()
    pasted.split('').forEach((ch, offset) => {
      next[idx + offset] = ch
    })
    emitJoined(next)
    focusAt(Math.min(idx + pasted.length, length - 1))
  }

  const handleKeyDown = (idx, event) => {
    if (event.key === 'ArrowLeft') {
      event.preventDefault()
      focusAt(idx - 1)
    } else if (event.key === 'ArrowRight') {
      event.preventDefault()
      focusAt(idx + 1)
    } else if (event.key === 'Backspace' && !values[idx] && idx > 0) {
      event.preventDefault()
      const next = values.slice()
      next[idx - 1] = ''
      emitJoined(next)
      focusAt(idx - 1)
    } else if (event.key === 'Delete' && values[idx]) {
      const next = values.slice()
      next[idx] = ''
      emitJoined(next)
    }
  }

  const handleFocus = event => {
    event.currentTarget.select?.()
    const slot = event.currentTarget.parentElement
    if (!slot) return
    setRing(curr => ({
      x: slot.offsetLeft,
      width: slot.offsetWidth,
      shown: true,
      glide: curr.shown,
    }))
  }

  const handleBlur = event => {
    if (!scope.current?.contains(event.relatedTarget)) {
      setRing(curr => ({ ...curr, shown: false, glide: false }))
    }
  }

  return (
    <div className={`flex flex-col items-center ${className}`}>
      <div
        ref={scope}
        role="group"
        aria-label={label}
        data-invalid={error ? 'true' : undefined}
        className="relative flex items-center justify-center gap-2.5"
      >
        {values.map((char, idx) => (
          <div
            key={`${generatedId}-${idx}`}
            className={`wp-otp-slot relative flex h-15 w-13 items-center justify-center rounded-2xl border transition-colors ${
              error
                ? 'border-error/75 bg-error/8'
                : char
                  ? 'border-primary/45 bg-base-200/70'
                  : 'border-base-300/90 bg-base-200/45'
            }`}
          >
            <input
              ref={node => { inputRefs.current[idx] = node }}
              type="text"
              inputMode="numeric"
              maxLength={1}
              autoComplete={idx === 0 ? 'one-time-code' : 'off'}
              aria-label={`${label} 第 ${idx + 1} 位`}
              aria-invalid={error ? true : undefined}
              value={char}
              disabled={disabled}
              onChange={event => handleChange(idx, event)}
              onPaste={event => handlePaste(idx, event)}
              onKeyDown={event => handleKeyDown(idx, event)}
              onFocus={handleFocus}
              onBlur={handleBlur}
              className="absolute inset-0 h-full w-full cursor-text bg-transparent text-center tabular-nums text-2xl font-bold text-transparent caret-primary outline-none"
            />
            <AnimatePresence initial={false}>
              {char ? (
                <motion.span
                  key={char}
                  aria-hidden="true"
                  initial={reduced ? { opacity: 0 } : { opacity: 0, y: '0.35em', filter: 'blur(3px)' }}
                  animate={{ opacity: 1, y: 0, filter: 'blur(0px)' }}
                  exit={reduced ? { opacity: 0 } : { opacity: 0, scale: 0.88, filter: 'blur(2px)' }}
                  transition={reduced ? { duration: 0.08 } : { duration: 0.18, ease: [0.22, 1, 0.36, 1] }}
                  className="pointer-events-none tabular-nums text-2xl font-bold text-base-content select-none"
                >
                  {char}
                </motion.span>
              ) : (
                <span aria-hidden="true" className="pointer-events-none h-1.5 w-1.5 rounded-full bg-base-content/20" />
              )}
            </AnimatePresence>
          </div>
        ))}
        <motion.span
          aria-hidden="true"
          initial={false}
          animate={{
            x: ring.x,
            width: ring.width,
            opacity: ring.shown ? 1 : 0,
            scale: ring.shown ? 1 : 0.94,
          }}
          transition={reduced
            ? { duration: 0 }
            : {
                x: ring.glide ? { type: 'spring', stiffness: 520, damping: 36 } : { duration: 0 },
                width: { duration: 0 },
                scale: { type: 'spring', stiffness: 460, damping: 32 },
                opacity: { duration: 0.14 },
              }}
          className="pointer-events-none absolute top-0 left-0 h-15 rounded-2xl ring-2 ring-primary ring-offset-1 ring-offset-base-100"
        />
      </div>
    </div>
  )
}
