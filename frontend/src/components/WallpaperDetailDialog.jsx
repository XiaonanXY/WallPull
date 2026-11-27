import { useCallback, useEffect, useId, useMemo, useRef, useState } from 'react'
import { createPortal } from 'react-dom'
import { AnimatePresence, animate, motion, useMotionValue, useTransform } from 'motion/react'
import {
  ArrowSquareOut,
  Camera,
  CaretDown,
  CaretLeft,
  CaretRight,
  Check,
  Copy,
  Crop,
  Desktop,
  DeviceTablet,
  DownloadSimple,
  MusicNotes,
  PaperPlaneTilt,
  Pause,
  Play,
  SlidersHorizontal,
  Stack,
  Trash,
  X,
} from '@phosphor-icons/react'
import GlideSelect from './reactbits/GlideSelect.jsx'
import PulseHeart from './reactbits/PulseHeart.jsx'
import ShinyText from './reactbits/ShinyText.jsx'
import RollingDigits from './ui/RollingDigits.jsx'
import MediaSurface from './MediaSurface.jsx'
import {
  IMAGE_EXPORT_FORMATS,
  VIDEO_EXPORT_FORMATS,
  formatBytes,
} from '../appConfig.js'

function parseResolutionDimensions(resolution) {
  if (typeof resolution === 'string') {
    const match = resolution.match(/(\d+)\s*[×xX]\s*(\d+)/)
    if (match) {
      const w = Number(match[1])
      const h = Number(match[2])
      if (w > 0 && h > 0) return { w, h }
    }
  }
  return null
}

function parseResolutionRatio(resolution) {
  const dims = parseResolutionDimensions(resolution)
  return dims ? dims.w / dims.h : 16 / 9
}

export default function WallpaperDetailDialog({
  item,
  originRect = null,
  isDark = false,
  isFavorited = false,
  hasPrev = false,
  hasNext = false,
  wePropertiesState = { loading: false, properties: [] },
  isNative,
  sendNativeMessage,
  globalAudio = null,
  onPlayGlobalAudio,
  onToggleGlobalAudio,
  onSeekGlobalAudio,
  onPrev,
  onNext,
  onToggleFavorite,
  onSendToTablet,
  onPushClipboardToTablet,
  onOpenLayerStudio,
  onCaptureFrame,
  onOpenCrop,
  onDelete,
  suppressHotkeys = false,
  onClose,
}) {
  const [closing, setClosing] = useState(false)
  const closingRef = useRef(false)
  closingRef.current = closing
  const [settled, setSettled] = useState(false)
  const [viewport, setViewport] = useState(() => ({
    w: globalThis.innerWidth || 1280,
    h: globalThis.innerHeight || 860,
  }))
  const [exportFormat, setExportFormat] = useState('original')
  const [assetIndex, setAssetIndex] = useState(0)
  const [intrinsicRatio, setIntrinsicRatio] = useState(null)
  const [trackIndex, setTrackIndex] = useState(0)
  const [audioPlaying, setAudioPlaying] = useState(false)
  const [audioTime, setAudioTime] = useState({ current: 0, duration: 0 })
  const [zoom, setZoom] = useState(1)
  const [pan, setPan] = useState({ x: 0, y: 0 })
  const [propsOpen, setPropsOpen] = useState(false)
  const [propValues, setPropValues] = useState({})
  const [copiedNotice, setCopiedNotice] = useState(false)
  const copyTimerRef = useRef(null)
  const panDragRef = useRef(null)
  const stageRef = useRef(null)
  const audioRef = useRef(null)
  const detailVideoRef = useRef(null)
  const titleId = useId()
  const panelRef = useRef(null)
  const previousFocusRef = useRef(null)
  const wasOpenRef = useRef(false)
  const flipControlRef = useRef(null)
  const animTokenRef = useRef(0)
  const itemType = item?.type

  useEffect(() => {
    const onResize = () => {
      setViewport({
        w: globalThis.innerWidth || 1280,
        h: globalThis.innerHeight || 860,
      })
    }
    globalThis.addEventListener('resize', onResize)
    return () => globalThis.removeEventListener('resize', onResize)
  }, [])

  const layoutMetrics = useMemo(() => {
    const rawRatio = intrinsicRatio || parseResolutionRatio(item?.resolution)
    const effectiveRatio = Math.max(
      0.25,
      Math.min(4.5, Number.isFinite(rawRatio) && rawRatio > 0 ? rawRatio : 16 / 9),
    )
    const padX = viewport.w < 640 ? 16 : 20
    const borderW = 2
    const panelChromeX = padX * 2 + borderW
    const outerMarginX = viewport.w < 640 ? 24 : 48
    const outerMarginY = viewport.w < 640 ? 24 : 48
    const hasAssets = Array.isArray(item?.assetUrls) && item.assetUrls.length > 1
    const hasStandaloneAudio = Array.isArray(item?.audioTracks)
      && item.audioTracks.some(track => track?.url && track.url !== item?.mediaUrl)
    const maxStageWCap = effectiveRatio > 1.95 ? 1080 : 920
    const availW = Math.max(260, Math.min(viewport.w - outerMarginX - panelChromeX, maxStageWCap))
    const chromeY = panelChromeX + (hasAssets ? 56 : 0) + (hasStandaloneAudio ? 52 : 0) + 152
    const availH = Math.max(
      220,
      Math.min(viewport.h - outerMarginY - chromeY, Math.round(viewport.h * 0.68), 720),
    )

    let stageW
    let stageH
    if (availW / availH > effectiveRatio) {
      stageH = availH
      stageW = Math.max(160, Math.round(stageH * effectiveRatio))
    } else {
      stageW = availW
      stageH = Math.max(160, Math.round(stageW / effectiveRatio))
    }

    const minContentW = Math.min(availW, 560)
    const contentW = Math.max(stageW, minContentW)
    const modalW = contentW + panelChromeX
    const isNarrowStage = stageW < contentW - 2
    return {
      stageW,
      stageH,
      contentW,
      modalW,
      chromeY,
      isNarrowStage,
    }
  }, [intrinsicRatio, item?.assetUrls, item?.audioTracks, item?.mediaUrl, item?.resolution, viewport.h, viewport.w])

  const flipMetrics = useMemo(() => {
    const vw = viewport.w || 1280
    const vh = viewport.h || 860
    const modalW = layoutMetrics.modalW
    const modalH = layoutMetrics.stageH + layoutMetrics.chromeY
    const frontSize = Math.max(180, Math.min(modalW, modalH))
    if (!originRect || !originRect.width) {
      return { dx: 0, dy: 24, startScale: 0.42, frontSize, hasOrigin: false }
    }
    const cx = originRect.left + originRect.width / 2
    const cy = originRect.top + originRect.height / 2
    const startScale = Math.max(0.18, Math.min(0.92, originRect.width / frontSize))
    return {
      dx: cx - vw / 2,
      dy: cy - vh / 2,
      startScale,
      frontSize,
      hasOrigin: true,
    }
  }, [layoutMetrics.chromeY, layoutMetrics.modalW, layoutMetrics.stageH, originRect, viewport.h, viewport.w])

  const handleIntrinsicSize = useCallback(({ width, height }) => {
    if (width > 0 && height > 0) {
      setIntrinsicRatio(width / height)
    }
  }, [])

  const flipProgress = useMotionValue(0)
  const cardX = useTransform(flipProgress, [0, 1], [flipMetrics.dx, 0])
  const cardY = useTransform(flipProgress, [0, 1], [flipMetrics.dy, 0])
  const cardScale = useTransform(
    flipProgress,
    [0, 0.5, 1],
    [flipMetrics.startScale, (flipMetrics.startScale + 1) * 0.52, 1],
  )
  const rotorRotateY = useTransform(flipProgress, [0, 1], [0, 180])

  const itemId = item?.id
  useEffect(() => {
    if (!itemId) {
      wasOpenRef.current = false
      animTokenRef.current += 1
      flipControlRef.current?.stop()
      flipProgress.set(0)
      setSettled(false)
      setClosing(false)
      return undefined
    }
    if (!previousFocusRef.current) {
      previousFocusRef.current = document.activeElement
    }
    if (!wasOpenRef.current) {
      wasOpenRef.current = true
      setSettled(false)
      flipControlRef.current?.stop()
      flipProgress.set(0)
      const token = ++animTokenRef.current
      flipControlRef.current = animate(flipProgress, 1, {
        duration: 0.62,
        ease: [0.32, 0.08, 0.24, 1],
      })
      flipControlRef.current.then(() => {
        if (animTokenRef.current === token && flipProgress.get() >= 0.99) {
          setSettled(true)
        }
      })
    } else if (closingRef.current) {
      animTokenRef.current += 1
      flipControlRef.current?.stop()
      flipProgress.set(1)
      setSettled(true)
    }
    setClosing(false)
    setCopiedNotice(false)
    setExportFormat('original')
    setAssetIndex(0)
    setIntrinsicRatio(null)
    setTrackIndex(0)
    setAudioPlaying(false)
    setAudioTime({ current: 0, duration: 0 })
    setZoom(1)
    setPan({ x: 0, y: 0 })
    setPropsOpen(false)
    setPropValues({})
    const frame = requestAnimationFrame(() => {
      panelRef.current?.focus({ preventScroll: true })
    })
    return () => cancelAnimationFrame(frame)
  }, [flipProgress, itemId])

  useEffect(() => () => {
    animTokenRef.current += 1
    flipControlRef.current?.stop()
    if (copyTimerRef.current) globalThis.clearTimeout(copyTimerRef.current)
  }, [])

  useEffect(() => {
    if (wePropertiesState?.id !== item?.id || !Array.isArray(wePropertiesState?.properties)) return
    const nextMap = {}
    wePropertiesState.properties.forEach(p => {
      nextMap[p.key] = p.value
    })
    setPropValues(nextMap)
  }, [item?.id, wePropertiesState])

  useEffect(() => {
    if (item) return
    if (previousFocusRef.current) {
      previousFocusRef.current.focus?.({ preventScroll: true })
      previousFocusRef.current = null
    }
  }, [item])

  const triggerClose = useCallback(() => {
    if (closing) return
    setClosing(true)
    setSettled(false)
    flipControlRef.current?.stop()
    const token = ++animTokenRef.current
    flipControlRef.current = animate(flipProgress, 0, {
      duration: 0.44,
      ease: [0.32, 0, 0.24, 1],
    })
    flipControlRef.current.then(() => {
      if (animTokenRef.current === token) {
        onClose?.()
      }
    })
  }, [closing, flipProgress, onClose])

  useEffect(() => {
    if (!item || suppressHotkeys || closing) return undefined
    const onKeyDown = event => {
      const tag = document.activeElement?.tagName
      const typing = tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT'
      const interactiveButton = tag === 'BUTTON'
      if (event.key === 'Escape') {
        triggerClose()
      } else if (!typing && !interactiveButton && event.code === 'Space' && item.type === 'video' && detailVideoRef.current) {
        event.preventDefault()
        if (detailVideoRef.current.paused) {
          detailVideoRef.current.play()?.catch(() => {})
        } else {
          detailVideoRef.current.pause()
        }
      } else if (!typing && event.key === 'Delete' && isNative) {
        event.preventDefault()
        onDelete?.(item)
      } else if (!typing && event.key === 'ArrowLeft' && hasPrev) {
        event.preventDefault()
        onPrev?.()
      } else if (!typing && event.key === 'ArrowRight' && hasNext) {
        event.preventDefault()
        onNext?.()
      }
    }
    globalThis.addEventListener('keydown', onKeyDown)
    return () => globalThis.removeEventListener('keydown', onKeyDown)
  }, [closing, hasNext, hasPrev, isNative, item, onDelete, onNext, onPrev, suppressHotkeys, triggerClose])

  useEffect(() => {
    const stageEl = stageRef.current
    if (!stageEl || !itemType || itemType === 'video') return undefined
    const onWheel = event => {
      event.preventDefault()
      const delta = event.deltaY < 0 ? 0.22 : -0.22
      setZoom(prev => {
        const next = Math.max(1, Math.min(5, +(prev + delta).toFixed(2)))
        if (next === 1) setPan({ x: 0, y: 0 })
        return next
      })
    }
    stageEl.addEventListener('wheel', onWheel, { passive: false })
    return () => stageEl.removeEventListener('wheel', onWheel)
  }, [item?.id, itemType])

  if (!item) return null

  const formatOptions = item.type === 'video' ? VIDEO_EXPORT_FORMATS : IMAGE_EXPORT_FORMATS
  const assetUrls = Array.isArray(item.assetUrls) && item.assetUrls.length > 1 ? item.assetUrls : null
  const activeImageSrc = assetUrls ? (assetUrls[assetIndex] || item.mediaUrl) : ''
  const rawAudioTracks = Array.isArray(item.audioTracks) && item.audioTracks.length > 0 ? item.audioTracks : null
  const standaloneList = rawAudioTracks
    ? rawAudioTracks
        .map((track, origIndex) => ({ ...track, origIndex }))
        .filter(track => track?.url && track.url !== item.mediaUrl)
    : []
  const standaloneAudioTracks = standaloneList.length > 0 ? standaloneList : null
  const hasVideoBgm = !standaloneAudioTracks && item.type === 'video' && (Boolean(item.hasAudio) || Boolean(rawAudioTracks?.length))
  const isLocalImported = String(item.workshopId || '').startsWith('99') && String(item.workshopId || '').length >= 15
  const audioTracks = standaloneAudioTracks
  const folderExtra = (item.folderSize || 0) > (item.fileSize || 0) * 1.15
    ? ` · 工坊共占 ${formatBytes(item.folderSize)}`
    : ''
  const metaText = `${item.type === 'video' ? '视频' : '图片'}${
    item.resolution ? ` · ${item.resolution}` : ''
  }${item.duration ? ` · ${item.duration}` : ''} · 原文件 ${formatBytes(item.fileSize)}${folderExtra}${
    assetUrls ? ` · 共 ${assetUrls.length} 张原画` : ''
  }`

  const activeGlobalForItem = Boolean(globalAudio?.item?.id === item.id)
  const safeTrackIdx = audioTracks ? Math.max(0, Math.min(trackIndex, audioTracks.length - 1)) : 0
  const globalMatchIdx = activeGlobalForItem && audioTracks
    ? audioTracks.findIndex(t => t.origIndex === globalAudio.trackIndex)
    : -1
  const displayTrackIdx = globalMatchIdx >= 0 ? globalMatchIdx : safeTrackIdx
  const displayTrack = audioTracks ? (audioTracks[displayTrackIdx] || audioTracks[0]) : null
  const displayAudioPlaying = onPlayGlobalAudio
    ? Boolean(activeGlobalForItem && globalAudio?.playing)
    : audioPlaying
  const displayAudioTime = activeGlobalForItem
    ? { current: globalAudio.currentTime || 0, duration: globalAudio.duration || 0 }
    : (onPlayGlobalAudio ? { current: 0, duration: 0 } : audioTime)

  const formatAudioClock = seconds => {
    if (!Number.isFinite(seconds) || seconds <= 0) return '0:00'
    const mins = Math.floor(seconds / 60)
    const secs = Math.floor(seconds % 60)
    return `${mins}:${String(secs).padStart(2, '0')}`
  }

  const toggleAudioPlay = () => {
    if (onPlayGlobalAudio) {
      if (activeGlobalForItem) {
        onToggleGlobalAudio?.()
      } else {
        onPlayGlobalAudio(item, displayTrack?.origIndex ?? 0)
      }
      return
    }
    const audio = audioRef.current
    if (!audio || !displayTrack?.url) return
    if (audio.paused) {
      audio.play()?.then(() => setAudioPlaying(true)).catch(() => {})
    } else {
      audio.pause()
      setAudioPlaying(false)
    }
  }

  const startPan = event => {
    if (item.type === 'video' || zoom <= 1 || event.button !== 0) return
    event.preventDefault()
    try {
      event.currentTarget.setPointerCapture(event.pointerId)
    } catch {
      // ignore if pointer capture unavailable
    }
    panDragRef.current = {
      pointerId: event.pointerId,
      startX: event.clientX - pan.x,
      startY: event.clientY - pan.y,
    }
  }

  const movePan = event => {
    const drag = panDragRef.current
    if (!drag || drag.pointerId !== event.pointerId) return
    setPan({
      x: event.clientX - drag.startX,
      y: event.clientY - drag.startY,
    })
  }

  const endPan = event => {
    const drag = panDragRef.current
    if (drag && event?.currentTarget?.hasPointerCapture?.(drag.pointerId)) {
      try {
        event.currentTarget.releasePointerCapture(drag.pointerId)
      } catch {
        // ignore
      }
    }
    panDragRef.current = null
  }

  const resetZoom = () => {
    setZoom(1)
    setPan({ x: 0, y: 0 })
  }

  const toggleHiddenPropertiesPanel = () => {
    const nextOpen = !propsOpen
    setPropsOpen(nextOpen)
    if (nextOpen && isNative && item?.customizableCount > 0) {
      sendNativeMessage('wallpapers.we-properties.get', { id: item.id })
    }
  }

  const pushHiddenProperties = () => {
    if (!isNative || !item) return
    sendNativeMessage('wallpapers.we-properties.apply', {
      id: item.id,
      properties: propValues,
    })
  }

  const weProps = wePropertiesState?.id === item.id ? (wePropertiesState.properties ?? []) : []

  return createPortal(
    <motion.div
      className="fixed inset-0 z-50 flex items-center justify-center bg-black/58 p-4 sm:p-6 backdrop-blur-[5px]"
      style={settled && !closing ? undefined : { perspective: 1300 }}
      initial={{ opacity: 0 }}
      animate={{ opacity: closing ? 0 : 1 }}
      transition={{ duration: closing ? 0.44 : 0.26 }}
      onMouseDown={event => {
        if (event.target === event.currentTarget) triggerClose()
      }}
    >
      <motion.div
        className="relative"
        style={{
          width: layoutMetrics.modalW,
          maxWidth: '100%',
          ...(settled && !closing
            ? undefined
            : {
                transformStyle: 'preserve-3d',
                x: cardX,
                y: cardY,
                scale: cardScale,
                rotateY: rotorRotateY,
              }),
        }}
      >
        {!settled || closing ? (
          <div
            aria-hidden="true"
            className="pointer-events-none absolute overflow-hidden rounded-[22px] border border-base-300 bg-base-200 shadow-2xl"
            style={{
              width: flipMetrics.frontSize,
              height: flipMetrics.frontSize,
              left: '50%',
              top: '50%',
              marginLeft: -flipMetrics.frontSize / 2,
              marginTop: -flipMetrics.frontSize / 2,
              backfaceVisibility: 'hidden',
              WebkitBackfaceVisibility: 'hidden',
              transform: 'rotateY(0deg) translateZ(1px)',
            }}
          >
            {item.previewUrl || (item.type !== 'video' ? item.mediaUrl : '') ? (
              <img
                src={item.previewUrl || item.mediaUrl}
                alt=""
                className="h-full w-full object-cover"
                decoding="async"
                draggable="false"
              />
            ) : null}
            <div
              className="absolute inset-0"
              style={{
                background: 'linear-gradient(135deg, rgba(255,255,255,0.28) 0%, rgba(255,255,255,0) 55%)',
              }}
            />
          </div>
        ) : null}

        <div
          ref={panelRef}
          role="dialog"
          aria-modal="true"
          aria-labelledby={titleId}
          tabIndex={-1}
          className="relative flex max-h-[calc(100vh-32px)] w-full flex-col overflow-y-auto rounded-[22px] border border-base-300 bg-base-100 p-4 sm:p-5 text-base-content shadow-2xl outline-none"
          style={
            settled && !closing
              ? undefined
              : {
                  backfaceVisibility: 'hidden',
                  WebkitBackfaceVisibility: 'hidden',
                  transform: 'rotateY(180deg) translateZ(1px)',
                }
          }
        >
        <div
          ref={stageRef}
          className="relative flex shrink-0 items-center justify-center overflow-hidden rounded-[14px]"
          onPointerDown={startPan}
          onPointerMove={movePan}
          onPointerUp={endPan}
          onPointerCancel={endPan}
          onLostPointerCapture={endPan}
          onDoubleClick={() => {
            if (item.type !== 'video') {
              if (zoom > 1) resetZoom()
              else setZoom(2)
            }
          }}
          style={{
            width: '100%',
            height: layoutMetrics.stageH,
            cursor: zoom > 1 ? 'grab' : undefined,
          }}
        >
          {layoutMetrics.isNarrowStage && (item.type === 'video' ? item.previewUrl : (activeImageSrc || item.previewUrl || item.mediaUrl)) ? (
            <>
              <img
                src={item.type === 'video' ? item.previewUrl : (activeImageSrc || item.previewUrl || item.mediaUrl)}
                alt=""
                aria-hidden="true"
                draggable={false}
                className="pointer-events-none absolute inset-0 h-full w-full scale-115 object-cover opacity-45 blur-2xl saturate-125 select-none"
              />
              <div aria-hidden="true" className="pointer-events-none absolute inset-0 bg-base-300/35" />
            </>
          ) : null}

          {hasPrev ? (
            <button
              type="button"
              className="btn btn-ghost btn-sm absolute left-2.5 z-20 h-9 w-9 min-w-0 rounded-full bg-base-100/75 px-0 backdrop-blur-md"
              onClick={event => {
                event.stopPropagation()
                onPrev?.()
              }}
              aria-label="上一张壁纸"
            >
              <CaretLeft size={16} weight="bold" />
            </button>
          ) : null}

          <div
            className={`relative z-[1] mx-auto max-w-full shrink-0 overflow-hidden rounded-[14px] ${
              layoutMetrics.isNarrowStage ? 'shadow-xl' : ''
            }`}
            style={{
              width: layoutMetrics.isNarrowStage ? layoutMetrics.stageW : '100%',
              height: layoutMetrics.stageH,
              ...(zoom > 1
                ? {
                    transform: `translate3d(${pan.x}px, ${pan.y}px, 0) scale(${zoom})`,
                    transformOrigin: 'center center',
                  }
                : null),
            }}
          >
            <MediaSurface
              key={`${item.id}:${activeImageSrc || item.mediaUrl}`}
              item={item}
              priority={10}
              fit="cover"
              interactive
              paused={closing}
              videoElementRef={detailVideoRef}
              overrideImageSrc={activeImageSrc}
              onIntrinsicSize={handleIntrinsicSize}
              onCaptureFrame={item.type === 'video' && onCaptureFrame ? (el => onCaptureFrame(el, item)) : null}
            />
          </div>

          {hasNext ? (
            <button
              type="button"
              className="btn btn-ghost btn-sm absolute right-2.5 z-20 h-9 w-9 min-w-0 rounded-full bg-base-100/75 px-0 backdrop-blur-md"
              onClick={event => {
                event.stopPropagation()
                onNext?.()
              }}
              aria-label="下一张壁纸"
            >
              <CaretRight size={16} weight="bold" />
            </button>
          ) : null}

          {zoom > 1 ? (
            <button
              type="button"
              className="btn btn-ghost btn-sm absolute bottom-3 right-3 z-20 h-7 min-h-0 rounded-full bg-black/55 px-2.5 text-xs text-white backdrop-blur-md"
              onClick={event => {
                event.stopPropagation()
                resetZoom()
              }}
            >
              {Math.round(zoom * 100)}% · 重置
            </button>
          ) : null}
        </div>

        {assetUrls ? (
          <div className="mt-3 flex shrink-0 items-center justify-center gap-2 overflow-x-auto py-0.5">
            {assetUrls.map((url, idx) => (
              <button
                key={url}
                type="button"
                aria-label={`原画版本 ${idx + 1}`}
                onClick={() => {
                  setAssetIndex(idx)
                  setIntrinsicRatio(null)
                  resetZoom()
                }}
                className={`h-11 w-11 shrink-0 overflow-hidden rounded-lg border-2 p-0 transition-transform ${
                  idx === assetIndex
                    ? 'scale-105 border-primary'
                    : 'border-transparent opacity-65 hover:opacity-100'
                }`}
              >
                <img src={url} alt="" className="h-full w-full object-cover" />
              </button>
            ))}
          </div>
        ) : null}

        {audioTracks && displayTrack ? (
          <div className="mt-3 flex shrink-0 flex-wrap items-center gap-3 rounded-xl border border-base-300/80 bg-base-200/55 px-3.5 py-2">
            {!onPlayGlobalAudio && !closing && displayTrack.url ? (
              <audio
                key={`${item.id}:${displayTrack.url}`}
                ref={audioRef}
                src={displayTrack.url}
                preload="metadata"
                onLoadedMetadata={event => {
                  const dur = event.currentTarget.duration
                  setAudioTime(prev => ({ ...prev, duration: Number.isFinite(dur) ? dur : 0 }))
                }}
                onTimeUpdate={event => {
                  const cur = event.currentTarget.currentTime
                  const dur = event.currentTarget.duration
                  setAudioTime({
                    current: Number.isFinite(cur) ? cur : 0,
                    duration: Number.isFinite(dur) ? dur : 0,
                  })
                }}
                onEnded={() => setAudioPlaying(false)}
              />
            ) : null}
            <button
              type="button"
              className="btn btn-primary btn-sm h-8 w-8 min-w-0 shrink-0 rounded-full px-0"
              aria-label={displayAudioPlaying ? '暂停配乐' : '试听配乐'}
              disabled={!displayTrack.url}
              onClick={toggleAudioPlay}
            >
              {displayAudioPlaying ? <Pause size={14} weight="fill" /> : <Play size={14} weight="fill" />}
            </button>
            <div className="flex min-w-0 flex-1 items-center gap-2.5">
              <MusicNotes size={15} weight="fill" className="shrink-0 text-primary" />
              <span className="max-w-44 truncate text-xs font-semibold">
                {displayTrack.name}
              </span>
              {audioTracks.length > 1 ? (
                <button
                  type="button"
                  className="btn btn-ghost btn-xs h-6 min-h-0 rounded-full px-2 text-[11px]"
                  onClick={() => {
                    const nextIdx = (displayTrackIdx + 1) % audioTracks.length
                    setTrackIndex(nextIdx)
                    if (onPlayGlobalAudio) {
                      onPlayGlobalAudio(item, audioTracks[nextIdx]?.origIndex ?? nextIdx)
                    } else {
                      setAudioPlaying(false)
                      setAudioTime({ current: 0, duration: 0 })
                    }
                  }}
                >
                  曲目 {displayTrackIdx + 1}/{audioTracks.length}
                </button>
              ) : null}
              <input
                type="range"
                aria-label="音频播放进度"
                min={0}
                max={displayAudioTime.duration || 100}
                step={0.1}
                value={Math.min(displayAudioTime.current, displayAudioTime.duration || 100)}
                disabled={!displayTrack.url || displayAudioTime.duration <= 0}
                onChange={event => {
                  const next = Number(event.target.value)
                  if (onPlayGlobalAudio && activeGlobalForItem) {
                    onSeekGlobalAudio?.(next)
                  } else {
                    if (audioRef.current) audioRef.current.currentTime = next
                    setAudioTime(prev => ({ ...prev, current: next }))
                  }
                }}
                className="range range-primary range-xs min-w-20 flex-1"
              />
              <span className="shrink-0 tabular-nums text-[11px] text-base-content/60">
                <RollingDigits value={`${formatAudioClock(displayAudioTime.current)} / ${formatAudioClock(displayAudioTime.duration)}`} />
              </span>
            </div>
            <div className="flex shrink-0 items-center gap-1">
              <button
                type="button"
                className="btn btn-ghost btn-sm h-7 min-h-0 px-2.5 text-xs"
                disabled={!isNative}
                onClick={() => sendNativeMessage('wallpapers.export-audio.request', {
                  id: item.id,
                  trackIndex: displayTrack?.origIndex ?? 0,
                })}
              >
                <DownloadSimple size={13} weight="bold" />
                {audioTracks.length > 1 ? '导出此曲' : '导出 BGM'}
              </button>
              {audioTracks.length > 1 ? (
                <button
                  type="button"
                  className="btn btn-ghost btn-sm h-7 min-h-0 px-2.5 text-xs"
                  disabled={!isNative}
                  onClick={() => sendNativeMessage('wallpapers.export-audio.request', {
                    id: item.id,
                  })}
                >
                  导出全部 ({audioTracks.length})
                </button>
              ) : null}
            </div>
          </div>
        ) : null}

        <div className="mt-4 shrink-0">
          <div className="flex items-start justify-between gap-3">
            <div className="min-w-0 flex-1">
              <h2 id={titleId} className="truncate text-lg font-semibold tracking-tight">
                <ShinyText
                  text={item.title}
                  color={isDark ? '#e4e4ee' : '#18181b'}
                  shineColor={isDark ? '#ffffff' : '#9a9ab0'}
                  speed={2.8}
                  delay={1.2}
                  shineWidth={38}
                  className="block truncate"
                />
              </h2>
              <p className="mt-1 text-sm text-base-content/70">
                <ShinyText
                  text={metaText}
                  color={isDark ? '#9898aa' : '#646474'}
                  shineColor={isDark ? '#f0f0f8' : '#c6c6d4'}
                  speed={3.4}
                  delay={1.6}
                  shineWidth={36}
                  className="block truncate"
                />
              </p>
            </div>
            <div className="flex shrink-0 items-center gap-1.5">
              <div className="wv-utility-island" role="group" aria-label="发送到平板">
                <button
                  className="wv-utility-island__btn"
                  type="button"
                  disabled={!isNative}
                  onClick={() => onSendToTablet?.(item, assetIndex)}
                >
                  <PaperPlaneTilt size={13} weight="bold" />
                  <span>发到 iPad</span>
                </button>
                {item.type === 'image' ? (
                  <>
                    <span className="wv-utility-island__divider" aria-hidden="true" />
                    <span className="tooltip tooltip-bottom" data-tip="推至 iPad 剪贴板">
                      <button
                        className="wv-utility-island__btn w-7 px-0"
                        type="button"
                        aria-label="推至 iPad 剪贴板"
                        disabled={!isNative}
                        onClick={() => onPushClipboardToTablet?.(item, assetIndex)}
                      >
                        <DeviceTablet size={13} weight="bold" />
                      </button>
                    </span>
                  </>
                ) : null}
              </div>
              {item.customizableCount > 0 ? (
                <button
                  type="button"
                  className={`btn btn-sm h-8 gap-1 px-2.5 text-xs ${propsOpen ? 'btn-primary' : 'btn-ghost'}`}
                  onClick={toggleHiddenPropertiesPanel}
                >
                  <SlidersHorizontal size={14} weight="bold" />
                  <span>隐藏开关 ({item.customizableCount})</span>
                  <CaretDown
                    size={12}
                    weight="bold"
                    className={`transition-transform ${propsOpen ? 'rotate-180' : ''}`}
                  />
                </button>
              ) : null}
              <PulseHeart
                liked={isFavorited}
                onChange={() => onToggleFavorite?.(item.id)}
                showCount={false}
                size={18}
                corner={999}
                pillColor={isDark ? 'rgba(255, 255, 255, 0.07)' : 'rgba(24, 24, 27, 0.05)'}
                idleColor={isDark ? '#e4e4ee' : '#3f3f46'}
                likedColor="#ff4d6d"
                label={isFavorited ? '取消收藏' : '加入收藏'}
              />
              <button
                type="button"
                className="btn btn-ghost btn-sm h-8 w-8 min-w-0 shrink-0 rounded-full px-0"
                aria-label="关闭详情"
                onClick={triggerClose}
              >
                <X size={16} weight="bold" />
              </button>
            </div>
          </div>

          <AnimatePresence>
            {propsOpen ? (
              <motion.div
                initial={{ opacity: 0, height: 0 }}
                animate={{ opacity: 1, height: 'auto' }}
                exit={{ opacity: 0, height: 0 }}
                transition={{ duration: 0.18 }}
                className="mt-3 overflow-hidden rounded-xl border border-base-300/85 bg-base-200/60 px-4 py-3"
              >
                <div className="flex flex-wrap items-center justify-between gap-2 pb-2">
                  <div>
                    <p className="text-xs font-semibold">作者隐藏开关与换装差分面板</p>
                  </div>
                  <button
                    type="button"
                    className="btn btn-primary btn-xs rounded-full px-3"
                    disabled={!isNative || weProps.length === 0}
                    onClick={pushHiddenProperties}
                  >
                    同步到 Wallpaper Engine
                  </button>
                </div>
                {wePropertiesState.loading ? (
                  <p className="py-2 text-xs text-base-content/60">正在解析 project.json 隐藏属性…</p>
                ) : weProps.length === 0 ? (
                  <p className="py-2 text-xs text-base-content/60">此壁纸未暴露用户可控属性。</p>
                ) : (
                  <div className="grid max-h-40 grid-cols-1 gap-2.5 overflow-y-auto pt-1 sm:grid-cols-2">
                    {weProps.map(prop => {
                      const val = propValues[prop.key] ?? prop.value
                      return (
                        <div
                          key={prop.key}
                          className="flex items-center justify-between gap-2 rounded-lg border border-base-300/70 bg-base-100/75 px-3 py-1.5"
                        >
                          <span className="truncate text-xs font-medium">
                            {prop.label}
                          </span>
                          {prop.type === 'bool' ? (
                            <input
                              type="checkbox"
                              className="toggle toggle-primary toggle-xs"
                              checked={Boolean(val)}
                              onChange={e => setPropValues(prev => ({ ...prev, [prop.key]: e.target.checked }))}
                            />
                          ) : prop.type === 'combo' && prop.options?.length > 0 ? (
                            <select
                              className="select select-xs max-w-36"
                              value={String(val ?? '')}
                              onChange={e => setPropValues(prev => ({ ...prev, [prop.key]: e.target.value }))}
                            >
                              {prop.options.map(opt => (
                                <option key={opt.value} value={opt.value}>{opt.label}</option>
                              ))}
                            </select>
                          ) : prop.type === 'slider' ? (
                            <input
                              type="range"
                              className="range range-primary range-xs w-28"
                              min={prop.min ?? 0}
                              max={prop.max ?? 100}
                              step="any"
                              value={Number(val) || 0}
                              onChange={e => setPropValues(prev => ({ ...prev, [prop.key]: Number(e.target.value) }))}
                            />
                          ) : (
                            <input
                              type="text"
                              className="input input-xs w-36"
                              value={String(val ?? '')}
                              onChange={e => setPropValues(prev => ({ ...prev, [prop.key]: e.target.value }))}
                            />
                          )}
                        </div>
                      )
                    })}
                  </div>
                )}
              </motion.div>
            ) : null}
          </AnimatePresence>

          <div className="mt-4 flex flex-wrap items-center justify-between gap-3">
            <div className="flex items-center gap-1.5">
              <span className="text-sm text-base-content/70">导出格式</span>
              <GlideSelect
                options={formatOptions}
                value={exportFormat}
                onChange={setExportFormat}
                placement="top"
                align="left"
                size="md"
                menuWidth={164}
                surfaceColor={isDark ? '#1c1c28' : '#ffffff'}
                highlightColor={isDark ? '#2b2b3c' : '#efecf5'}
                textColor={isDark ? '#f1f1f6' : '#18181b'}
                accentColor="var(--color-primary)"
                ariaLabel="选择导出格式"
              />
            </div>
            <div className="flex flex-wrap items-center gap-1.5">
              <button
                className="btn btn-ghost btn-sm"
                type="button"
                disabled={!isNative}
                onClick={() => sendNativeMessage(
                  'wallpapers.set-desktop.request',
                  { id: item.id, assetIndex },
                )}
              >
                <Desktop size={15} weight="bold" />
                设为桌面
              </button>
              {item.type === 'video' && onCaptureFrame ? (
                <button
                  className="btn btn-ghost btn-sm gap-1"
                  type="button"
                  onClick={() => onCaptureFrame(detailVideoRef.current, item)}
                >
                  <Camera size={14} weight="bold" />
                  截当前帧
                </button>
              ) : null}
              {item.type !== 'video' && onOpenCrop ? (
                <button
                  className="btn btn-ghost btn-sm gap-1"
                  type="button"
                  onClick={() => onOpenCrop({
                    src: activeImageSrc || item.mediaUrl || item.previewUrl,
                    heading: `${item.title || '壁纸'} · 智能比例裁切`,
                    suggestedName: item.title || 'wallpull-crop',
                    sourceKind: 'wallpaper',
                    wallpaperId: item.id,
                    assetIndex: assetUrls ? assetIndex : null,
                    nativeSize: parseResolutionDimensions(item.resolution),
                  })}
                >
                  <Crop size={14} weight="bold" />
                  比例裁切
                </button>
              ) : null}
              {hasVideoBgm ? (
                <button
                  className="btn btn-ghost btn-sm gap-1"
                  type="button"
                  disabled={!isNative}
                  onClick={() => sendNativeMessage('wallpapers.export-audio.request', { id: item.id })}
                >
                  <MusicNotes size={14} weight="bold" />
                  提取 BGM
                </button>
              ) : null}
              {item.hasSceneLayers ? (
                <button
                  className="btn btn-outline btn-primary btn-sm"
                  type="button"
                  disabled={!isNative}
                  onClick={() => onOpenLayerStudio?.(item)}
                >
                  <Stack size={15} weight="bold" />
                  透视拆解台
                </button>
              ) : null}
              {!isLocalImported && item.workshopId ? (
                <button
                  className="btn btn-ghost btn-sm"
                  type="button"
                  disabled={!isNative}
                  onClick={() => sendNativeMessage(
                    'wallpapers.open-workshop.request',
                    { id: item.id },
                  )}
                >
                  <ArrowSquareOut size={15} weight="bold" />
                  Steam 创意工坊
                </button>
              ) : null}
              <button
                className="btn btn-ghost btn-sm text-error hover:bg-error/10"
                type="button"
                disabled={!isNative}
                onClick={() => onDelete?.(item)}
              >
                <Trash size={15} weight="bold" />
                删除
              </button>
              <button
                className="btn btn-ghost btn-sm"
                type="button"
                disabled={!isNative}
                onClick={() => sendNativeMessage(
                  'wallpapers.open-folder.request',
                  { id: item.id },
                )}
              >
                原文件位置
              </button>
              <button
                className="btn btn-ghost btn-sm gap-1.5"
                type="button"
                disabled={!isNative}
                onClick={() => {
                  sendNativeMessage('wallpapers.copy.request', { id: item.id, assetIndex })
                  setCopiedNotice(true)
                  if (copyTimerRef.current) globalThis.clearTimeout(copyTimerRef.current)
                  copyTimerRef.current = globalThis.setTimeout(() => setCopiedNotice(false), 1600)
                }}
              >
                {copiedNotice ? <Check size={14} weight="bold" className="text-success" /> : <Copy size={14} weight="bold" />}
                <span>{copiedNotice ? '已复制' : (item.type === 'video' ? '复制视频' : '复制原图')}</span>
              </button>
              <button
                className="btn btn-ghost btn-sm"
                type="button"
                disabled={!isNative}
                onClick={() => sendNativeMessage(
                  'wallpapers.export-as.request',
                  { ids: [item.id], format: exportFormat, assetIndex },
                )}
              >
                另存到…
              </button>
              <button
                className="btn btn-primary btn-sm"
                type="button"
                disabled={!isNative}
                onClick={() => sendNativeMessage(
                  'wallpapers.export.request',
                  { ids: [item.id], format: exportFormat, assetIndex },
                )}
              >
                导出
              </button>
              <button className="btn btn-ghost btn-sm" type="button" onClick={triggerClose}>
                关闭
              </button>
            </div>
          </div>
        </div>
        </div>
      </motion.div>
    </motion.div>,
    document.body,
  )
}
