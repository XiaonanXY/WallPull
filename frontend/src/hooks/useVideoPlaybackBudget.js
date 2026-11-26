import { useEffect, useState } from 'react'

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

  entries.forEach((entry, element) => entry.setAllowed(allowed.has(element)))
}

export default function useVideoPlaybackBudget(surfaceRef, priority = 0, identity = '') {
  const [allowed, setAllowed] = useState(false)

  useEffect(() => {
    const element = surfaceRef.current
    if (!element || !identity) {
      setAllowed(false)
      return undefined
    }
    const entry = {
      order: sequence++,
      priority,
      ratio: 0,
      visible: observer === null,
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
  }, [identity, priority, surfaceRef])

  return allowed
}
