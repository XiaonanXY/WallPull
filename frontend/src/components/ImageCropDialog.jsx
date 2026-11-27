import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { createPortal } from 'react-dom'
import { AnimatePresence, motion } from 'motion/react'
import { ArrowsLeftRight, Copy, Crop, DownloadSimple, FolderOpen, X } from '@phosphor-icons/react'

const CROP_PRESETS = [
  { id: 'free', label: '自由比例', ratio: null },
  { id: '1:1', label: '1:1 头像', ratio: 1 },
  { id: '4:3', label: '4:3 iPad', ratio: 4 / 3 },
  { id: '16:9', label: '16:9 桌面', ratio: 16 / 9 },
  { id: '9:19.5', label: '9:19.5 手机', ratio: 9 / 19.5 },
]

function clamp(v, min, max) {
  return Math.min(max, Math.max(min, v))
}

function fitInitialRect(imgW, imgH, targetRatio) {
  if (!targetRatio || imgW <= 0 || imgH <= 0) {
    return { x: 0, y: 0, w: 1, h: 1 }
  }
  const imgRatio = imgW / imgH
  if (imgRatio > targetRatio) {
    const h = 1
    const w = clamp(targetRatio / imgRatio, 0.06, 1)
    return { x: (1 - w) / 2, y: 0, w, h }
  }
  const w = 1
  const h = clamp(imgRatio / targetRatio, 0.06, 1)
  return { x: 0, y: (1 - h) / 2, w, h }
}

export default function ImageCropDialog({
  open = false,
  src = '',
  heading = '智能比例裁切台',
  suggestedName = 'wallpull-crop',
  nativeSize = null,
  sourceKind = 'dataUrl',
  actionDoneSeq = 0,
  isNative = false,
  onCropAction,
  onPngAction,
  onClose,
}) {
  const imgRef = useRef(null)
  const frameRef = useRef(null)
  const dragRef = useRef(null)
  const busyTimerRef = useRef(null)
  const [imgSize, setImgSize] = useState({ w: 0, h: 0 })
  const [loadError, setLoadError] = useState('')
  const [presetId, setPresetId] = useState('free')
  const [swapped, setSwapped] = useState(false)
  const [cropRect, setCropRect] = useState({ x: 0, y: 0, w: 1, h: 1 })
  const [busyMode, setBusyMode] = useState(null)

  const activeRatio = useMemo(() => {
    const preset = CROP_PRESETS.find(p => p.id === presetId)
    if (!preset || !preset.ratio) return null
    return swapped ? 1 / preset.ratio : preset.ratio
  }, [presetId, swapped])

  const effectiveSize = useMemo(() => {
    if (sourceKind === 'studio' && nativeSize?.w > 0 && nativeSize?.h > 0) {
      return { w: Math.round(nativeSize.w), h: Math.round(nativeSize.h) }
    }
    if (imgSize.w > 0 && imgSize.h > 0) {
      return imgSize
    }
    if (nativeSize?.w > 0 && nativeSize?.h > 0) {
      return { w: Math.round(nativeSize.w), h: Math.round(nativeSize.h) }
    }
    return imgSize
  }, [imgSize, nativeSize?.h, nativeSize?.w, sourceKind])

  useEffect(() => {
    if (!open) return
    setLoadError('')
    setImgSize({ w: 0, h: 0 })
    setPresetId('free')
    setSwapped(false)
    setCropRect({ x: 0, y: 0, w: 1, h: 1 })
    setBusyMode(null)
    if (busyTimerRef.current) {
      globalThis.clearTimeout(busyTimerRef.current)
      busyTimerRef.current = null
    }
  }, [open, src])

  useEffect(() => {
    if (actionDoneSeq > 0) {
      setBusyMode(null)
      if (busyTimerRef.current) {
        globalThis.clearTimeout(busyTimerRef.current)
        busyTimerRef.current = null
      }
    }
  }, [actionDoneSeq])

  useEffect(() => {
    if (!open) return undefined
    const onKeyDown = event => {
      if (event.key === 'Escape') {
        event.preventDefault()
        event.stopPropagation()
        onClose?.()
      }
    }
    globalThis.addEventListener('keydown', onKeyDown, true)
    return () => globalThis.removeEventListener('keydown', onKeyDown, true)
  }, [onClose, open])

  const applyPreset = useCallback((nextId, nextSwapped) => {
    const preset = CROP_PRESETS.find(p => p.id === nextId)
    const ratio = preset?.ratio ? (nextSwapped ? 1 / preset.ratio : preset.ratio) : null
    if (effectiveSize.w > 0 && effectiveSize.h > 0) {
      setCropRect(fitInitialRect(effectiveSize.w, effectiveSize.h, ratio))
    }
  }, [effectiveSize.h, effectiveSize.w])

  useEffect(() => {
    const onPointerMove = event => {
      const drag = dragRef.current
      const box = frameRef.current
      if (!drag || !box) return
      const bounds = box.getBoundingClientRect()
      if (bounds.width <= 0 || bounds.height <= 0) return

      const dx = (event.clientX - drag.startX) / bounds.width
      const dy = (event.clientY - drag.startY) / bounds.height
      const r0 = drag.startRect
      const minFrac = 0.06

      if (drag.mode === 'move') {
        setCropRect({
          x: clamp(r0.x + dx, 0, 1 - r0.w),
          y: clamp(r0.y + dy, 0, 1 - r0.h),
          w: r0.w,
          h: r0.h,
        })
        return
      }

      const imgRatio = effectiveSize.w > 0 && effectiveSize.h > 0 ? effectiveSize.w / effectiveSize.h : 1
      let x = r0.x
      let y = r0.y
      let w = r0.w
      let h = r0.h

      if (drag.mode.includes('e')) {
        w = clamp(r0.w + dx, minFrac, 1 - r0.x)
      }
      if (drag.mode.includes('w')) {
        const nextX = clamp(r0.x + dx, 0, r0.x + r0.w - minFrac)
        w = r0.x + r0.w - nextX
        x = nextX
      }
      if (drag.mode.includes('s')) {
        h = clamp(r0.h + dy, minFrac, 1 - r0.y)
      }
      if (drag.mode.includes('n')) {
        const nextY = clamp(r0.y + dy, 0, r0.y + r0.h - minFrac)
        h = r0.y + r0.h - nextY
        y = nextY
      }

      if (activeRatio && imgRatio > 0) {
        const normRatio = activeRatio / imgRatio
        if (Math.abs(dx) >= Math.abs(dy)) {
          h = w / normRatio
          if (drag.mode.includes('n')) {
            y = r0.y + r0.h - h
            if (y < 0) {
              h = r0.y + r0.h
              y = 0
              w = h * normRatio
              if (drag.mode.includes('w')) x = r0.x + r0.w - w
            }
          } else if (y + h > 1) {
            h = 1 - y
            w = h * normRatio
            if (drag.mode.includes('w')) x = r0.x + r0.w - w
          }
        } else {
          w = h * normRatio
          if (drag.mode.includes('w')) {
            x = r0.x + r0.w - w
            if (x < 0) {
              w = r0.x + r0.w
              x = 0
              h = w / normRatio
              if (drag.mode.includes('n')) y = r0.y + r0.h - h
            }
          } else if (x + w > 1) {
            w = 1 - x
            h = w / normRatio
            if (drag.mode.includes('n')) y = r0.y + r0.h - h
          }
        }
      }

      if (w >= minFrac && h >= minFrac) {
        setCropRect({ x, y, w, h })
      }
    }

    const onPointerUp = () => {
      dragRef.current = null
    }

    globalThis.addEventListener('pointermove', onPointerMove)
    globalThis.addEventListener('pointerup', onPointerUp)
    globalThis.addEventListener('pointercancel', onPointerUp)
    return () => {
      globalThis.removeEventListener('pointermove', onPointerMove)
      globalThis.removeEventListener('pointerup', onPointerUp)
      globalThis.removeEventListener('pointercancel', onPointerUp)
    }
  }, [activeRatio, effectiveSize.h, effectiveSize.w])

  const outputPixels = useMemo(() => {
    if (effectiveSize.w <= 0 || effectiveSize.h <= 0) return { x: 0, y: 0, w: 0, h: 0 }
    const x = Math.max(0, Math.round(cropRect.x * effectiveSize.w))
    const y = Math.max(0, Math.round(cropRect.y * effectiveSize.h))
    const w = Math.max(1, Math.min(effectiveSize.w - x, Math.round(cropRect.w * effectiveSize.w)))
    const h = Math.max(1, Math.min(effectiveSize.h - y, Math.round(cropRect.h * effectiveSize.h)))
    return { x, y, w, h }
  }, [cropRect.h, cropRect.w, cropRect.x, cropRect.y, effectiveSize.h, effectiveSize.w])

  const exportCroppedPng = mode => {
    if (busyMode || outputPixels.w <= 0 || outputPixels.h <= 0) return
    const stem = `${suggestedName || 'wallpull-crop'}_${outputPixels.w}x${outputPixels.h}`
    if (isNative && onCropAction) {
      setBusyMode(mode)
      if (busyTimerRef.current) globalThis.clearTimeout(busyTimerRef.current)
      if (mode !== 'save-as') {
        busyTimerRef.current = globalThis.setTimeout(() => {
          setBusyMode(null)
          busyTimerRef.current = null
        }, 6000)
      } else {
        busyTimerRef.current = null
      }
      onCropAction(mode, cropRect, stem)
      return
    }
    const img = imgRef.current
    if (!img) return
    const canvas = document.createElement('canvas')
    canvas.width = outputPixels.w
    canvas.height = outputPixels.h
    const ctx = canvas.getContext('2d')
    if (!ctx) return
    ctx.drawImage(
      img,
      outputPixels.x,
      outputPixels.y,
      outputPixels.w,
      outputPixels.h,
      0,
      0,
      outputPixels.w,
      outputPixels.h,
    )
    let dataUrl = ''
    try {
      dataUrl = canvas.toDataURL('image/png')
    } catch {
      setLoadError('当前图片来源受安全策略限制，无法在画布中直接导出。')
      return
    }
    onPngAction?.(mode, dataUrl, stem)
  }

  const startDrag = (event, mode) => {
    event.preventDefault()
    event.stopPropagation()
    dragRef.current = {
      mode,
      startX: event.clientX,
      startY: event.clientY,
      startRect: { ...cropRect },
    }
  }

  return createPortal(
    <AnimatePresence>
      {open && src ? (
        <motion.div
          className="fixed inset-0 z-75 flex items-center justify-center bg-black/62 p-4 backdrop-blur-[6px]"
          initial={{ opacity: 0 }}
          animate={{ opacity: 1 }}
          exit={{ opacity: 0 }}
          transition={{ duration: 0.14 }}
          onMouseDown={event => {
            if (event.target === event.currentTarget) onClose?.()
          }}
        >
          <motion.div
            role="dialog"
            aria-modal="true"
            aria-label="壁纸比例裁切台"
            className="flex max-h-[90vh] w-full max-w-4xl flex-col overflow-hidden rounded-[24px] border border-base-300/85 bg-base-100/96 text-base-content shadow-2xl backdrop-blur-2xl"
            initial={{ opacity: 0, scale: 0.96, y: 10 }}
            animate={{ opacity: 1, scale: 1, y: 0 }}
            exit={{ opacity: 0, scale: 0.97, y: 6 }}
            transition={{ duration: 0.16, ease: [0.22, 1, 0.36, 1] }}
          >
            <header className="flex flex-wrap items-center justify-between gap-3 border-b border-base-300/70 px-5 py-3.5">
              <div className="flex min-w-0 items-center gap-2.5">
                <span className="inline-flex h-8 w-8 shrink-0 items-center justify-center rounded-xl bg-primary/14 text-primary">
                  <Crop size={17} weight="bold" />
                </span>
                <div className="min-w-0">
                  <h2 className="truncate text-sm font-semibold">{heading}</h2>
                  <p className="text-xs text-base-content/60 tabular-nums">
                    {effectiveSize.w > 0
                      ? `原图 ${effectiveSize.w} × ${effectiveSize.h} → 输出 ${outputPixels.w} × ${outputPixels.h} px`
                      : '正在载入原图…'}
                  </p>
                </div>
              </div>

              <div className="flex flex-wrap items-center gap-1.5">
                {CROP_PRESETS.map(preset => {
                  const active = presetId === preset.id
                  return (
                    <button
                      key={preset.id}
                      type="button"
                      className={`btn btn-xs h-7 px-2.5 ${active ? 'btn-primary' : 'btn-ghost'}`}
                      onClick={() => {
                        setPresetId(preset.id)
                        applyPreset(preset.id, swapped)
                      }}
                    >
                      {preset.label}
                    </button>
                  )
                })}
                <button
                  type="button"
                  disabled={!activeRatio}
                  className="btn btn-ghost btn-xs h-7 gap-1 px-2.5"
                  onClick={() => {
                    const nextSwapped = !swapped
                    setSwapped(nextSwapped)
                    applyPreset(presetId, nextSwapped)
                  }}
                >
                  <ArrowsLeftRight size={13} weight="bold" />
                  横竖互换
                </button>
                <button
                  type="button"
                  className="btn btn-ghost btn-sm h-8 w-8 min-w-0 rounded-full px-0"
                  aria-label="关闭比例裁切台"
                  onClick={onClose}
                >
                  <X size={16} weight="bold" />
                </button>
              </div>
            </header>

            <div className="relative flex min-h-0 flex-1 items-center justify-center overflow-hidden bg-zinc-950/92 p-6 select-none">
              <div ref={frameRef} className="relative inline-block max-h-[58vh] max-w-full">
                <img
                  ref={imgRef}
                  src={src}
                  crossOrigin={isNative ? undefined : 'anonymous'}
                  alt="待裁切原图"
                  draggable={false}
                  onLoad={event => {
                    const el = event.currentTarget
                    if (el.naturalWidth > 0 && el.naturalHeight > 0) {
                      setImgSize({ w: el.naturalWidth, h: el.naturalHeight })
                      setLoadError('')
                    }
                  }}
                  onError={() => setLoadError('未能加载该壁纸原图，请先确认文件完整。')}
                  className="block max-h-[58vh] max-w-full object-contain"
                />

                {imgSize.w > 0 ? (
                  <div
                    role="presentation"
                    style={{
                      left: `${cropRect.x * 100}%`,
                      top: `${cropRect.y * 100}%`,
                      width: `${cropRect.w * 100}%`,
                      height: `${cropRect.h * 100}%`,
                      boxShadow: '0 0 0 9999px rgba(0, 0, 0, 0.54)',
                    }}
                    onPointerDown={event => startDrag(event, 'move')}
                    className="absolute cursor-move border-2 border-white shadow-sm"
                  >
                    <span className="pointer-events-none absolute inset-x-0 top-1/3 h-px bg-white/30" />
                    <span className="pointer-events-none absolute inset-x-0 top-2/3 h-px bg-white/30" />
                    <span className="pointer-events-none absolute inset-y-0 left-1/3 w-px bg-white/30" />
                    <span className="pointer-events-none absolute inset-y-0 left-2/3 w-px bg-white/30" />

                    {[
                      { id: 'nw', cls: '-top-2 -left-2 cursor-nwse-resize' },
                      { id: 'ne', cls: '-top-2 -right-2 cursor-nesw-resize' },
                      { id: 'sw', cls: '-bottom-2 -left-2 cursor-nesw-resize' },
                      { id: 'se', cls: '-bottom-2 -right-2 cursor-nwse-resize' },
                    ].map(handle => (
                      <button
                        key={handle.id}
                        type="button"
                        aria-label={`调整裁切角 ${handle.id}`}
                        onPointerDown={event => startDrag(event, handle.id)}
                        className={`absolute h-4 w-4 rounded-full border-2 border-primary bg-white shadow ${handle.cls}`}
                      />
                    ))}
                  </div>
                ) : null}
              </div>

              {loadError ? (
                <div className="absolute inset-x-6 bottom-4 rounded-xl bg-error/90 px-4 py-2 text-center text-xs font-medium text-white">
                  {loadError}
                </div>
              ) : null}
            </div>

            <footer className="flex flex-wrap items-center justify-between gap-2.5 border-t border-base-300/70 px-5 py-3.5">
              <p className="text-xs text-base-content/60">
                拖动亮框可移动位置，拖动四角圆点可缩放裁切区域
              </p>
              <div className="flex flex-wrap items-center gap-2">
                <button
                  type="button"
                  className="btn btn-ghost btn-sm gap-1.5"
                  disabled={!isNative || effectiveSize.w === 0 || Boolean(busyMode)}
                  onClick={() => exportCroppedPng('save-as')}
                >
                  <FolderOpen size={15} weight="bold" />
                  {busyMode === 'save-as' ? '正在导出…' : '另存为 PNG…'}
                </button>
                <button
                  type="button"
                  className="btn btn-ghost btn-sm gap-1.5"
                  disabled={!isNative || effectiveSize.w === 0 || Boolean(busyMode)}
                  onClick={() => exportCroppedPng('save')}
                >
                  <DownloadSimple size={15} weight="bold" />
                  {busyMode === 'save' ? '正在保存…' : '保存到导出目录'}
                </button>
                <button
                  type="button"
                  className="btn btn-primary btn-sm gap-1.5"
                  disabled={!isNative || effectiveSize.w === 0 || Boolean(busyMode)}
                  onClick={() => exportCroppedPng('copy')}
                >
                  <Copy size={15} weight="bold" />
                  {busyMode === 'copy' ? '正在复制…' : '复制裁切图（贴微信）'}
                </button>
              </div>
            </footer>
          </motion.div>
        </motion.div>
      ) : null}
    </AnimatePresence>,
    document.body,
  )
}
