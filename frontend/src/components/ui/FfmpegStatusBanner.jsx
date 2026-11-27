import { ArrowsClockwise, FolderOpen, FolderSimplePlus, X } from '@phosphor-icons/react'

export default function FfmpegStatusBanner({
  status = null,
  isNative = false,
  compact = false,
  onRefresh,
  onOpenToolsDir,
  onPickExe,
  onClearCustom,
}) {
  const available = Boolean(status?.available)
  const ffprobeOk = Boolean(status?.ffprobeAvailable)
  const pathText = status?.ffmpegPath || ''
  const hasCustom = Boolean(status?.customPath)

  if (compact) {
    if (available) return null
    return (
      <div className="flex flex-wrap items-center justify-between gap-2 rounded-xl border border-base-300/70 bg-base-200/55 px-3.5 py-2 text-xs text-base-content">
        <span className="min-w-0 flex-1 truncate text-base-content/75">
          未检测到 FFmpeg，视频转码与瘦身功能暂不可用
        </span>
        <div className="flex shrink-0 flex-wrap items-center gap-1.5">
          <button
            type="button"
            className="btn btn-ghost btn-xs h-7 px-2.5"
            disabled={!isNative}
            onClick={onOpenToolsDir}
          >
            <FolderOpen size={13} weight="bold" />
            打开 Tools
          </button>
          <button
            type="button"
            className="btn btn-primary btn-xs h-7 px-2.5"
            disabled={!isNative}
            onClick={onPickExe}
          >
            <FolderSimplePlus size={13} weight="bold" />
            指定 ffmpeg.exe
          </button>
          <button
            type="button"
            className="btn btn-ghost btn-xs h-7 w-7 min-w-0 px-0"
            aria-label="重新检测 FFmpeg"
            disabled={!isNative}
            onClick={onRefresh}
          >
            <ArrowsClockwise size={13} weight="bold" />
          </button>
        </div>
      </div>
    )
  }

  return (
    <div className="flex flex-wrap items-center justify-between gap-3">
      <div className="min-w-0 flex-1">
        <p className="text-sm font-medium">FFmpeg 组件</p>
        <p className="mt-0.5 truncate text-xs text-base-content/60">
          {available
            ? `已就绪 · ${pathText}${ffprobeOk ? '' : '（缺 ffprobe）'}`
            : '未检测到（仅视频转码 / 瘦身需要）'}
        </p>
      </div>
      <div className="flex shrink-0 flex-wrap items-center gap-1.5">
        <button
          type="button"
          className="btn btn-ghost btn-xs h-7 px-2.5"
          disabled={!isNative}
          onClick={onOpenToolsDir}
        >
          打开 Tools
        </button>
        <button
          type="button"
          className={`btn btn-xs h-7 px-2.5 ${available ? 'btn-ghost' : 'btn-primary'}`}
          disabled={!isNative}
          onClick={onPickExe}
        >
          指定路径
        </button>
        {hasCustom ? (
          <button
            type="button"
            className="btn btn-ghost btn-xs h-7 px-2 text-base-content/70"
            disabled={!isNative}
            onClick={onClearCustom}
          >
            <X size={12} weight="bold" />
            恢复自动
          </button>
        ) : null}
        <button
          type="button"
          className="btn btn-ghost btn-xs h-7 w-7 min-w-0 px-0"
          aria-label="重新检测 FFmpeg"
          disabled={!isNative}
          onClick={onRefresh}
        >
          <ArrowsClockwise size={13} weight="bold" />
        </button>
      </div>
    </div>
  )
}
