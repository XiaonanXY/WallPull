import { useId } from 'react'
import { motion, useReducedMotion } from 'motion/react'

export default function AnimatedPillGroup({
  options = [],
  value,
  onChange,
  ariaLabel,
  className = '',
}) {
  const pillId = useId()
  const reduced = useReducedMotion()

  return (
    <div
      role="group"
      aria-label={ariaLabel}
      className={`inline-flex items-center gap-0.5 rounded-full border border-base-300/90 bg-base-200/60 p-0.5 ${className}`}
    >
      {options.map(opt => {
        const active = opt.value === value
        return (
          <button
            key={opt.value}
            type="button"
            onClick={() => onChange?.(opt.value)}
            className={`relative h-7 rounded-full px-3 text-xs font-semibold transition-colors cursor-pointer ${
              active ? 'text-primary-content' : 'text-base-content/70 hover:text-base-content'
            }`}
          >
            {active ? (
              <motion.span
                layoutId={`animated-pill-${pillId}`}
                transition={reduced ? { duration: 0 } : { type: 'spring', stiffness: 480, damping: 34 }}
                className="absolute inset-0 rounded-full bg-primary shadow-xs"
              />
            ) : null}
            <span className="relative z-10 whitespace-nowrap">{opt.label}</span>
          </button>
        )
      })}
    </div>
  )
}
