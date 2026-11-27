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

export function isGeneratedThumbUrl(url) {
  return typeof url === 'string' && /(?:-img-thumb-v3\.jpg|-aspect-v4\.jpg)(?:[?#]|$)/i.test(url)
}

export function isLegacySquarePreviewUrl(url) {
  return typeof url === 'string' && /(?:-img-thumb-v2\.jpg|-square-v3\.jpg|-480p-v1\.mp4)(?:[?#]|$)/i.test(url)
}

export function preloadWallpaperBatch(items, startIndex = 0, count = 12) {
  if (!Array.isArray(items) || items.length === 0) return
  const slice = items.slice(startIndex, startIndex + count)
  const run = () => {
    for (const item of slice) {
      if (isGeneratedThumbUrl(item.previewUrl)) {
        preloadImageUrl(item.previewUrl)
      }
    }
  }
  globalThis.setTimeout(() => {
    if (typeof globalThis.requestIdleCallback === 'function') {
      globalThis.requestIdleCallback(run, { timeout: 600 })
    } else {
      run()
    }
  }, 180)
}

export function getSavedVideoTime(id) {
  return savedVideoTimes.get(id) ?? 0
}

export function saveVideoTime(id, time) {
  if (Number.isFinite(time) && time >= 0) {
    savedVideoTimes.set(id, time)
  }
}
