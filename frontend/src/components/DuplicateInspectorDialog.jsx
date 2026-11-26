import { useEffect, useMemo, useState } from 'react'
import { createPortal } from 'react-dom'
import { motion } from 'motion/react'
import {
  ArrowsClockwise,
  Check,
  Columns,
  Compass,
  Eye,
  MagnifyingGlass,
  X,
} from '@phosphor-icons/react'
import { formatBytes } from '../appConfig.js'
import HoldToConfirmButton from './ui/HoldToConfirmButton.jsx'
import ImageCompareSlider from './ui/ImageCompareSlider.jsx'
import RollingDigits from './ui/RollingDigits.jsx'

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
  const [compareState, setCompareState] = useState(null)

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
      setCompareState(null)
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
    setCompareState(null)
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
              {(loading || result) ? (
                <p className="text-xs text-base-content/60">
                  {loading
                    ? '正在比对全库壁纸…'
                    : `共检测 ${result.scannedCount} 个 · 发现 ${groups.length} 组重复 · 可释放 ${formatBytes(result.totalReclaimableBytes)}`}
                </p>
              ) : null}
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
              <p className="text-base font-semibold">壁纸库非常干净，未发现重复壁纸</p>
            </div>
          ) : (
            groups.map((group, groupIdx) => {
              const imageMembers = group.members.filter(m => m.item?.type !== 'video' && (m.item?.mediaUrl || m.item?.previewUrl))
              const keepMember = imageMembers.find(m => m.recommendedKeep) || imageMembers[0]
              const candidateMembers = imageMembers.filter(m => m.item?.id !== keepMember?.item?.id)
              const canCompare = Boolean(keepMember && candidateMembers.length > 0)
              const isComparing = compareState?.groupId === group.groupId && canCompare
              const candIdx = isComparing ? Math.min(compareState.candidateIdx ?? 0, candidateMembers.length - 1) : 0
              const activeCand = isComparing ? candidateMembers[candIdx] : null

              return (
              <section
                key={group.groupId}
                className="rounded-2xl border border-base-300/80 bg-base-200/30 p-4"
              >
                <div className="mb-3 flex flex-wrap items-center justify-between gap-2">
                  <div className="flex items-center gap-2">
                    <span className="badge badge-sm badge-neutral">第 {groupIdx + 1} 组</span>
                    <span className="text-sm font-semibold">{group.members.length} 项画面相似</span>
                    {canCompare ? (
                      <button
                        type="button"
                        className={`btn btn-xs rounded-full ${isComparing ? 'btn-primary' : 'btn-ghost'}`}
                        onClick={() => setCompareState(isComparing ? null : { groupId: group.groupId, candidateIdx: 0 })}
                      >
                        <Columns size={13} weight="bold" />
                        <span>{isComparing ? '收起对比' : '像素对比'}</span>
                      </button>
                    ) : null}
                  </div>
                  <span className="text-xs font-medium text-base-content/65">
                    清理可节省约 <RollingDigits value={formatBytes(group.reclaimableBytes)} />
                  </span>
                </div>

                {isComparing && keepMember && activeCand ? (
                  <div className="mb-4 rounded-2xl border border-base-300/70 bg-base-100/80 p-3">
                    {candidateMembers.length > 1 ? (
                      <div className="mb-2.5 flex flex-wrap items-center gap-1.5">
                        <span className="text-[11px] font-medium text-base-content/60">对比目标：</span>
                        {candidateMembers.map((cm, cIdx) => (
                          <button
                            key={cm.item.id}
                            type="button"
                            onClick={() => setCompareState({ groupId: group.groupId, candidateIdx: cIdx })}
                            className={`btn btn-xs rounded-full ${cIdx === candIdx ? 'btn-primary' : 'btn-ghost'}`}
                          >
                            {cm.item.title}
                          </button>
                        ))}
                      </div>
                    ) : null}
                    <ImageCompareSlider
                      beforeSrc={keepMember.item.mediaUrl || keepMember.item.previewUrl}
                      afterSrc={activeCand.item.mediaUrl || activeCand.item.previewUrl}
                      beforeLabel={`保留最优 · ${keepMember.item.resolution || ''}`}
                      afterLabel={`候选 · ${activeCand.item.resolution || ''}`}
                      aspectRatio="16 / 9"
                      className="max-h-72"
                    />
                  </div>
                ) : null}

                <div className="grid grid-cols-1 gap-3 md:grid-cols-2 lg:grid-cols-3">
                  {group.members.map(member => {
                    const item = member.item
                    const checked = selectedIds.has(item.id)
                    const thumb = item.previewUrl || (item.type !== 'video' ? item.mediaUrl : '')
                    const diskBytes = item.folderSize || item.fileSize || 0
                    const isLocalImported = String(item.workshopId || '').startsWith('99') && String(item.workshopId || '').length >= 15

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
                            {thumb ? (
                              <img src={thumb} alt={item.title} className="h-full w-full object-cover" />
                            ) : (
                              <div className="flex h-full w-full items-center justify-center text-xs text-base-content/45">
                                视频壁纸
                              </div>
                            )}
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
                            {isLocalImported ? '本地跨端入库' : `工坊 ID: ${item.workshopId}`}
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
                          {!isLocalImported ? (
                            <button
                              type="button"
                              className="btn btn-xs btn-ghost"
                              disabled={!isNative}
                              onClick={() => onOpenWorkshop?.(item)}
                            >
                              <Compass size={13} weight="bold" />
                              工坊退订
                            </button>
                          ) : null}
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
              )
            })
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
                    setSelectedIds(new Set(suggestedIds))
                  }}
                >
                  选中全部冗余推荐 ({suggestedIds.length})
                </button>
                <button
                  type="button"
                  className="btn btn-xs btn-ghost"
                  onClick={() => {
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
            <HoldToConfirmButton
              tone="danger"
              duration={850}
              disabled={!isNative || selectedIds.size === 0 || loading}
              label={`按住移入回收站 (${selectedIds.size} 项 · ${formatBytes(selectedBytes)})`}
              confirmedLabel="已移入回收站"
              onConfirm={() => {
                onRecycleIds?.([...selectedIds])
              }}
            />
          </div>
        </footer>
      </motion.div>
    </div>,
    document.body,
  )
}
