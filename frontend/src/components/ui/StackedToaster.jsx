import { useEffect, useState } from 'react'
import { createPortal } from 'react-dom'
import { AnimatePresence, motion, useReducedMotion } from 'motion/react'
import { CheckCircle, FolderOpen, WarningCircle, X } from '@phosphor-icons/react'

function ToastCard({ toast, idx, total, expanded, isDark, onDismiss, onAction }) {
  const reduced = useReducedMotion()
  const reverseIdx = total - 1 - idx
  const isError = toast.status === 'error'
  const isRunning = toast.status === 'running'
  const surface = isDark ? 'rgba(24, 24, 34, 0.94)' : 'rgba(255, 255, 255, 0.96)'

  const yOffset = expanded ? -(reverseIdx * 52) : -(reverseIdx * 8)
  const scale = expanded ? 1 : Math.max(0.88, 1 - reverseIdx * 0.045)
  const opacity = !expanded && reverseIdx >= 3 ? 0 : 1

  return (
    <motion.div
      layout={!reduced}
      drag="x"
      dragConstraints={{ left: 0, right: 240 }}
      dragElastic={0.25}
      dragSnapToOrigin
      onDragEnd={(_, info) => {
        if (info.offset.x > 72 || info.velocity.x > 360) {
          onDismiss?.(toast.id)
        }
      }}
      initial={reduced ? { opacity: 0 } : { opacity: 0, y: 18, scale: 0.94 }}
      animate={{ opacity, y: yOffset, scale }}
      exit={reduced ? { opacity: 0 } : { opacity: 0, y: 12, scale: 0.92 }}
      transition={reduced ? { duration: 0.1 } : { type: 'spring', stiffness: 460, damping: 32 }}
      style={{ backgroundColor: surface, zIndex: 210 + idx }}
      className="pointer-events-auto absolute bottom-0 left-1/2 flex w-max max-w-[min(92vw,460px)] -translate-x-1/2 items-center gap-2.5 rounded-full border border-base-300/85 px-3.5 py-2 shadow-xl backdrop-blur-2xl"
    >
      {isRunning ? (
        <span className="loading loading-spinner loading-xs shrink-0 text-primary" />
      ) : isError ? (
        <WarningCircle size={17} weight="fill" className="shrink-0 text-error" />
      ) : (
        <CheckCircle size={17} weight="fill" className="shrink-0 text-success" />
      )}

      <span className="truncate text-xs font-semibold text-base-content">
        {toast.message}
      </span>

      {toast.actionLabel || toast.destination ? (
        <button
          type="button"
          onClick={() => onAction?.(toast)}
          className="inline-flex shrink-0 items-center gap-1 rounded-full bg-primary/14 px-2.5 py-0.5 text-[11px] font-semibold text-primary transition hover:bg-primary/22"
        >
          {toast.destination ? <FolderOpen size={12} weight="bold" /> : null}
          <span>{toast.actionLabel || '打开目录'}</span>
        </button>
      ) : null}

      <button
        type="button"
        aria-label="关闭通知"
        onClick={() => onDismiss?.(toast.id)}
        className="inline-flex h-5 w-5 shrink-0 items-center justify-center rounded-full text-base-content/50 transition hover:bg-base-content/10 hover:text-base-content"
      >
        <X size={12} weight="bold" />
      </button>
    </motion.div>
  )
}

export default function StackedToaster({
  toasts = [],
  onDismiss,
  onAction,
  onHoverChange,
  isDark = false,
  offsetBottomClass = 'bottom-6',
}) {
  const [expanded, setExpanded] = useState(false)
  const visible = toasts.slice(-4)

  useEffect(() => {
    if (visible.length === 0) {
      setExpanded(false)
      onHoverChange?.(false)
    }
  }, [onHoverChange, visible.length])

  if (typeof document === 'undefined') return null

  const containerHeight = expanded && visible.length > 1 ? 40 + (visible.length - 1) * 52 : 40

  return createPortal(
    <div
      style={{ zIndex: 210 }}
      onMouseEnter={() => {
        setExpanded(true)
        onHoverChange?.(true)
      }}
      onMouseLeave={() => {
        setExpanded(false)
        onHoverChange?.(false)
      }}
      className={`pointer-events-none fixed left-1/2 -translate-x-1/2 transition-all duration-200 ${offsetBottomClass}`}
    >
      <div className="relative w-[460px]" style={{ height: `${containerHeight}px` }}>
        <AnimatePresence initial={false}>
          {visible.map((toast, idx) => (
            <ToastCard
              key={toast.id}
              toast={toast}
              idx={idx}
              total={visible.length}
              expanded={expanded}
              isDark={isDark}
              onDismiss={onDismiss}
              onAction={onAction}
            />
          ))}
        </AnimatePresence>
      </div>
    </div>,
    document.body,
  )
}
