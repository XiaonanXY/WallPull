import { useLayoutEffect, useRef, useState } from 'react'

const MAX_PLAYING_VIDEOS = 12
const entries = new Map()
let sequence = 0

const observer = typeof IntersectionObserver === 'undefined'
  ? null
  : new IntersectionObserver(changes => {
      changes.forEach(change => {
        const entry = entries.get(change.target)
        if (!entry) return
        entry.visible = change.isIntersecting && change.intersectionRatio >= 0.15
        entry.ratio = change.intersectionRatio
      })
      updatePlaybackBudget()
    }, { threshold: [0, 0.15, 0.5, 0.9] })

function updatePlaybackBudget() {
  const allowed = new Set(
    [...entries.entries()]
      .filter(([, entry]) => entry.visible)
      .sort(([, left], [, right]) =>
        right.priority - left.priority || right.ratio - left.ratio || left.order - right.order)
      .slice(0, MAX_PLAYING_VIDEOS)
      .map(([element]) => element),
  )

  entries.forEach((entry, element) => {
    const next = allowed.has(element)
    entry.setAllowed(prev => (prev === next ? prev : next))
  })
}

export default function useVideoPlaybackBudget(surfaceRef, priority = 0, identity = '') {
  const [allowed, setAllowed] = useState(() => Boolean(identity))
  const priorityRef = useRef(priority)
  priorityRef.current = priority

  useLayoutEffect(() => {
    const element = surfaceRef.current
    if (!element || !identity) {
      setAllowed(false)
      return undefined
    }
    const initiallyVisible = observer === null
      ? true
      : typeof element.getBoundingClientRect === 'function'
        ? (() => {
            const rect = element.getBoundingClientRect()
            const vw = globalThis.innerWidth || 0
            const vh = globalThis.innerHeight || 0
            return (
              rect.width > 0 &&
              rect.height > 0 &&
              rect.bottom > 0 &&
              rect.right > 0 &&
              (vh <= 0 || rect.top < vh) &&
              (vw <= 0 || rect.left < vw)
            )
          })()
        : false
    const entry = {
      order: sequence++,
      priority: priorityRef.current,
      ratio: initiallyVisible ? 1 : 0,
      visible: initiallyVisible,
      setAllowed,
    }
    entries.set(element, entry)
    observer?.observe(element)
    updatePlaybackBudget()
    return () => {
      observer?.unobserve(element)
      entries.delete(element)
      updatePlaybackBudget()
    }
  }, [identity, surfaceRef])

  return allowed
}
