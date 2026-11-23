import { useEffect, useMemo, useState } from 'react'
import { createPortal } from 'react-dom'
import { AnimatePresence, motion } from 'motion/react'
import {
  ArrowsLeftRight,
  Check,
  FileZip,
  FolderOpen,
  HardDrive,
  Lightning,
  MagnifyingGlass,
  Package,
  SlidersHorizontal,
  Sparkle,
  Toolbox,
  Trash,
  Vault,
  X,
} from '@phosphor-icons/react'
import { formatBytes } from '../appConfig.js'

const LAYOUT_SCHEMES = [
  { id: 'sidebar', label: '侧面工作台' },
  { id: 'bento', label: '全景工作台' },
  { id: 'dual', label: '双页工作台' },
]

const SIDEBAR_SECTIONS = [
  { id: 'archive', label: '收藏典藏', icon: Vault },
  { id: 'cleanup', label: '空间清理', icon: SlidersHorizontal },
  { id: 'format', label: '格式转换', icon: ArrowsLeftRight },
  { id: 'unpack', label: '文件解包', icon: Package },
]

const DUAL_TABS = [
  { id: 'library', label: '壁纸库管理', icon: Vault },
  { id: 'media', label: '外部文件处理', icon: ArrowsLeftRight },
]

const FORMAT_GROUPS = [
  {
    title: '图片格式',
    items: [
      { value: 'png', label: 'PNG 无损' },
      { value: 'jpg', label: 'JPG' },
      { value: 'webp', label: 'WebP' },
      { value: 'avif', label: 'AVIF' },
      { value: 'ico', label: 'ICO 图标' },
    ],
  },
  {
    title: '视频处理',
    items: [
      { value: 'mp4', label: 'MP4 (H.264)' },
      { value: 'mp4-h265', label: 'MP4 (H.265 压缩)' },
      { value: 'gif', label: 'GIF 动图' },
      { value: 'mute-mp4', label: '静音视频' },
    ],
  },
  {
    title: '音频提取与互转',
    items: [
      { value: 'mp3', label: 'MP3' },
      { value: 'flac', label: 'FLAC 无损' },
      { value: 'wav', label: 'WAV' },
      { value: 'ogg', label: 'OGG' },
    ],
  },
]

const BADGE_OPTIONS = [
  { value: false, label: '隐藏已典藏标签' },
  { value: true, label: '启用已典藏标签' },
]

export default function SuperToolboxDialog({
  open,
  busy = false,
  onClose,
  wallpapers = [],
  favoriteIds = [],
  toolboxFiles = [],
  setToolboxFiles,
  migrationStatus = null,
  settings = {},
  persistSettings,
  isNative,
  sendNativeMessage,
  onOpenDuplicates,
}) {
  const [sidebarTab, setSidebarTab] = useState('archive')
  const [dualTab, setDualTab] = useState('library')
  const [targetFormat, setTargetFormat] = useState('png')
  const [selectedVideoIds, setSelectedVideoIds] = useState([])

  const layoutScheme = ['sidebar', 'bento', 'dual'].includes(settings?.toolboxLayout)
    ? settings.toolboxLayout
    : 'bento'

  const selectLayoutScheme = nextId => {
    if (nextId === layoutScheme) return
    persistSettings?.({ ...settings, toolboxLayout: nextId })
  }

  useEffect(() => {
    if (!open || !isNative) return
    sendNativeMessage('toolbox.migration.status', {})
  }, [isNative, open, sendNativeMessage])

  useEffect(() => {
    if (!open) return undefined
    const onKeyDown = e => {
      if (e.key === 'Escape') onClose?.()
    }
    globalThis.addEventListener('keydown', onKeyDown)
    return () => globalThis.removeEventListener('keydown', onKeyDown)
  }, [onClose, open])

  const archivedSet = useMemo(
    () => new Set(wallpapers.filter(w => w.isArchivedOffline).map(w => w.id)),
    [wallpapers],
  )
  const unarchivedFavoriteIds = useMemo(
    () => favoriteIds.filter(id => !archivedSet.has(id)),
    [archivedSet, favoriteIds],
  )
  const archivedFavoriteCount = favoriteIds.length - unarchivedFavoriteIds.length
  const showArchivedBadge = Boolean(settings?.showArchivedBadge)

  const largeVideos = useMemo(
    () =>
      wallpapers
        .filter(w => w.type === 'video' && (w.fileSize || 0) >= 35 * 1024 * 1024)
        .sort((a, b) => (b.fileSize || 0) - (a.fileSize || 0))
        .slice(0, 12),
    [wallpapers],
  )

  const toggleVideoId = id => {
    setSelectedVideoIds(prev => (prev.includes(id) ? prev.filter(x => x !== id) : [...prev, id]))
  }

  const activeVideoIds = useMemo(() => {
    const valid = new Set(largeVideos.map(v => v.id))
    return selectedVideoIds.filter(id => valid.has(id))
  }, [largeVideos, selectedVideoIds])

  const allVideosSelected =
    largeVideos.length > 0 && largeVideos.every(v => activeVideoIds.includes(v.id))

  const toggleAllVideos = () => {
    if (allVideosSelected) {
      setSelectedVideoIds([])
    } else {
      setSelectedVideoIds(largeVideos.map(v => v.id))
    }
  }

  const archiveButtonLabel = busy
    ? '正在典藏…'
    : favoriteIds.length > 0 && unarchivedFavoriteIds.length === 0
      ? '已全部典藏'
      : archivedFavoriteCount > 0
        ? `典藏新增收藏 (${unarchivedFavoriteIds.length})`
        : `典藏全部收藏 (${favoriteIds.length})`

  const renderArchiveCard = (compact = false) => (
    <div className={`rounded-2xl border border-base-300/75 bg-base-200/45 ${compact ? 'p-4' : 'p-5'}`}>
      <div className="flex flex-wrap items-start justify-between gap-2.5">
        <div className="min-w-0 flex-1">
          <div className="flex flex-wrap items-center gap-2">
            <Vault size={17} weight="fill" className="shrink-0 text-primary" />
            <h3 className="text-sm font-semibold">收藏典藏</h3>
            <span className="rounded-full bg-base-300/60 px-2.5 py-0.5 text-[11px] font-medium text-base-content/75 tabular-nums">
              已收藏 {favoriteIds.length} 项 · 已典藏 {archivedFavoriteCount} 项
            </span>
          </div>
          <p className="mt-1 text-xs leading-relaxed text-base-content/65">
            将收藏的壁纸保存为本地独立工程，取消订阅或原作品下架后仍可正常使用。
          </p>
        </div>
      </div>

      {migrationStatus?.archiveDirectory ? (
        <p className="mt-1.5 truncate text-[11px] text-base-content/50">
          典藏路径：{migrationStatus.archiveDirectory}
        </p>
      ) : null}

      <div className={`flex flex-wrap items-center justify-between gap-2.5 ${compact ? 'mt-3' : 'mt-4'}`}>
        <div className="flex flex-wrap items-center gap-2">
          <button
            type="button"
            className="btn btn-primary btn-sm"
            disabled={!isNative || busy || unarchivedFavoriteIds.length === 0}
            onClick={() =>
              sendNativeMessage('wallpapers.archive-offline.request', {
                ids: unarchivedFavoriteIds,
              })
            }
          >
            {busy ? <span className="loading loading-spinner loading-xs" /> : null}
            {archiveButtonLabel}
          </button>
          <button
            type="button"
            className="btn btn-ghost btn-sm gap-1.5"
            disabled={!isNative}
            onClick={() => sendNativeMessage('wallpapers.open-archive-dir.request', {})}
          >
            <FolderOpen size={15} weight="bold" />
            打开目录
          </button>
        </div>

        <div className="flex flex-wrap items-center gap-2">
          <span className="text-xs text-base-content/65">卡片典藏角标</span>
          <div className="wv-segmented" role="group" aria-label="卡片已典藏标签显示模式">
            {BADGE_OPTIONS.map(opt => {
              const active = showArchivedBadge === opt.value
              return (
                <button
                  key={String(opt.value)}
                  type="button"
                  className="wv-segmented__item text-xs"
                  aria-pressed={active}
                  onClick={() =>
                    persistSettings?.({ ...settings, showArchivedBadge: opt.value })
                  }
                >
                  {active ? (
                    <motion.span
                      layoutId="archive-badge-pill"
                      className="wv-segmented__pill"
                      transition={{ type: 'spring', duration: 0.28, bounce: 0 }}
                    />
                  ) : null}
                  <span className="relative z-10">{opt.label}</span>
                </button>
              )
            })}
          </div>
        </div>
      </div>
    </div>
  )

  const renderDuplicateCard = (compact = false) => (
    <div className={`flex flex-col justify-between rounded-2xl border border-base-300/75 bg-base-200/45 ${compact ? 'p-4' : 'p-5'}`}>
      <div className={compact ? 'flex items-center justify-between gap-3' : ''}>
        <div className="min-w-0">
          <h3 className="flex items-center gap-2 text-sm font-semibold">
            <MagnifyingGlass size={16} weight="bold" className="shrink-0 text-primary" />
            重复壁纸清理
          </h3>
          <p className="mt-1 text-xs leading-relaxed text-base-content/65">
            比对画面找出重复订阅或低清版本并移入回收站。
          </p>
        </div>
        {compact ? (
          <button
            type="button"
            className="btn btn-ghost btn-sm shrink-0"
            disabled={!isNative}
            onClick={() => {
              onClose?.()
              onOpenDuplicates?.()
            }}
          >
            扫描重复
          </button>
        ) : null}
      </div>
      {!compact ? (
        <div className="mt-4">
          <button
            type="button"
            className="btn btn-ghost btn-sm"
            disabled={!isNative}
            onClick={() => {
              onClose?.()
              onOpenDuplicates?.()
            }}
          >
            扫描重复壁纸
          </button>
        </div>
      ) : null}
    </div>
  )

  const renderMigrationCard = (compact = false) => (
    <div className={`flex flex-col justify-between rounded-2xl border border-base-300/75 bg-base-200/45 ${compact ? 'p-4' : 'p-5'}`}>
      <div>
        <h3 className="flex items-center gap-2 text-sm font-semibold">
          <HardDrive size={16} weight="fill" className="shrink-0 text-primary" />
          工坊目录迁移
        </h3>
        <p className="mt-1 break-all text-xs leading-relaxed text-base-content/65">
          {migrationStatus?.workshopRoot
            ? `当前目录：${migrationStatus.workshopRoot}（${formatBytes(migrationStatus.totalBytes)}）`
            : '正在检测工坊目录…'}
        </p>
      </div>
      {migrationStatus?.isJunction ? (
        <div className={`${compact ? 'mt-3' : 'mt-4'} flex flex-wrap items-center justify-between gap-2 rounded-xl bg-emerald-500/12 px-3 py-2 text-xs font-medium text-emerald-600 dark:text-emerald-400`}>
          <span className="min-w-0 truncate">已映射至：{migrationStatus.linkTarget}</span>
          <button
            type="button"
            className="btn btn-ghost btn-xs shrink-0 gap-1"
            disabled={!isNative || !migrationStatus.linkTarget}
            onClick={() =>
              sendNativeMessage('shell.open-path.request', {
                path: migrationStatus.linkTarget,
              })
            }
          >
            <FolderOpen size={13} weight="bold" />
            打开目录
          </button>
        </div>
      ) : (
        <div className={compact ? 'mt-3' : 'mt-4'}>
          <button
            type="button"
            className="btn btn-outline btn-primary btn-sm"
            disabled={!isNative || busy || !migrationStatus?.workshopRoot}
            onClick={() => sendNativeMessage('toolbox.migration.execute', {})}
          >
            {busy ? <span className="loading loading-spinner loading-xs" /> : null}
            迁移到其他磁盘
          </button>
        </div>
      )}
    </div>
  )

  const renderVideoSlimCard = (compact = false) => (
    <div
      className={`rounded-2xl border border-base-300/75 bg-base-200/45 ${
        compact ? 'flex min-h-0 flex-1 flex-col p-4' : 'p-5'
      }`}
    >
      <div className="flex flex-wrap items-center justify-between gap-2.5">
        <div>
          <h3 className="text-sm font-semibold">视频体积压缩</h3>
          <p className="mt-0.5 text-xs text-base-content/65">
            超过 35 MB 的视频可重编码为 H.265 节省空间，原文件自动移入回收站。
          </p>
        </div>
        <div className="flex items-center gap-1.5">
          {largeVideos.length > 0 ? (
            <button
              type="button"
              className="btn btn-ghost btn-sm"
              onClick={toggleAllVideos}
            >
              {allVideosSelected ? '清空选择' : '全选'}
            </button>
          ) : null}
          <button
            type="button"
            className="btn btn-primary btn-sm"
            disabled={
              !isNative ||
              busy ||
              (activeVideoIds.length === 0 && largeVideos.length === 0)
            }
            onClick={() =>
              sendNativeMessage('wallpapers.slim-videos.request', {
                ids:
                  activeVideoIds.length > 0
                    ? activeVideoIds
                    : largeVideos.map(v => v.id),
              })
            }
          >
            {busy ? <span className="loading loading-spinner loading-xs" /> : null}
            {busy
              ? '正在压缩…'
              : activeVideoIds.length > 0
                ? `压缩已选 (${activeVideoIds.length})`
                : `全部压缩 (${largeVideos.length})`}
          </button>
        </div>
      </div>

      {largeVideos.length > 0 ? (
        <div
          className={`mt-3 grid gap-2 ${
            compact
              ? 'min-h-40 flex-1 grid-cols-1 content-start overflow-y-auto pr-1'
              : 'grid-cols-1 sm:grid-cols-2'
          }`}
        >
          {largeVideos.map(video => {
            const checked = activeVideoIds.includes(video.id)
            return (
              <button
                key={video.id}
                type="button"
                aria-pressed={checked}
                onClick={() => toggleVideoId(video.id)}
                className={`flex w-full items-center justify-between gap-2.5 rounded-xl border px-3 py-2 text-left text-xs transition-colors ${
                  checked
                    ? 'border-primary bg-primary/10'
                    : 'border-base-300/75 bg-base-100/80 hover:border-base-content/25'
                }`}
              >
                <span className="flex min-w-0 items-center gap-2.5">
                  <span
                    className={`inline-flex h-4 w-4 shrink-0 items-center justify-center rounded-full border transition-colors ${
                      checked
                        ? 'border-primary bg-primary text-primary-content'
                        : 'border-base-content/30 bg-base-100 text-transparent'
                    }`}
                  >
                    <Check size={10} weight="bold" />
                  </span>
                  <span className="truncate font-medium">{video.title}</span>
                </span>
                <span className="shrink-0 font-semibold tabular-nums text-primary">
                  {formatBytes(video.fileSize)}
                </span>
              </button>
            )
          })}
        </div>
      ) : (
        <p className="mt-3 text-xs text-base-content/55">
          当前壁纸库内暂无超过 35 MB 的大型视频文件。
        </p>
      )}
    </div>
  )

  const renderFormatCard = (compact = false) => (
    <div className={`space-y-3.5 rounded-2xl border border-base-300/75 bg-base-200/45 ${compact ? 'p-4' : 'p-5'}`}>
      <div className="flex flex-wrap items-center justify-between gap-2">
        <h3 className="flex items-center gap-2 text-sm font-semibold">
          <ArrowsLeftRight size={16} weight="bold" className="text-primary" />
          格式转换
        </h3>
        <div className="flex items-center gap-1.5">
          {toolboxFiles.length > 0 ? (
            <button
              type="button"
              className="btn btn-ghost btn-xs"
              onClick={() => setToolboxFiles([])}
            >
              <Trash size={13} />
              清空
            </button>
          ) : null}
          <button
            type="button"
            className="btn btn-primary btn-xs rounded-full px-3"
            disabled={!isNative}
            onClick={() => sendNativeMessage('toolbox.media.pick', {})}
          >
            <FolderOpen size={13} weight="bold" />
            添加文件…
          </button>
        </div>
      </div>

      <div
        className={`grid grid-cols-1 gap-3.5 ${compact ? '' : 'lg:grid-cols-12'}`}
      >
        <div
          className={`rounded-xl border border-dashed border-base-300 bg-base-100/55 p-3 ${
            compact ? '' : 'min-h-48 lg:col-span-5'
          }`}
        >
          {toolboxFiles.length === 0 ? (
            <div
              className={`flex flex-col items-center justify-center gap-1.5 text-center ${
                compact ? 'py-4' : 'h-40'
              }`}
            >
              <Sparkle size={20} weight="duotone" className="text-primary/75" />
              <p className="text-xs text-base-content/70">
                支持图片、视频与常见音频文件
              </p>
              <button
                type="button"
                className="btn btn-ghost btn-xs"
                disabled={!isNative}
                onClick={() => sendNativeMessage('toolbox.media.pick', {})}
              >
                选择本地文件
              </button>
            </div>
          ) : (
            <ul className="max-h-48 space-y-1.5 overflow-y-auto pr-1">
              {toolboxFiles.map(file => (
                <li
                  key={file.path}
                  className="flex items-center justify-between gap-2 rounded-lg border border-base-300/70 bg-base-100 px-3 py-1.5 text-xs"
                >
                  <span className="truncate font-medium">{file.name}</span>
                  <div className="flex shrink-0 items-center gap-2 text-base-content/55">
                    <span className="badge badge-xs uppercase">{file.ext}</span>
                    <span className="tabular-nums">{formatBytes(file.size)}</span>
                    <button
                      type="button"
                      aria-label={`移除 ${file.name}`}
                      onClick={() =>
                        setToolboxFiles(prev => prev.filter(f => f.path !== file.path))
                      }
                      className="inline-flex h-5 w-5 items-center justify-center rounded-full text-base-content/50 hover:bg-base-content/10 hover:text-error"
                    >
                      <X size={11} weight="bold" />
                    </button>
                  </div>
                </li>
              ))}
            </ul>
          )}
        </div>

        <div className={`space-y-3 ${compact ? '' : 'lg:col-span-7'}`}>
          <div className="space-y-2.5 rounded-xl border border-base-300/70 bg-base-100/55 p-3">
            {FORMAT_GROUPS.map(group => (
              <div key={group.title} className="space-y-1">
                <p className="text-[11px] font-semibold text-base-content/55">
                  {group.title}
                </p>
                <div className="flex flex-wrap gap-1.5">
                  {group.items.map(opt => (
                    <button
                      key={opt.value}
                      type="button"
                      onClick={() => setTargetFormat(opt.value)}
                      className={`btn btn-xs h-7 px-3 ${
                        targetFormat === opt.value
                          ? 'btn-primary'
                          : 'btn-ghost bg-base-200/70'
                      }`}
                    >
                      {opt.label}
                    </button>
                  ))}
                </div>
              </div>
            ))}
          </div>

          <div className="flex flex-wrap items-center justify-between gap-2">
            <p className="text-xs text-base-content/55">
              输出保存至默认导出目录下的「格式工坊」文件夹
            </p>
            <button
              type="button"
              className="btn btn-primary btn-sm gap-1.5 px-5"
              disabled={!isNative || busy || toolboxFiles.length === 0}
              onClick={() =>
                sendNativeMessage('toolbox.media.convert', {
                  paths: toolboxFiles.map(f => f.path),
                  targetFormat,
                  stripMetadata: true,
                  trimTransparency: false,
                })
              }
            >
              {busy ? (
                <span className="loading loading-spinner loading-xs" />
              ) : (
                <Lightning size={15} weight="fill" />
              )}
              {busy ? '正在转换…' : `开始转换 (${toolboxFiles.length})`}
            </button>
          </div>
        </div>
      </div>
    </div>
  )

  const renderUnpackCard = (inline = false) => (
    <div
      className={`rounded-2xl border border-base-300/75 bg-base-200/45 ${
        inline
          ? 'flex flex-wrap items-center justify-between gap-3.5 p-4'
          : 'flex flex-col items-center justify-center p-5 py-10 text-center'
      }`}
    >
      <div className={inline ? 'flex min-w-0 flex-1 items-center gap-3' : 'flex flex-col items-center'}>
        <span
          className={`flex shrink-0 items-center justify-center rounded-2xl bg-primary/14 text-primary ${
            inline ? 'h-10 w-10' : 'h-14 w-14'
          }`}
        >
          <FileZip size={inline ? 20 : 28} weight="duotone" />
        </span>
        <div className={inline ? 'min-w-0' : 'mt-4 max-w-lg'}>
          <h3 className="text-sm font-semibold">解包 .pkg / .tex 文件</h3>
          <p className="mt-0.5 text-xs leading-relaxed text-base-content/65">
            直接提取外部 .pkg 资源包或 .tex 贴图中的原图与音频文件。
          </p>
        </div>
      </div>
      <button
        type="button"
        className={`btn btn-primary btn-sm shrink-0 gap-2 ${inline ? 'px-4' : 'mt-5 px-6'}`}
        disabled={!isNative || busy}
        onClick={() => sendNativeMessage('toolbox.packages.unpack', {})}
      >
        {busy ? (
          <span className="loading loading-spinner loading-xs" />
        ) : (
          <Package size={15} weight="bold" />
        )}
        {busy ? '正在解包…' : '选择文件解包'}
      </button>
    </div>
  )

  return createPortal(
    <AnimatePresence>
      {open ? (
        <motion.div
          className="fixed inset-0 z-55 flex items-center justify-center bg-black/48 p-4 sm:p-6 backdrop-blur-[5px]"
          initial={{ opacity: 0 }}
          animate={{ opacity: 1 }}
          exit={{ opacity: 0 }}
          transition={{ duration: 0.16 }}
          onMouseDown={event => {
            if (event.target === event.currentTarget) onClose?.()
          }}
        >
          <motion.div
            role="dialog"
            aria-modal="true"
            aria-label="工具箱"
            className="flex max-h-[86vh] w-full max-w-5xl flex-col overflow-hidden rounded-[24px] border border-base-300/85 bg-base-100/94 text-base-content shadow-2xl backdrop-blur-2xl"
            initial={{ opacity: 0, scale: 0.96, y: 12 }}
            animate={{ opacity: 1, scale: 1, y: 0 }}
            exit={{ opacity: 0, scale: 0.97, y: 8 }}
            transition={{ duration: 0.18, ease: [0.22, 1, 0.36, 1] }}
          >
            <header className="flex flex-wrap items-center justify-between gap-3 border-b border-base-300/70 px-6 py-4">
              <div className="flex items-center gap-2.5">
                <span className="inline-flex h-8 w-8 items-center justify-center rounded-xl bg-primary/14 text-primary">
                  <Toolbox size={18} weight="fill" />
                </span>
                <div>
                  <h2 className="text-base font-semibold tracking-tight">工具箱</h2>
                  <p className="text-xs text-base-content/60">
                    收藏典藏、空间清理与外部媒体处理
                  </p>
                </div>
              </div>

              <div className="flex flex-wrap items-center gap-2.5">
                <div className="wv-segmented" role="group" aria-label="工具箱布局方案">
                  {LAYOUT_SCHEMES.map(scheme => {
                    const active = layoutScheme === scheme.id
                    return (
                      <button
                        key={scheme.id}
                        type="button"
                        className="wv-segmented__item text-xs"
                        aria-pressed={active}
                        onClick={() => selectLayoutScheme(scheme.id)}
                      >
                        {active ? (
                          <motion.span
                            layoutId="toolbox-layout-pill"
                            className="wv-segmented__pill"
                            transition={{ type: 'spring', duration: 0.28, bounce: 0 }}
                          />
                        ) : null}
                        <span className="relative z-10">{scheme.label}</span>
                      </button>
                    )
                  })}
                </div>
                <button
                  type="button"
                  className="btn btn-ghost btn-sm h-8 w-8 min-w-0 rounded-full px-0"
                  onClick={onClose}
                  aria-label="关闭工具箱"
                >
                  <X size={16} weight="bold" />
                </button>
              </div>
            </header>

            {layoutScheme === 'sidebar' ? (
              <div className="flex min-h-0 flex-1 flex-col md:flex-row">
                <aside
                  className="flex shrink-0 flex-row gap-1 overflow-x-auto border-b border-base-300/60 bg-base-200/35 p-3 md:w-48 md:flex-col md:border-r md:border-b-0"
                  role="tablist"
                  aria-label="工具箱功能分类"
                >
                  {SIDEBAR_SECTIONS.map(sec => {
                    const Icon = sec.icon
                    const active = sidebarTab === sec.id
                    const countText =
                      sec.id === 'archive'
                        ? favoriteIds.length
                        : sec.id === 'cleanup'
                          ? largeVideos.length
                          : sec.id === 'format'
                            ? toolboxFiles.length
                            : null
                    return (
                      <button
                        key={sec.id}
                        type="button"
                        role="tab"
                        aria-selected={active}
                        onClick={() => setSidebarTab(sec.id)}
                        className={`flex shrink-0 items-center justify-between gap-2 rounded-xl px-3.5 py-2.5 text-left text-sm font-medium transition-colors ${
                          active
                            ? 'bg-primary text-primary-content shadow-xs'
                            : 'text-base-content/75 hover:bg-base-content/7 hover:text-base-content'
                        }`}
                      >
                        <span className="flex items-center gap-2">
                          <Icon size={16} weight={active ? 'fill' : 'bold'} />
                          <span>{sec.label}</span>
                        </span>
                        {countText !== null && countText > 0 ? (
                          <span
                            className={`rounded-full px-1.5 py-0.5 text-[11px] leading-none tabular-nums ${
                              active
                                ? 'bg-white/22 text-white'
                                : 'bg-base-300/75 text-base-content/70'
                            }`}
                          >
                            {countText}
                          </span>
                        ) : null}
                      </button>
                    )
                  })}
                </aside>

                <div className="min-h-[440px] flex-1 overflow-y-auto p-6">
                  {sidebarTab === 'archive' ? renderArchiveCard(false) : null}
                  {sidebarTab === 'cleanup' ? (
                    <div className="space-y-4">
                      <div className="grid grid-cols-1 gap-4 md:grid-cols-2">
                        {renderDuplicateCard(false)}
                        {renderMigrationCard(false)}
                      </div>
                      {renderVideoSlimCard(false)}
                    </div>
                  ) : null}
                  {sidebarTab === 'format' ? renderFormatCard(false) : null}
                  {sidebarTab === 'unpack' ? renderUnpackCard(false) : null}
                </div>
              </div>
            ) : null}

            {layoutScheme === 'bento' ? (
              <div className="min-h-0 flex-1 overflow-y-auto p-5">
                <div className="grid grid-cols-1 gap-3.5 lg:grid-cols-12 lg:items-stretch">
                  <div className="flex flex-col gap-3.5 lg:col-span-7">
                    {renderArchiveCard(true)}
                    {renderFormatCard(true)}
                    {renderUnpackCard(true)}
                  </div>
                  <div className="flex flex-col gap-3.5 lg:col-span-5">
                    {renderDuplicateCard(true)}
                    {renderMigrationCard(true)}
                    {renderVideoSlimCard(true)}
                  </div>
                </div>
              </div>
            ) : null}

            {layoutScheme === 'dual' ? (
              <>
                <nav
                  className="flex flex-wrap gap-1.5 border-b border-base-300/60 bg-base-200/40 px-6 py-2.5"
                  role="tablist"
                >
                  {DUAL_TABS.map(tab => {
                    const Icon = tab.icon
                    const active = dualTab === tab.id
                    return (
                      <button
                        key={tab.id}
                        type="button"
                        role="tab"
                        aria-selected={active}
                        onClick={() => setDualTab(tab.id)}
                        className={`btn btn-sm gap-1.5 ${active ? 'btn-primary' : 'btn-ghost'}`}
                      >
                        <Icon size={15} weight={active ? 'fill' : 'bold'} />
                        {tab.label}
                      </button>
                    )
                  })}
                </nav>
                <div className="min-h-0 flex-1 overflow-y-auto p-6">
                  {dualTab === 'library' ? (
                    <div className="space-y-4">
                      {renderArchiveCard(false)}
                      <div className="grid grid-cols-1 gap-4 md:grid-cols-2">
                        {renderDuplicateCard(false)}
                        {renderMigrationCard(false)}
                      </div>
                      {renderVideoSlimCard(false)}
                    </div>
                  ) : (
                    <div className="space-y-4">
                      {renderFormatCard(false)}
                      {renderUnpackCard(true)}
                    </div>
                  )}
                </div>
              </>
            ) : null}
          </motion.div>
        </motion.div>
      ) : null}
    </AnimatePresence>,
    document.body,
  )
}
