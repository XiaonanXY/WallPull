import { useCallback, useEffect, useRef, useState } from 'react'
import { createPortal } from 'react-dom'
import { AnimatePresence, motion } from 'motion/react'
import { Camera, Copy, Crop, DownloadSimple, FolderOpen, X } from '@phosphor-icons/react'
import { formatCaptureTimestamp } from '../utils/videoFrameCapture.js'

export default function VideoFrameCaptureDialog({
  open = false,
  capture = null,
  heading = '视频高清截帧',
  suggestedName = 'wallpull-frame',
  isNative = false,
  onPngAction,
  onOpenCrop,
  onClose,
}) {
  const [busyAction, setBusyAction] = useState(null)
  const busyTimerRef = useRef(null)

  const triggerPngAction = useCallback(mode => {
    if (!capture?.dataUrl || busyAction) return
    setBusyAction(mode)
    if (busyTimerRef.current) globalThis.clearTimeout(busyTimerRef.current)
    busyTimerRef.current = globalThis.setTimeout(() => {
      setBusyAction(null)
      busyTimerRef.current = null
    }, 800)
    onPngAction?.(mode, capture.dataUrl, `${suggestedName || 'wallpull-frame'}_frame`)
  }, [busyAction, capture?.dataUrl, onPngAction, suggestedName])

  useEffect(() => {
    if (!open) {
      if (busyTimerRef.current) {
        globalThis.clearTimeout(busyTimerRef.current)
        busyTimerRef.current = null
      }
      setBusyAction(null)
      return undefined
    }
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

  return createPortal(
    <AnimatePresence>
      {open && capture ? (
        <motion.div
          className="fixed inset-0 z-70 flex items-center justify-center bg-black/58 p-4 backdrop-blur-[5px]"
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
            aria-label="视频当前帧高清截图"
            className="flex max-h-[88vh] w-full max-w-3xl flex-col overflow-hidden rounded-[24px] border border-base-300/85 bg-base-100/96 text-base-content shadow-2xl backdrop-blur-2xl"
            initial={{ opacity: 0, scale: 0.96, y: 10 }}
            animate={{ opacity: 1, scale: 1, y: 0 }}
            exit={{ opacity: 0, scale: 0.97, y: 6 }}
            transition={{ duration: 0.16, ease: [0.22, 1, 0.36, 1] }}
          >
            <header className="flex items-center justify-between gap-3 border-b border-base-300/70 px-5 py-3.5">
              <div className="flex min-w-0 items-center gap-2.5">
                <span className="inline-flex h-8 w-8 shrink-0 items-center justify-center rounded-xl bg-primary/14 text-primary">
                  <Camera size={17} weight="fill" />
                </span>
                <div className="min-w-0">
                  <h2 className="truncate text-sm font-semibold">{heading}</h2>
                  <p className="text-xs text-base-content/60 tabular-nums">
                    原生帧 {capture.width} × {capture.height} · 时间点 {formatCaptureTimestamp(capture.timestampSec)}
                  </p>
                </div>
              </div>
              <button
                type="button"
                className="btn btn-ghost btn-sm h-8 w-8 min-w-0 rounded-full px-0"
                aria-label="关闭截帧预览"
                onClick={onClose}
              >
                <X size={16} weight="bold" />
              </button>
            </header>

            <div className="flex min-h-0 flex-1 items-center justify-center overflow-hidden bg-black/82 p-4">
              <img
                src={capture.dataUrl}
                alt="视频当前帧截图预览"
                className="max-h-[56vh] max-w-full rounded-xl object-contain shadow-lg"
              />
            </div>

            <footer className="flex flex-wrap items-center justify-between gap-2.5 border-t border-base-300/70 px-5 py-3.5">
              <button
                type="button"
                className="btn btn-outline btn-primary btn-sm gap-1.5"
                onClick={() => onOpenCrop?.(capture)}
              >
                <Crop size={15} weight="bold" />
                进入比例裁切
              </button>

              <div className="flex flex-wrap items-center gap-2">
                <button
                  type="button"
                  className="btn btn-ghost btn-sm gap-1.5"
                  disabled={!isNative || Boolean(busyAction)}
                  onClick={() => triggerPngAction('save-as')}
                >
                  <FolderOpen size={15} weight="bold" />
                  {busyAction === 'save-as' ? '处理中…' : '另存为 PNG…'}
                </button>
                <button
                  type="button"
                  className="btn btn-ghost btn-sm gap-1.5"
                  disabled={!isNative || Boolean(busyAction)}
                  onClick={() => triggerPngAction('save')}
                >
                  <DownloadSimple size={15} weight="bold" />
                  {busyAction === 'save' ? '保存中…' : '保存到导出目录'}
                </button>
                <button
                  type="button"
                  className="btn btn-primary btn-sm gap-1.5"
                  disabled={!isNative || Boolean(busyAction)}
                  onClick={() => triggerPngAction('copy')}
                >
                  <Copy size={15} weight="bold" />
                  {busyAction === 'copy' ? '复制中…' : '复制原图（贴微信）'}
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
