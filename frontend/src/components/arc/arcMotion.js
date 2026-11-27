/**
 * Motion presets adapted from arc-library motion tokens.
 * Critically damped springs (bounce: 0) settle cleanly without jitter or overshoot.
 */
export const arcMotion = {
  duration: {
    instant: 0.12,
    fast: 0.16,
    exit: 0.14,
    standard: 0.22,
  },
  ease: {
    enter: [0.16, 1, 0.3, 1],
    exit: [0.7, 0, 0.84, 0],
    standard: [0.22, 1, 0.36, 1],
  },
  spring: {
    snappy: { type: 'spring', visualDuration: 0.24, bounce: 0 },
    smooth: { type: 'spring', visualDuration: 0.34, bounce: 0 },
    morph: { type: 'spring', visualDuration: 0.36, bounce: 0 },
  },
  blur: {
    subtle: 2,
    soft: 4,
  },
}
