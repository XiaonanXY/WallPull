import { AnimatePresence, motion, useReducedMotion } from 'motion/react'

const DIGITS = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]

function isDigitChar(ch) {
  return ch >= '0' && ch <= '9'
}

export default function RollingDigits({ value, className = '' }) {
  const reduced = useReducedMotion()
  const text = String(value ?? '')
  const chars = [...text]
  let place = chars.filter(isDigitChar).length
  let symbolRun = 0
  const transition = reduced
    ? { duration: 0 }
    : { type: 'spring', stiffness: 420, damping: 34, mass: 0.7 }

  return (
    <span className={`inline-flex items-baseline tabular-nums ${className}`}>
      <AnimatePresence initial={false} mode="popLayout">
        {chars.map(ch => {
          const isDigit = isDigitChar(ch)
          const key = isDigit ? `d-${--place}` : `s-${place}-${symbolRun++}`
          if (isDigit) symbolRun = 0
          return (
            <motion.span
              key={key}
              initial={reduced ? false : { opacity: 0, width: 0 }}
              animate={{ opacity: 1, width: 'auto' }}
              exit={reduced ? undefined : { opacity: 0, width: 0 }}
              transition={transition}
              className="relative inline-block overflow-hidden align-baseline"
              style={isDigit ? { height: '1.15em', lineHeight: '1.15em' } : undefined}
            >
              {isDigit ? (
                <>
                  <span className="invisible select-none">0</span>
                  <span
                    className="absolute top-0 left-0 flex flex-col transition-transform duration-200 ease-out"
                    style={{
                      transform: `translateY(${-Number(ch) * 10}%)`,
                      transitionDuration: reduced ? '0ms' : '220ms',
                    }}
                  >
                    {DIGITS.map(d => (
                      <span key={d} className="block text-center" style={{ height: '1.15em', lineHeight: '1.15em' }}>
                        {d}
                      </span>
                    ))}
                  </span>
                </>
              ) : (
                <span>{ch}</span>
              )}
            </motion.span>
          )
        })}
      </AnimatePresence>
    </span>
  )
}
