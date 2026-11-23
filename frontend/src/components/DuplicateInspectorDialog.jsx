import { useEffect, useMemo, useState } from 'react'
import { createPortal } from 'react-dom'
import { motion } from 'motion/react'
import {
  ArrowsClockwise,
  Check,
  Compass,
  Eye,
  MagnifyingGlass,
  Trash,
  X,
} from '@phosphor-icons/react'
import { formatBytes } from '../appConfig.js'

export default function DuplicateInspectorDialog({
  open,
  loading,
  result,
  isNative,
  onRescan,
  onPreview,
  onOpenWorkshop,
  onRecycleIds,
  onClose,
}) {
  const [selectedIds, setSelectedIds] = useState(() => new Set())
  const [confirmStep, setConfirmStep] = useState(false)

  const groups = useMemo(() => result?.groups ?? [], [result])

  const suggestedIds = useMemo(() => {
    const ids = []
    groups.forEach(group => {
      group.members.forEach(member => {
        if (!member.recommendedKeep && member.item?.id) {
          ids.push(member.item.id)
        }
      })
    })
    return ids
  }, [groups])

  useEffect(() => {
    if (!open) {
      setConfirmStep(false)
      return undefined
    }

    const onKeyDown = event => {
      if (event.key === 'Escape') {
        event.preventDefault()
        onClose?.()
      }
    }
    globalThis.addEventListener('keydown', onKeyDown)
    return () => globalThis.removeEventListener('keydown', onKeyDown)
  }, [onClose, open])

  useEffect(() => {
    setSelectedIds(new Set(suggestedIds))
    setConfirmStep(false)
  }, [suggestedIds])

  const selectedBytes = useMemo(() => {
    let total = 0
    const seenWorkshop = new Set()
    groups.forEach(group => {
      group.members.forEach(member => {
        const item = member.item
        if (!item || !selectedIds.has(item.id)) return
        if (seenWorkshop.has(item.workshopId)) return
        seenWorkshop.add(item.workshopId)
        total += item.folderSize || item.fileSize || 0
      })
    })
    return total
  }, [groups, selectedIds])

  if (!open) return null

  const toggleId = id => {
    setConfirmStep(false)
    setSelectedIds(prev => {
      const next = new Set(prev)
      if (next.has(id)) next.delete(id)
      else next.add(id)
      return next
    })
  }

  return createPortal(
    <div
      className="fixed inset-0 z-55 flex items-center justify-center bg-black/58 p-4 backdrop-blur-sm"
      onMouseDown={event => {
        if (event.target === event.currentTarget) onClose?.()
      }}
    >
      <motion.div
        role="dialog"
        aria-modal="true"
        aria-label="相似与重复壁纸智能体检"
        className="flex max-h-[86vh] w-full max-w-5xl flex-col overflow-hidden rounded-[22px] border border-base-300 bg-base-100 text-base-content shadow-2xl"
        initial={{ opacity: 0, scale: 0.96, y: 12 }}
        animate={{ opacity: 1, scale: 1, y: 0 }}
        transition={{ duration: 0.2, ease: [0.2, 0, 0, 1] }}
      >
        <header className="flex shrink-0 items-center justify-between gap-4 border-b border-base-300/70 px-6 py-4">
          <div className="flex items-center gap-3">
            <div className="flex h-9 w-9 shrink-0 items-center justify-center rounded-xl bg-primary/14 text-primary">
              <MagnifyingGlass size={19} weight="bold" />
            </div>
            <div>
              <h2 className="text-base font-semibold tracking-tight">相似与重复壁纸体检</h2>
              <p className="text-xs text-base-content/60">
                {loading
                  ? '正在用感知视觉指纹比对全库壁纸…'
                  : result
                    ? `共检测 ${result.scannedCount} 个工坊壁纸 · 发现 ${groups.length} 组近似/重复项 · 预计可释放 ${formatBytes(result.totalReclaimableBytes)}`
                    : '自动识别重传、低清晰度副本与同画面不同版本'}
              </p>
            </div>
          </div>

          <div className="flex items-center gap-2">
            <button
              type="button"
              className="btn btn-ghost btn-sm"
              disabled={loading || !isNative}
              onClick={onRescan}
            >
              <ArrowsClockwise size={14} weight="bold" className={loading ? 'animate-spin' : ''} />
              重新检测
            </button>
            <button
              type="button"
              className="btn btn-ghost btn-sm h-8 w-8 min-w-0 px-0"
              aria-label="关闭体检中心"
              onClick={onClose}
            >
              <X size={16} weight="bold" />
            </button>
          </div>
        </header>

        <div className="flex-1 space-y-4 overflow-y-auto p-6">
          {loading ? (
            <div className="flex flex-col items-center justify-center gap-3 py-16 text-base-content/70">
              <span className="loading loading-spinner loading-md text-primary" />
              <p className="text-sm">正在多线程计算 dHash / aHash 感知指纹…</p>
            </div>
          ) : groups.length === 0 ? (
            <div className="flex flex-col items-center justify-center gap-2 rounded-2xl border border-base-300/70 bg-base-200/35 py-14 text-center">
              <Check size={34} weight="bold" className="text-success" />
              <p className="text-base font-semibold">壁纸库非常干净，未发现重复或高度相似壁纸</p>
              <p className="text-sm text-base-content/60">
                当前 {result?.scannedCount ?? 0} 个壁纸包均无明显画面重复。
              </p>
            </div>
          ) : (
            groups.map((group, groupIdx) => (
              <section
                key={group.groupId}
                className="rounded-2xl border border-base-300/80 bg-base-200/30 p-4"
              >
                <div className="mb-3 flex flex-wrap items-center justify-between gap-2">
                  <div className="flex items-center gap-2">
                    <span className="badge badge-sm badge-neutral">第 {groupIdx + 1} 组</span>
                    <span className="text-sm font-semibold">{group.members.length} 项画面相似</span>
                  </div>
                  <span className="text-xs font-medium text-base-content/65">
                    清理可节省约 {formatBytes(group.reclaimableBytes)}
                  </span>
                </div>

                <div className="grid grid-cols-1 gap-3 md:grid-cols-2 lg:grid-cols-3">
                  {group.members.map(member => {
                    const item = member.item
                    const checked = selectedIds.has(item.id)
                    const thumb = item.previewUrl || item.mediaUrl
                    const diskBytes = item.folderSize || item.fileSize || 0

                    return (
                      <div
                        key={item.id}
                        className={`flex flex-col justify-between rounded-2xl border p-3 transition-colors ${
                          member.recommendedKeep
                            ? 'border-emerald-500/40 bg-emerald-500/6'
                            : checked
                              ? 'border-rose-500/50 bg-rose-500/7'
                              : 'border-base-300/70 bg-base-100'
                        }`}
                      >
                        <div>
                          <div className="relative aspect-video w-full overflow-hidden rounded-xl bg-base-300/40">
                            <img src={thumb} alt={item.title} className="h-full w-full object-cover" />
                            <span
                              className={`absolute top-2 left-2 rounded-full px-2 py-0.5 text-[11px] font-semibold backdrop-blur-md ${
                                member.recommendedKeep
                                  ? 'bg-emerald-600 text-white'
                                  : 'bg-black/68 text-white'
                              }`}
                            >
                              {member.matchReason}
                            </span>
                            {!member.recommendedKeep ? (
                              <input
                                type="checkbox"
                                className="checkbox checkbox-sm checkbox-error absolute top-2 right-2 bg-base-100/90"
                                checked={checked}
                                onChange={() => toggleId(item.id)}
                                aria-label={`选择清理 ${item.title}`}
                              />
                            ) : null}
                          </div>

                          <p className="mt-2.5 truncate text-sm font-semibold">
                            {item.title}
                          </p>
                          <p className="mt-0.5 text-xs text-base-content/60">
                            {item.type === 'video' ? '视频' : '图片'} · {item.resolution || '未知分辨率'} · {formatBytes(diskBytes)}
                          </p>
                          <p className="text-[11px] text-base-content/45">
                            工坊 ID: {item.workshopId}
                          </p>
                        </div>

                        <div className="mt-2.5 flex items-center justify-between gap-1.5 border-t border-base-300/50 pt-2">
                          <button
                            type="button"
                            className="btn btn-xs btn-ghost"
                            onClick={() => onPreview?.(item)}
                          >
                            <Eye size={13} weight="bold" />
                            对比大图
                          </button>
                          <button
                            type="button"
                            className="btn btn-xs btn-ghost"
                            disabled={!isNative}
                            onClick={() => onOpenWorkshop?.(item)}
                          >
                            <Compass size={13} weight="bold" />
                            工坊退订
                          </button>
                          {!member.recommendedKeep ? (
                            <button
                              type="button"
                              className={`btn btn-xs ${checked ? 'btn-error btn-soft' : 'btn-ghost'}`}
                              onClick={() => toggleId(item.id)}
                            >
                              {checked ? '已选清理' : '保留此项'}
                            </button>
                          ) : (
                            <span className="px-2 text-[11px] font-semibold text-emerald-600 dark:text-emerald-400">
                              保留最优
                            </span>
                          )}
                        </div>
                      </div>
                    )
                  })}
                </div>
              </section>
            ))
          )}
        </div>

        <footer className="flex shrink-0 flex-wrap items-center justify-between gap-3 border-t border-base-300/70 bg-base-100 px-6 py-3.5">
          <div className="flex flex-wrap items-center gap-2 text-xs text-base-content/65">
            {groups.length > 0 ? (
              <>
                <button
                  type="button"
                  className="btn btn-xs btn-ghost"
                  onClick={() => {
                    setConfirmStep(false)
                    setSelectedIds(new Set(suggestedIds))
                  }}
                >
                  选中全部冗余推荐 ({suggestedIds.length})
                </button>
                <button
                  type="button"
                  className="btn btn-xs btn-ghost"
                  onClick={() => {
                    setConfirmStep(false)
                    setSelectedIds(new Set())
                  }}
                >
                  全部取消
                </button>
              </>
            ) : null}
            <span>删除仅移入 Windows 回收站，可随时还原；若开启 Steam 云同步请顺手退订。</span>
          </div>

          <div className="flex items-center gap-2">
            {confirmStep ? (
              <>
                <button
                  type="button"
                  className="btn btn-sm btn-ghost"
                  onClick={() => setConfirmStep(false)}
                >
                  再想想
                </button>
                <button
                  type="button"
                  className="btn btn-sm btn-error"
                  disabled={!isNative || selectedIds.size === 0}
                  onClick={() => {
                    setConfirmStep(false)
                    onRecycleIds?.([...selectedIds])
                  }}
                >
                  <Trash size={14} weight="bold" />
                  确认移入回收站 ({selectedIds.size} 项 · 省 {formatBytes(selectedBytes)})
                </button>
              </>
            ) : (
              <button
                type="button"
                className="btn btn-sm btn-error"
                disabled={!isNative || selectedIds.size === 0 || loading}
                onClick={() => setConfirmStep(true)}
              >
                <Trash size={14} weight="bold" />
                清理选中冗余 ({selectedIds.size} 项 · {formatBytes(selectedBytes)})
              </button>
            )}
          </div>
        </footer>
      </motion.div>
    </div>,
    document.body,
  )
}
