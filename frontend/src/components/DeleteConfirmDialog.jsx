import { useEffect, useId } from 'react'
import { createPortal } from 'react-dom'
import { AnimatePresence, motion } from 'motion/react'
import { ArrowSquareOut, Trash, WarningCircle, X } from '@phosphor-icons/react'
import { formatBytes } from '../appConfig.js'

export default function DeleteConfirmDialog({
  items = [],
  isNative = false,
  onOpenWorkshop,
  onConfirm,
  onCancel,
}) {
  const open = Array.isArray(items) && items.length > 0
  const titleId = useId()

  useEffect(() => {
    if (!open) return undefined
    const onKeyDown = event => {
      if (event.key === 'Escape') {
        event.preventDefault()
        onCancel?.()
      } else if (event.key === 'Enter' && isNative) {
        event.preventDefault()
        onConfirm?.()
      }
    }
    globalThis.addEventListener('keydown', onKeyDown)
    return () => globalThis.removeEventListener('keydown', onKeyDown)
  }, [isNative, onCancel, onConfirm, open])

  const single = open && items.length === 1 ? items[0] : null
  const totalBytes = open
    ? items.reduce((sum, item) => sum + (item.folderSize || item.fileSize || 0), 0)
    : 0
  const thumb = single ? (single.previewUrl || single.mediaUrl) : ''

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
                  <p className="mt-0.5 text-xs text-base-content/60">
                    将创意工坊本地文件夹移入 Windows 回收站（可随时还原）
                  </p>
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

            <div className="mt-5 flex flex-wrap items-center justify-between gap-2">
              {single && single.workshopId ? (
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
                  type="button"
                  className="btn btn-ghost btn-sm"
                  onClick={onCancel}
                >
                  取消
                </button>
                <button
                  type="button"
                  className="btn btn-error btn-sm gap-1.5 text-white"
                  disabled={!isNative}
                  onClick={onConfirm}
                >
                  <Trash size={14} weight="bold" />
                  移入回收站
                </button>
              </div>
            </div>
          </motion.div>
        </motion.div>
      ) : null}
    </AnimatePresence>,
    document.body,
  )
}
