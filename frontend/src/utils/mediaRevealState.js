const revealedMediaIds = new Set()
const preloadedUrls = new Set()
const savedVideoTimes = new Map()

export function isMediaRevealed(key) {
  return revealedMediaIds.has(key)
}

export function markMediaRevealed(key) {
  revealedMediaIds.add(key)
}

export function resetRevealedMedia() {
  revealedMediaIds.clear()
  preloadedUrls.clear()
}

export function preloadImageUrl(url) {
  if (!url || preloadedUrls.has(url)) return
  preloadedUrls.add(url)
  const img = new Image()
  img.decoding = 'async'
  img.src = url
  if (typeof img.decode === 'function') {
    img.decode().catch(() => {})
  }
}

export function preloadWallpaperBatch(items, startIndex = 0, count = 24) {
  if (!Array.isArray(items) || items.length === 0) return
  const slice = items.slice(startIndex, startIndex + count)
  const run = () => {
    for (const item of slice) {
      const url = item.previewUrl || item.mediaUrl
      if (url) preloadImageUrl(url)
    }
  }
  if (typeof globalThis.requestIdleCallback === 'function') {
    globalThis.requestIdleCallback(run, { timeout: 600 })
  } else {
    globalThis.setTimeout(run, 32)
  }
}

export function getSavedVideoTime(id) {
  return savedVideoTimes.get(id) ?? 0
}

export function saveVideoTime(id, time) {
  if (Number.isFinite(time) && time >= 0) {
    savedVideoTimes.set(id, time)
  }
}
