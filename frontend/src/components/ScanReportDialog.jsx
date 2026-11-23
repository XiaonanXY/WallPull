import { useCallback, useEffect, useId, useRef, useState } from 'react'
import { createPortal } from 'react-dom'
import { AnimatePresence, motion } from 'motion/react'

const STATE_LABELS = {
  success: '成功',
  warning: '已纠正',
  failed: '失败',
  skipped: '跳过',
}

const STATE_DOT_CLASSES = {
  success: 'bg-success',
  warning: 'bg-info',
  failed: 'bg-error',
  skipped: 'bg-warning',
}

export default function ScanReportDialog({ open, report, onClose }) {
  const [stateFilter, setStateFilter] = useState('all')
  const titleId = useId()
  const panelRef = useRef(null)
  const previousFocusRef = useRef(null)

  useEffect(() => {
    if (!open) return undefined
    previousFocusRef.current = document.activeElement
    setStateFilter('all')
    const frame = requestAnimationFrame(() => {
      panelRef.current?.focus({ preventScroll: true })
    })
    return () => {
      cancelAnimationFrame(frame)
      previousFocusRef.current?.focus?.({ preventScroll: true })
    }
  }, [open])

  const handleClose = useCallback(() => {
    onClose?.()
  }, [onClose])

  useEffect(() => {
    if (!open) return undefined
    const onKeyDown = event => {
      if (event.key === 'Escape') handleClose()
    }
    globalThis.addEventListener('keydown', onKeyDown)
    return () => globalThis.removeEventListener('keydown', onKeyDown)
  }, [handleClose, open])

  const filterTabs = report
    ? [
        { value: 'all', label: `全部 ${report.discoveredProjects ?? 0}` },
        { value: 'success', label: `成功 ${report.successfulProjects ?? 0}` },
        { value: 'failed', label: `失败 ${report.failedProjects ?? 0}` },
        { value: 'skipped', label: `未解析 ${report.skippedProjects ?? 0}` },
      ]
    : []

  const entries = (report?.entries ?? []).filter(entry => {
    if (stateFilter === 'all') return true
    if (stateFilter === 'success') return entry.state === 'success' || entry.state === 'warning'
    return entry.state === stateFilter
  })

  return createPortal(
    <AnimatePresence>
      {open ? (
        <motion.div
          className="fixed inset-0 z-50 flex items-center justify-center bg-black/50 p-4 sm:p-6 backdrop-blur-[4px]"
          initial={{ opacity: 0 }}
          animate={{ opacity: 1 }}
          exit={{ opacity: 0 }}
          transition={{ duration: 0.16 }}
          onMouseDown={event => {
            if (event.target === event.currentTarget) handleClose()
          }}
        >
          <motion.div
            ref={panelRef}
            role="dialog"
            aria-modal="true"
            aria-labelledby={titleId}
            tabIndex={-1}
            className="flex max-h-[calc(100vh-48px)] w-full max-w-4xl flex-col rounded-[22px] border border-base-300 bg-base-100 p-6 text-base-content shadow-2xl outline-none"
            initial={{ opacity: 0, scale: 0.96, y: 12 }}
            animate={{ opacity: 1, scale: 1, y: 0 }}
            exit={{ opacity: 0, scale: 0.98, y: 6 }}
            transition={{ type: 'spring', duration: 0.28, bounce: 0 }}
          >
            <div className="flex flex-wrap items-center justify-between gap-4">
              <div>
                <h2 id={titleId} className="text-lg font-semibold tracking-tight">
                  解析报告
                </h2>
                <p className="mt-0.5 text-sm text-base-content/60">
                  创意工坊项目扫描、解包与媒体校验明细
                </p>
              </div>
              {report ? (
                <div className="wv-segmented" role="group" aria-label="按状态筛选解析结果">
                  {filterTabs.map(tab => {
                    const active = stateFilter === tab.value
                    return (
                      <button
                        key={tab.value}
                        type="button"
                        className="wv-segmented__item"
                        aria-pressed={active}
                        onClick={() => setStateFilter(tab.value)}
                      >
                        {active ? (
                          <motion.span
                            layoutId="report-filter-pill"
                            className="wv-segmented__pill"
                            transition={{ type: 'spring', duration: 0.28, bounce: 0 }}
                          />
                        ) : null}
                        <span className="relative z-10">{tab.label}</span>
                      </button>
                    )
                  })}
                </div>
              ) : null}
            </div>

            {report ? (
              <div className="mt-4 min-h-0 flex-1 overflow-auto overscroll-contain rounded-xl border border-base-300/70">
                <table className="table table-sm table-pin-rows">
                  <thead>
                    <tr className="bg-base-200/70 text-xs text-base-content/65">
                      <th className="w-24">状态</th>
                      <th>正式标题</th>
                      <th className="w-36">Workshop ID</th>
                      <th>说明</th>
                    </tr>
                  </thead>
                  <tbody>
                    {entries.map((entry, index) => (
                      <tr key={`${entry.workshopId}-${index}`} className="hover:bg-base-200/40">
                        <td>
                          <span className="inline-flex items-center gap-1.5 text-xs font-medium">
                            <span
                              className={`h-2 w-2 rounded-full ${
                                STATE_DOT_CLASSES[entry.state] ?? 'bg-base-content/40'
                              }`}
                            />
                            {STATE_LABELS[entry.state] ?? entry.state}
                          </span>
                        </td>
                        <td className="max-w-60 truncate font-medium">
                          {entry.title}
                        </td>
                        <td className="font-mono text-xs text-base-content/65">
                          {entry.workshopId}
                        </td>
                        <td className="text-sm text-base-content/75">{entry.message}</td>
                      </tr>
                    ))}
                    {entries.length === 0 ? (
                      <tr>
                        <td colSpan={4} className="py-10 text-center text-sm text-base-content/55">
                          当前筛选状态下没有记录
                        </td>
                      </tr>
                    ) : null}
                  </tbody>
                </table>
              </div>
            ) : (
              <div className="mt-5 rounded-xl border border-base-300/70 bg-base-200/40 px-4 py-8 text-center text-sm text-base-content/65">
                完成一次扫描后，这里会显示详细解析结果。
              </div>
            )}

            <div className="mt-4 flex shrink-0 justify-end">
              <button type="button" className="btn btn-ghost btn-sm" onClick={handleClose}>
                关闭
              </button>
            </div>
          </motion.div>
        </motion.div>
      ) : null}
    </AnimatePresence>,
    document.body,
  )
}
