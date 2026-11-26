import { useEffect, useState } from 'react'
import { createPortal } from 'react-dom'
import { AnimatePresence, motion, useReducedMotion } from 'motion/react'
import {
  DeviceTablet,
  MusicNotes,
  Pause,
  Play,
  SkipBack,
  SkipForward,
  Stop,
  X,
} from '@phosphor-icons/react'
import { formatBytes } from '../../appConfig.js'
import RollingDigits from './RollingDigits.jsx'

const METER_DURATIONS = ['0.48s', '0.62s', '0.43s', '0.57s', '0.46s', '0.64s']
const METER_DELAYS = ['-0.15s', '-0.42s', '-0.08s', '-0.31s', '-0.24s', '-0.53s']

function LevelMeter({ playing }) {
  return (
    <span aria-hidden="true" className="inline-flex h-4 items-center gap-[2px]">
      {METER_DURATIONS.map((dur, idx) => (
        <span
          key={idx}
          className={`wp-level-bar block w-[2.5px] rounded-full bg-primary ${playing ? 'is-playing' : ''}`}
          style={{
            height: '14px',
            '--wp-dur': dur,
            '--wp-delay': METER_DELAYS[idx],
          }}
        />
      ))}
    </span>
  )
}

function CircularRing({ fraction = 0, size = 24 }) {
  const clamped = Math.min(1, Math.max(0.02, fraction))
  const r = (size - 4) / 2
  const circ = 2 * Math.PI * r
  const offset = circ * (1 - clamped)
  return (
    <svg width={size} height={size} viewBox={`0 0 ${size} ${size}`} className="-rotate-90 shrink-0">
      <circle
        cx={size / 2}
        cy={size / 2}
        r={r}
        fill="none"
        stroke="currentColor"
        strokeOpacity="0.18"
        strokeWidth="2.5"
      />
      <circle
        cx={size / 2}
        cy={size / 2}
        r={r}
        fill="none"
        stroke="var(--color-primary)"
        strokeWidth="2.5"
        strokeLinecap="round"
        strokeDasharray={circ}
        strokeDashoffset={offset}
        style={{ transition: 'stroke-dashoffset 160ms ease' }}
      />
    </svg>
  )
}

function formatClock(sec) {
  if (!Number.isFinite(sec) || sec <= 0) return '0:00'
  const m = Math.floor(sec / 60)
  const s = Math.floor(sec % 60)
  return `${m}:${String(s).padStart(2, '0')}`
}

export default function FloatingActivityIsland({
  localsendProgress,
  toolboxProgress,
  toolboxBusy = false,
  toolboxCancelling = false,
  onCancelToolbox,
  globalAudio,
  onToggleAudio,
  onPrevAudio,
  onNextAudio,
  onSeekAudio,
  onCloseAudio,
  isDark = false,
  raised = false,
}) {
  const reduced = useReducedMotion()
  const [expanded, setExpanded] = useState(false)
  const [focusMode, setFocusMode] = useState('transfer')

  const hasTransfer = Boolean(localsendProgress)
  const hasToolbox = Boolean(toolboxBusy && toolboxProgress)
  const hasAudio = Boolean(globalAudio?.track)
  const primaryWork = hasTransfer ? 'transfer' : (hasToolbox ? 'toolbox' : null)

  useEffect(() => {
    if (hasTransfer) setFocusMode('transfer')
    else if (hasToolbox) setFocusMode('toolbox')
    else if (hasAudio) setFocusMode('audio')
  }, [hasTransfer, hasToolbox, hasAudio])

  if (typeof document === 'undefined' || (!hasTransfer && !hasToolbox && !hasAudio)) {
    return null
  }

  const activeKind = (() => {
    if (focusMode === 'transfer' && hasTransfer) return 'transfer'
    if (focusMode === 'toolbox' && hasToolbox) return 'toolbox'
    if (focusMode === 'audio' && hasAudio) return 'audio'
    return primaryWork || 'audio'
  })()

  const secondaryKind = (() => {
    if (activeKind !== 'audio' && hasAudio) return 'audio'
    if (activeKind === 'audio' && primaryWork) return primaryWork
    if (activeKind === 'transfer' && hasToolbox) return 'toolbox'
    return null
  })()

  const transferFraction = hasTransfer
    ? (localsendProgress.totalBytes > 0
        ? (localsendProgress.bytesSent || 0) / localsendProgress.totalBytes
        : (localsendProgress.total > 0 ? (localsendProgress.current || 1) / localsendProgress.total : 0.05))
    : 0

  const toolboxFraction = hasToolbox
    ? (typeof toolboxProgress.overallPercent === 'number'
        ? toolboxProgress.overallPercent / 100
        : (toolboxProgress.totalCount > 0 ? toolboxProgress.currentIndex / toolboxProgress.totalCount : 0.08))
    : 0

  const surfaceClass = isDark
    ? 'border-white/12 bg-[#161620]/94 text-base-content'
    : 'border-base-300/90 bg-white/95 text-base-content'

  return createPortal(
    <div
      style={{ zIndex: 196 }}
      className={`pointer-events-none fixed right-5 flex items-end gap-2 transition-all duration-200 ${
        raised ? 'bottom-[84px]' : 'bottom-6'
      }`}
    >
      {secondaryKind ? (
        <motion.button
          type="button"
          layout={!reduced}
          onClick={() => setFocusMode(secondaryKind)}
          aria-label={secondaryKind === 'audio' ? '切换到后台音乐控制' : '切换到后台传输任务'}
          initial={reduced ? false : { opacity: 0, scale: 0.85 }}
          animate={{ opacity: 1, scale: 1 }}
          exit={reduced ? undefined : { opacity: 0, scale: 0.85 }}
          className={`pointer-events-auto flex h-10 w-10 items-center justify-center rounded-full border shadow-xl backdrop-blur-2xl transition hover:scale-105 ${surfaceClass}`}
        >
          {secondaryKind === 'audio' ? (
            <LevelMeter playing={Boolean(globalAudio?.playing)} />
          ) : (
            <CircularRing fraction={secondaryKind === 'transfer' ? transferFraction : toolboxFraction} size={22} />
          )}
        </motion.button>
      ) : null}

      <motion.div
        layout={!reduced}
        initial={reduced ? false : { opacity: 0, y: 14, scale: 0.95 }}
        animate={{ opacity: 1, y: 0, scale: 1 }}
        exit={reduced ? undefined : { opacity: 0, y: 10, scale: 0.95 }}
        transition={reduced ? { duration: 0.1 } : { type: 'spring', stiffness: 420, damping: 32 }}
        className={`pointer-events-auto overflow-hidden border shadow-2xl backdrop-blur-2xl ${
          expanded ? 'w-80 rounded-[22px] p-3.5' : 'rounded-full px-3.5 py-2'
        } ${surfaceClass}`}
      >
        {activeKind === 'transfer' && hasTransfer ? (
          <div>
            <div
              onClick={() => setExpanded(prev => !prev)}
              className="flex cursor-pointer items-center gap-2.5"
            >
              <span className="flex h-7 w-7 shrink-0 items-center justify-center rounded-full bg-primary/14 text-primary">
                <DeviceTablet size={14} weight="bold" />
              </span>
              <div className="min-w-0 flex-1">
                <p className="truncate text-xs font-semibold">
                  {localsendProgress.title || '传输到平板'}
                </p>
                <p className="text-[11px] text-base-content/60">
                  {localsendProgress.stage === 'preparing' ? (
                    '视频适配转码中…'
                  ) : (
                    <RollingDigits
                      value={`${localsendProgress.current || 1}/${localsendProgress.total || 1}${(localsendProgress.bytesPerSecond || 0) >= 102400 ? ` · ${(localsendProgress.bytesPerSecond / 1048576).toFixed(1)} MB/s` : ''}`}
                    />
                  )}
                </p>
              </div>
              <CircularRing fraction={transferFraction} size={24} />
            </div>
            {expanded ? (
              <div className="mt-2.5 border-t border-base-300/60 pt-2">
                <progress
                  className="progress progress-primary h-1.5 w-full"
                  value={Math.round(transferFraction * 100)}
                  max={100}
                />
                {localsendProgress.totalBytes > 0 ? (
                  <p className="mt-1 flex justify-between text-[11px] text-base-content/60">
                    <RollingDigits value={formatBytes(localsendProgress.bytesSent || 0)} />
                    <span>{formatBytes(localsendProgress.totalBytes)}</span>
                  </p>
                ) : null}
              </div>
            ) : null}
          </div>
        ) : null}

        {activeKind === 'toolbox' && hasToolbox ? (
          <div>
            <div
              onClick={() => setExpanded(prev => !prev)}
              className="flex cursor-pointer items-center gap-2.5"
            >
              <CircularRing fraction={toolboxFraction} size={24} />
              <div className="min-w-0 flex-1">
                <p className="truncate text-xs font-semibold">
                  {toolboxProgress.message || '后台处理中…'}
                </p>
                {toolboxProgress.totalCount > 0 ? (
                  <p className="text-[11px] text-base-content/60">
                    <RollingDigits value={`${toolboxProgress.currentIndex} / ${toolboxProgress.totalCount}`} />
                  </p>
                ) : null}
              </div>
              {toolboxProgress.cancellable !== false && onCancelToolbox ? (
                <button
                  type="button"
                  disabled={toolboxCancelling}
                  onClick={e => {
                    e.stopPropagation()
                    onCancelToolbox()
                  }}
                  aria-label="停止后台任务"
                  className="btn btn-xs btn-error btn-soft h-6 min-h-0 rounded-full px-2 text-[11px]"
                >
                  <Stop size={11} weight="fill" />
                  <span>{toolboxCancelling ? '停止中' : '停止'}</span>
                </button>
              ) : null}
            </div>
            {expanded ? (
              <progress
                className="progress progress-primary mt-2 h-1.5 w-full"
                value={Math.round(toolboxFraction * 100)}
                max={100}
              />
            ) : null}
          </div>
        ) : null}

        {activeKind === 'audio' && hasAudio ? (
          <div>
            <div
              onClick={() => setExpanded(prev => !prev)}
              className="flex cursor-pointer items-center gap-2.5"
            >
              {globalAudio.item?.previewUrl ? (
                <img
                  src={globalAudio.item.previewUrl}
                  alt={globalAudio.item.title}
                  className="h-7 w-7 shrink-0 rounded-full object-cover ring-1 ring-base-300"
                />
              ) : (
                <span className="flex h-7 w-7 shrink-0 items-center justify-center rounded-full bg-primary/14 text-primary">
                  <MusicNotes size={14} weight="fill" />
                </span>
              )}
              <div className="min-w-0 flex-1">
                <p className="truncate text-xs font-semibold">
                  {globalAudio.track.name}
                </p>
                {expanded ? (
                  <p className="truncate text-[11px] text-base-content/60">
                    {globalAudio.item?.title}
                  </p>
                ) : null}
              </div>
              <LevelMeter playing={Boolean(globalAudio.playing)} />
              <button
                type="button"
                aria-label={globalAudio.playing ? '暂停音乐' : '播放音乐'}
                onClick={e => {
                  e.stopPropagation()
                  onToggleAudio?.()
                }}
                className="inline-flex h-7 w-7 shrink-0 items-center justify-center rounded-full bg-primary text-primary-content transition hover:brightness-110"
              >
                {globalAudio.playing ? <Pause size={13} weight="fill" /> : <Play size={13} weight="fill" />}
              </button>
              <button
                type="button"
                aria-label="关闭音乐浮窗"
                onClick={e => {
                  e.stopPropagation()
                  onCloseAudio?.()
                }}
                className="inline-flex h-6 w-6 shrink-0 items-center justify-center rounded-full text-base-content/50 transition hover:bg-base-content/10 hover:text-base-content"
              >
                <X size={12} weight="bold" />
              </button>
            </div>

            <AnimatePresence>
              {expanded ? (
                <motion.div
                  initial={reduced ? false : { opacity: 0, height: 0 }}
                  animate={{ opacity: 1, height: 'auto' }}
                  exit={reduced ? undefined : { opacity: 0, height: 0 }}
                  className="mt-2.5 overflow-hidden border-t border-base-300/60 pt-2.5"
                >
                  <div className="flex items-center gap-2 text-[11px] text-base-content/60">
                    <RollingDigits value={formatClock(globalAudio.currentTime)} />
                    <input
                      type="range"
                      aria-label="音乐播放进度"
                      min={0}
                      max={globalAudio.duration || 100}
                      step={0.1}
                      value={Math.min(globalAudio.currentTime || 0, globalAudio.duration || 100)}
                      disabled={!globalAudio.duration}
                      onChange={e => onSeekAudio?.(Number(e.target.value))}
                      className="range range-primary range-xs flex-1"
                    />
                    <RollingDigits value={formatClock(globalAudio.duration)} />
                  </div>
                  <div className="mt-2 flex items-center justify-center gap-3">
                    <button
                      type="button"
                      aria-label="上一首"
                      onClick={onPrevAudio}
                      className="btn btn-ghost btn-xs h-7 w-7 rounded-full p-0"
                    >
                      <SkipBack size={14} weight="fill" />
                    </button>
                    <button
                      type="button"
                      aria-label={globalAudio.playing ? '暂停' : '播放'}
                      onClick={onToggleAudio}
                      className="btn btn-primary btn-xs h-8 w-8 rounded-full p-0"
                    >
                      {globalAudio.playing ? <Pause size={15} weight="fill" /> : <Play size={15} weight="fill" />}
                    </button>
                    <button
                      type="button"
                      aria-label="下一首"
                      onClick={onNextAudio}
                      className="btn btn-ghost btn-xs h-7 w-7 rounded-full p-0"
                    >
                      <SkipForward size={14} weight="fill" />
                    </button>
                  </div>
                </motion.div>
              ) : null}
            </AnimatePresence>
          </div>
        ) : null}
      </motion.div>
    </div>,
    document.body,
  )
}
