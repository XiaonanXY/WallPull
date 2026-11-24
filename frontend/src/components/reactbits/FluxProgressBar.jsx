import { StopCircle } from '@phosphor-icons/react'
import { BorderBeam } from '@appica/ui-react/border-beam'
import { Progress } from '@appica/ui-react/progress'
import { formatBytes } from '../../appConfig.js'
import StatusMark from './StatusMark.jsx'

function formatEta(seconds) {
  if (!Number.isFinite(seconds) || seconds <= 0) return null
  const s = Math.round(seconds)
  if (s < 60) return `剩余约 ${s} 秒`
  const m = Math.floor(s / 60)
  const rem = s % 60
  return rem > 0 ? `剩余约 ${m} 分 ${rem} 秒` : `剩余约 ${m} 分钟`
}

export default function FluxProgressBar({
  progress,
  compact = false,
  cancelling = false,
  onCancel = null,
  className = '',
}) {
  if (!progress) return null

  const filePct = Number.isFinite(progress.filePercent)
    ? Math.max(0, Math.min(100, progress.filePercent))
    : null
  const overallPct = Number.isFinite(progress.overallPercent)
    ? Math.max(0, Math.min(100, progress.overallPercent))
    : null
  const displayPct = filePct ?? overallPct
  const etaLabel = formatEta(progress.etaSeconds)
  const savedLabel = Number(progress.savedBytes) > 0 ? formatBytes(progress.savedBytes) : null
  const showCancel = Boolean(onCancel && progress.cancellable !== false)

  if (compact) {
    return (
      <div
        role="status"
        aria-live="polite"
        className={`flex items-center gap-3 rounded-full border border-base-300/85 bg-base-100/92 px-4 py-2 shadow-lg backdrop-blur-xl ${className}`}
      >
        <StatusMark
          status="running"
          progress={displayPct !== null ? displayPct / 100 : undefined}
          size={18}
          strokeWidth={2.2}
          color="var(--color-primary)"
        />
        <div className="min-w-0 flex-1 space-y-1.5">
          <div className="flex items-center justify-between gap-3 text-xs">
            <span className="truncate font-medium text-base-content">
              {progress.message || '正在处理…'}
            </span>
            <span className="shrink-0 font-semibold tabular-nums text-primary">
              {displayPct !== null ? `${Math.round(displayPct)}%` : ''}
            </span>
          </div>
          <Progress
            variant="bar"
            value={displayPct ?? 0}
            thickness={4}
            indicatorColor="var(--color-primary)"
            className="gap-0 **:data-[slot=progress-track]:bg-base-content/10"
          />
        </div>
        {showCancel ? (
          <button
            type="button"
            disabled={cancelling}
            onClick={onCancel}
            className="btn btn-ghost btn-xs h-7 shrink-0 gap-1 rounded-full px-2.5 text-base-content/75 hover:bg-error/12 hover:text-error"
          >
            <StopCircle size={14} weight="fill" />
            <span>{cancelling ? '终止中' : '停止'}</span>
          </button>
        ) : null}
      </div>
    )
  }

  return (
    <BorderBeam
      color="var(--color-primary)"
      length={16}
      thickness={1}
      speed={4.5}
      className={`rounded-2xl border border-base-300/80 bg-base-100/90 px-4 py-3 ${className}`}
    >
      <div role="status" aria-live="polite" className="space-y-2">
        <div className="flex flex-wrap items-center justify-between gap-2.5">
          <div className="flex min-w-0 flex-1 items-center gap-2.5">
            <StatusMark
              status="running"
              progress={displayPct !== null ? displayPct / 100 : undefined}
              size={18}
              strokeWidth={2.2}
              color="var(--color-primary)"
            />
            <span className="truncate text-xs font-medium text-base-content">
              {progress.message || '正在处理…'}
            </span>
            {savedLabel ? (
              <span className="shrink-0 rounded-full bg-emerald-500/12 px-2 py-0.5 text-[11px] font-semibold tabular-nums text-emerald-600 dark:text-emerald-400">
                已省 {savedLabel}
              </span>
            ) : null}
          </div>

          <div className="flex shrink-0 items-center gap-2.5">
            {etaLabel ? (
              <span className="text-[11px] tabular-nums text-base-content/55">
                {etaLabel}
              </span>
            ) : null}
            {displayPct !== null ? (
              <span className="text-xs font-semibold tabular-nums text-primary">
                {Math.round(displayPct)}%
              </span>
            ) : null}
            {showCancel ? (
              <button
                type="button"
                disabled={cancelling}
                onClick={onCancel}
                className="btn btn-ghost btn-xs h-7 gap-1 rounded-full px-2.5 text-error hover:bg-error/10"
              >
                <StopCircle size={14} weight="fill" />
                <span>{cancelling ? '正在终止…' : '停止任务'}</span>
              </button>
            ) : null}
          </div>
        </div>

        <Progress
          variant="bar"
          value={displayPct ?? 0}
          thickness={6}
          indicatorColor="var(--color-primary)"
          className="gap-0 **:data-[slot=progress-track]:bg-base-content/10"
        />
      </div>
    </BorderBeam>
  )
}
