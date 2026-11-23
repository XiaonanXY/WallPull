const colorCache = new Map()
const pending = new Set()

let scratchCanvas = null
let scratchCtx = null
let notifyTimer = null

export function resetColorCache() {
  colorCache.clear()
  pending.clear()
  if (notifyTimer) {
    globalThis.clearTimeout(notifyTimer)
    notifyTimer = null
  }
}

function scheduleColorUpdate(onUpdated) {
  if (!onUpdated || notifyTimer) return
  notifyTimer = globalThis.setTimeout(() => {
    notifyTimer = null
    onUpdated()
  }, 180)
}

function getScratchContext() {
  if (!scratchCtx && typeof document !== 'undefined') {
    scratchCanvas = document.createElement('canvas')
    scratchCanvas.width = 16
    scratchCanvas.height = 16
    scratchCtx = scratchCanvas.getContext('2d', { willReadFrequently: true })
  }
  return scratchCtx
}

function classifyRgbPixels(data) {
  const counts = { dark: 0, light: 0, blue: 0, purple: 0, green: 0, warm: 0 }
  let totalLuma = 0
  let chromaPixels = 0
  const pixelCount = data.length / 4

  for (let i = 0; i < data.length; i += 4) {
    const r = data[i] / 255
    const g = data[i + 1] / 255
    const b = data[i + 2] / 255
    const max = Math.max(r, g, b)
    const min = Math.min(r, g, b)
    const delta = max - min
    const l = (max + min) / 2
    totalLuma += l

    if (delta < 0.12) {
      if (l < 0.28) counts.dark += 1
      else if (l > 0.78) counts.light += 1
      continue
    }

    const s = l > 0.5 ? delta / (2 - max - min) : delta / (max + min)
    if (s < 0.16) {
      if (l < 0.28) counts.dark += 1
      else if (l > 0.78) counts.light += 1
      continue
    }

    chromaPixels += 1
    let hue = 0
    if (max === r) hue = ((g - b) / delta + (g < b ? 6 : 0)) * 60
    else if (max === g) hue = ((b - r) / delta + 2) * 60
    else hue = ((r - g) / delta + 4) * 60

    if (hue >= 335 || hue < 55) counts.warm += 1.25
    else if (hue >= 55 && hue < 168) counts.green += 1.25
    else if (hue >= 168 && hue < 252) counts.blue += 1.25
    else counts.purple += 1.25
  }

  const avgLuma = totalLuma / Math.max(1, pixelCount)
  if (chromaPixels < pixelCount * 0.22) {
    if (avgLuma < 0.34) return 'dark'
    if (avgLuma > 0.72) return 'light'
  }

  let bestKey = avgLuma < 0.4 ? 'dark' : 'light'
  let bestScore = -1
  for (const [key, score] of Object.entries(counts)) {
    if (score > bestScore) {
      bestScore = score
      bestKey = key
    }
  }
  return bestKey
}

export function getCachedColorBucket(id) {
  return colorCache.get(id) ?? null
}

export function sniffWallpaperColors(items, onUpdated) {
  if (!Array.isArray(items) || items.length === 0) return

  const queue = items.filter(
    item => item?.id && !colorCache.has(item.id) && !pending.has(item.id) && (item.previewUrl || item.mediaUrl),
  )
  if (queue.length === 0) return

  let index = 0
  const step = () => {
    const batch = queue.slice(index, index + 6)
    index += 6
    let resolvedInBatch = 0

    for (const item of batch) {
      pending.add(item.id)
      const url = item.previewUrl || item.mediaUrl
      const img = new Image()
      img.crossOrigin = 'anonymous'
      img.decoding = 'async'
      img.onload = () => {
        pending.delete(item.id)
        try {
          const ctx = getScratchContext()
          if (ctx) {
            ctx.clearRect(0, 0, 16, 16)
            ctx.drawImage(img, 0, 0, 16, 16)
            const pixels = ctx.getImageData(0, 0, 16, 16).data
            colorCache.set(item.id, classifyRgbPixels(pixels))
            resolvedInBatch += 1
            if (resolvedInBatch >= 1) scheduleColorUpdate(onUpdated)
          }
        } catch {
          // Cross-origin fallback ignored silently
        }
      }
      img.onerror = () => {
        pending.delete(item.id)
      }
      img.src = url
    }

    if (index < queue.length) {
      if (typeof globalThis.requestIdleCallback === 'function') {
        globalThis.requestIdleCallback(step, { timeout: 800 })
      } else {
        globalThis.setTimeout(step, 48)
      }
    }
  }

  if (typeof globalThis.requestIdleCallback === 'function') {
    globalThis.requestIdleCallback(step, { timeout: 500 })
  } else {
    globalThis.setTimeout(step, 32)
  }
}
