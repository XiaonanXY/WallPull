import { useEffect, useId, useRef, useState } from 'react'
import { createPortal } from 'react-dom'
import { AnimatePresence, motion } from 'motion/react'
import { ArrowSquareOut, FilmStrip, Trash, WarningCircle, X } from '@phosphor-icons/react'
import { formatBytes } from '../appConfig.js'
import HoldToConfirmButton from './ui/HoldToConfirmButton.jsx'

export default function DeleteConfirmDialog({
  items = [],
  isNative = false,
  onOpenWorkshop,
  onConfirm,
  onCancel,
}) {
  const open = Array.isArray(items) && items.length > 0
  const titleId = useId()
  const cancelBtnRef = useRef(null)
  const [alsoDeleteVault, setAlsoDeleteVault] = useState(false)
  const hasArchivedTargets = open && items.some(item => item.isArchivedOffline)

  useEffect(() => {
    if (!open) return undefined
    setAlsoDeleteVault(false)
    const frame = globalThis.requestAnimationFrame(() => {
      cancelBtnRef.current?.focus({ preventScroll: true })
    })
    const onKeyDown = event => {
      if (event.key === 'Escape') {
        event.preventDefault()
        onCancel?.()
      }
    }
    globalThis.addEventListener('keydown', onKeyDown)
    return () => {
      globalThis.cancelAnimationFrame(frame)
      globalThis.removeEventListener('keydown', onKeyDown)
    }
  }, [onCancel, open])

  const single = open && items.length === 1 ? items[0] : null
  const totalBytes = open
    ? (() => {
        const seen = new Map()
        for (const item of items) {
          const key = item.workshopId || item.id
          const size = item.folderSize || item.fileSize || 0
          seen.set(key, Math.max(seen.get(key) ?? 0, size))
        }
        let sum = 0
        for (const val of seen.values()) sum += val
        return sum
      })()
    : 0
  const thumb = single ? (single.previewUrl || (single.type !== 'video' ? single.mediaUrl : '')) : ''

  return createPortal(
    <AnimatePresence>
      {open ? (
        <motion.div
          className="fixed inset-0 z-70 flex items-center justify-center bg-black/52 p-4 backdrop-blur-[4px]"
          initial={{ opacity: 0 }}
          animate={{ opacity: 1 }}
          exit={{ opacity: 0 }}
          transition={{ duration: 0.14 }}
          onMouseDown={event => {
            if (event.target === event.currentTarget) onCancel?.()
          }}
        >
          <motion.div
            role="alertdialog"
            aria-modal="true"
            aria-labelledby={titleId}
            className="w-full max-w-md overflow-hidden rounded-[22px] border border-base-300 bg-base-100 p-6 text-base-content shadow-2xl"
            initial={{ opacity: 0, scale: 0.95, y: 10 }}
            animate={{ opacity: 1, scale: 1, y: 0 }}
            exit={{ opacity: 0, scale: 0.96, y: 6 }}
            transition={{ duration: 0.16, ease: [0.22, 1, 0.36, 1] }}
          >
            <div className="flex items-start justify-between gap-3">
              <div className="flex items-center gap-3">
                <span className="inline-flex h-10 w-10 shrink-0 items-center justify-center rounded-2xl bg-error/12 text-error">
                  <Trash size={20} weight="fill" />
                </span>
                <div>
                  <h2 id={titleId} className="text-base font-semibold tracking-tight">
                    {single ? '删除此壁纸？' : `删除已选 ${items.length} 项壁纸？`}
                  </h2>
                </div>
              </div>
              <button
                type="button"
                className="btn btn-ghost btn-sm h-8 w-8 min-w-0 rounded-full px-0"
                aria-label="取消删除"
                onClick={onCancel}
              >
                <X size={15} weight="bold" />
              </button>
            </div>

            {single ? (
              <div className="mt-4 flex items-center gap-3 rounded-2xl border border-base-300/80 bg-base-200/45 p-3">
                {thumb ? (
                  <img
                    src={thumb}
                    alt=""
                    className="h-14 w-14 shrink-0 rounded-xl object-cover"
                  />
                ) : single.type === 'video' ? (
                  <div className="flex h-14 w-14 shrink-0 items-center justify-center rounded-xl bg-base-300/60 text-base-content/55">
                    <FilmStrip size={22} weight="duotone" />
                  </div>
                ) : null}
                <div className="min-w-0 flex-1">
                  <p className="truncate text-sm font-medium">
                    {single.title}
                  </p>
                  <p className="mt-0.5 text-xs text-base-content/60">
                    {single.type === 'video' ? '视频' : '图片'}
                    {single.resolution ? ` · ${single.resolution}` : ''}
                    {totalBytes > 0 ? ` · 释放 ${formatBytes(totalBytes)}` : ''}
                  </p>
                </div>
              </div>
            ) : (
              <div className="mt-4 rounded-2xl border border-base-300/80 bg-base-200/45 p-3.5">
                <p className="text-sm font-medium">
                  共选中 {items.length} 项本地壁纸，可释放约 {formatBytes(totalBytes)} 磁盘空间
                </p>
                <p className="mt-1 truncate text-xs text-base-content/60">
                  包含：{items.slice(0, 3).map(item => item.title).join('、')}
                  {items.length > 3 ? ` 等 ${items.length} 项` : ''}
                </p>
              </div>
            )}

            <div className="mt-3 flex items-start gap-2 rounded-xl bg-warning/10 px-3 py-2 text-xs leading-relaxed text-base-content/75">
              <WarningCircle size={15} weight="fill" className="mt-0.5 shrink-0 text-warning" />
              <span>
                若壁纸仍在 Steam 创意工坊订阅列表中，下次 Steam 启动可能会自动重新下载；如需彻底移除请同步在 Steam 取消订阅。
              </span>
            </div>

            {hasArchivedTargets ? (
              <label className="mt-3 flex cursor-pointer items-center gap-2 rounded-xl border border-base-300/75 bg-base-200/45 px-3 py-2 text-xs font-medium text-base-content/85">
                <input
                  type="checkbox"
                  className="checkbox checkbox-xs checkbox-error"
                  checked={alsoDeleteVault}
                  onChange={event => setAlsoDeleteVault(event.target.checked)}
                />
                <span>同时移除「离线永久保险箱」备份</span>
              </label>
            ) : null}

            <div className="mt-5 flex flex-wrap items-center justify-between gap-2">
              {single && single.workshopId && !(String(single.workshopId || '').startsWith('99') && String(single.workshopId || '').length >= 15) ? (
                <button
                  type="button"
                  className="btn btn-ghost btn-sm gap-1 text-xs"
                  disabled={!isNative}
                  onClick={() => onOpenWorkshop?.(single)}
                >
                  <ArrowSquareOut size={14} weight="bold" />
                  Steam 创意工坊
                </button>
              ) : <span />}
              <div className="flex items-center gap-2">
                <button
                  ref={cancelBtnRef}
                  type="button"
                  className="btn btn-ghost btn-sm"
                  onClick={onCancel}
                >
                  取消
                </button>
                <HoldToConfirmButton
                  tone="danger"
                  duration={800}
                  label="按住移入回收站"
                  confirmedLabel="已移入回收站"
                  disabled={!isNative}
                  onConfirm={() => onConfirm?.(alsoDeleteVault)}
                />
              </div>
            </div>
          </motion.div>
        </motion.div>
      ) : null}
    </AnimatePresence>,
    document.body,
  )
}
