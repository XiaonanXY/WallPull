import { startTransition, useCallback, useDeferredValue, useEffect, useMemo, useRef, useState } from 'react'
import { createPortal } from 'react-dom'
import {
  ArrowsClockwise,
  CaretLeft,
  CaretRight,
  CheckSquare,
  DownloadSimple,
  FadersHorizontal,
  FolderOpen,
  GearSix,
  Heart,
  MagnifyingGlass,
  Moon,
  Sun,
  Toolbox,
  Trash,
  WarningCircle,
  X,
} from '@phosphor-icons/react'
import { AnimatePresence, motion } from 'motion/react'
import { formatColor } from '@appica/ui-react'
import {
  ColorSwatchPicker,
  ColorSwatchPickerItem,
} from '@appica/ui-react/color-swatch-picker'
import FusionDemo from './components/FusionDemo.jsx'
import CardContextMenu from './components/CardContextMenu.jsx'
import ClickSpark from './components/ClickSpark.jsx'
import DeleteConfirmDialog from './components/DeleteConfirmDialog.jsx'
import DuplicateInspectorDialog from './components/DuplicateInspectorDialog.jsx'
import SceneLayerStudioDialog from './components/SceneLayerStudioDialog.jsx'
import SuperToolboxDialog from './components/SuperToolboxDialog.jsx'
import CallChip from './components/reactbits/CallChip.jsx'
import FluxProgressBar from './components/reactbits/FluxProgressBar.jsx'
import LatticeLoader from './components/reactbits/LatticeLoader.jsx'
import ShinyText from './components/reactbits/ShinyText.jsx'
import TechText from './components/reactbits/TechText.jsx'
import SettingsPage from './components/SettingsPage.jsx'
import WallpaperDetailDialog from './components/WallpaperDetailDialog.jsx'
import TargetCursor from './components/reactbits/TargetCursor.jsx'
import { preloadWallpaperBatch, resetRevealedMedia } from './utils/mediaRevealState.js'
import { getCachedColorBucket, resetColorCache, sniffWallpaperColors } from './utils/colorSniffer.js'
import {
  APP_INFO,
  COLOR_BUCKETS,
  DEFAULT_CARD_SIZE,
  DEFAULT_SETTINGS,
  MOCK_WALLPAPERS,
  RATING_FILTERS,
  SORT_MODES,
  SPEC_FILTERS,
  TYPE_FILTERS,
  createRequestId,
  formatBytes,
  isNewerVersion,
  isValidHexColor,
  parseResolutionDimensions,
  parseResolutionPixels,
  readableAccentInk,
  readableTextColor,
} from './appConfig.js'

export default function App() {
  const [page, setPage] = useState('library')
  const [wallpapers, setWallpapers] = useState([])
  const [filter, setFilter] = useState('all')
  const [specFilter, setSpecFilter] = useState('all')
  const [ratingFilter, setRatingFilter] = useState('all')
  const [colorFilter, setColorFilter] = useState(null)
  const [hoveredColorBucket, setHoveredColorBucket] = useState(null)
  const [colorVersion, setColorVersion] = useState(0)
  const [sortBy, setSortBy] = useState('default')
  const [filterPopoverOpen, setFilterPopoverOpen] = useState(false)
  const [query, setQuery] = useState('')
  const [currentPage, setCurrentPage] = useState(1)
  const [detailItem, setDetailItem] = useState(null)
  const [detailOriginRect, setDetailOriginRect] = useState(null)
  const [contextMenu, setContextMenu] = useState(null)
  const [selectedIds, setSelectedIds] = useState([])
  const [settings, setSettings] = useState(DEFAULT_SETTINGS)
  const [savedSettings, setSavedSettings] = useState(DEFAULT_SETTINGS)
  const [cacheSizeBytes, setCacheSizeBytes] = useState(0)
  const searchInputRef = useRef(null)
  const filterPopoverRef = useRef(null)
  const [status, setStatus] = useState('正在连接本机壁纸库…')
  const [errorMessage, setErrorMessage] = useState(null)
  const [toastState, setToastState] = useState(null)
  const [loading, setLoading] = useState(true)
  const [isMaximized, setIsMaximized] = useState(false)
  const [customCaptionButtons, setCustomCaptionButtons] = useState(false)
  const [appVersion, setAppVersion] = useState(APP_INFO.version)
  const [checkingUpdate, setCheckingUpdate] = useState(false)
  const toastTimerRef = useRef(null)
  const [sparkSizeText, setSparkSizeText] = useState(String(DEFAULT_SETTINGS.sparkSizePercent))
  const [gridLayout, setGridLayout] = useState({
    columns: 3,
    rows: 2,
    cardSize: DEFAULT_CARD_SIZE,
  })
  const [detectedWorkshopRoots, setDetectedWorkshopRoots] = useState([])
  const [gpuAdapters, setGpuAdapters] = useState([])
  const [activeHardwareAccelerationMode, setActiveHardwareAccelerationMode] = useState('gpu')
  const [toolboxOpen, setToolboxOpen] = useState(false)
  const [toolboxBusy, setToolboxBusy] = useState(false)
  const [toolboxProgress, setToolboxProgress] = useState(null)
  const [toolboxCancelling, setToolboxCancelling] = useState(false)
  const [toolboxFiles, setToolboxFiles] = useState([])
  const [migrationStatus, setMigrationStatus] = useState(null)
  const [wePropertiesState, setWePropertiesState] = useState({ id: null, loading: false, properties: [] })
  const [studioState, setStudioState] = useState({ open: false, loading: false, rendering: false })
  const [dupState, setDupState] = useState({ open: false, loading: false, result: null })
  const [deleteTargets, setDeleteTargets] = useState([])
  const [scanProgress, setScanProgress] = useState(null)
  const [colorIndexProgress, setColorIndexProgress] = useState({ running: false, indexed: 0, total: 0 })
  const deferredQuery = useDeferredValue(query)
  const stageSectionRef = useRef(null)
  const wheelTurnStampRef = useRef(0)
  const latestScanRequestId = useRef(null)
  const activeToolboxRequestId = useRef(null)
  const lastSelectedIdRef = useRef(null)
  const isNative = Boolean(globalThis.chrome?.webview)

  const sendNativeMessage = useCallback((type, payload = {}) => {
    if (!isNative) return null
    if (type === 'wallpapers.we-properties.get') {
      setWePropertiesState({ id: payload?.id ?? null, loading: true, properties: [] })
    }
    const requestId = createRequestId()
    if (type === 'settings.clear-cache.request') {
      resetRevealedMedia()
      resetColorCache()
      setWallpapers([])
      setScanProgress(null)
      setLoading(true)
      latestScanRequestId.current = requestId
    }
    if ([
      'toolbox.media.convert',
      'toolbox.packages.unpack',
      'wallpapers.archive-offline.request',
      'toolbox.migration.execute',
      'wallpapers.slim-videos.request',
    ].includes(type)) {
      if (!activeToolboxRequestId.current) {
        activeToolboxRequestId.current = requestId
      }
      setToolboxBusy(true)
      setToolboxCancelling(false)
      setToolboxProgress({
        taskKind: type === 'wallpapers.slim-videos.request'
          ? 'slim-videos'
          : type === 'toolbox.media.convert'
            ? 'convert'
            : type === 'wallpapers.archive-offline.request'
              ? 'archive'
              : type === 'toolbox.packages.unpack'
                ? 'unpack'
                : 'migration',
        message: '正在准备任务…',
        currentIndex: 0,
        totalCount: 0,
        overallPercent: null,
        cancellable: type !== 'toolbox.migration.execute',
      })
    }
    globalThis.chrome.webview.postMessage({
      version: 1,
      type,
      requestId,
      payload,
    })
    return requestId
  }, [isNative])

  const persistSettings = useCallback(nextSettings => {
    setSettings(nextSettings)
    setSavedSettings(nextSettings)
    sendNativeMessage('settings.update.request', nextSettings)
  }, [sendNativeMessage])

  const showToast = useCallback((message, options = {}) => {
    if (!message) return
    const nextStatus = options.status || 'done'
    setToastState({
      message,
      status: nextStatus,
      destination: options.destination || null,
      actionLabel: options.actionLabel || null,
      actionUrl: options.actionUrl || null,
    })
    if (toastTimerRef.current) globalThis.clearTimeout(toastTimerRef.current)
    if (nextStatus !== 'running') {
      toastTimerRef.current = globalThis.setTimeout(() => {
        setToastState(null)
      }, options.destination || options.actionUrl ? 5000 : 2500)
    }
  }, [])

  const openExternalUrl = useCallback(({ url, copyText, toastMessage } = {}) => {
    if (!url) return
    if (isNative) {
      sendNativeMessage('shell.open-url.request', {
        url,
        copyText: copyText || null,
        toastMessage: toastMessage || null,
      })
      return
    }
    globalThis.open(url, '_blank', 'noopener,noreferrer')
    if (copyText) {
      globalThis.navigator?.clipboard?.writeText?.(copyText).catch(() => {})
    }
    if (toastMessage) {
      showToast(toastMessage)
    }
  }, [isNative, sendNativeMessage, showToast])

  const checkLatestUpdate = useCallback(async () => {
    if (checkingUpdate) return
    if (isNative) {
      setCheckingUpdate(true)
      sendNativeMessage('app.check-update.request', { currentVersion: appVersion })
      return
    }
    setCheckingUpdate(true)
    try {
      const resp = await globalThis.fetch('https://api.github.com/repos/XiaonanXY/WallPull/releases/latest', {
        headers: { Accept: 'application/vnd.github+json' },
      })
      if (resp.status === 403) {
        showToast('GitHub API 当前触发频率限制，请点击「GitHub 链接」查看最新版本', {
          status: 'error',
          actionLabel: '前往发布页',
          actionUrl: APP_INFO.releasesUrl,
        })
        return
      }
      if (!resp.ok) {
        throw new Error(`检查更新失败（状态码 ${resp.status}）`)
      }
      const data = await resp.json()
      const tag = String(data?.tag_name || '').trim()
      if (!tag) {
        throw new Error('GitHub 响应中缺少版本号信息。')
      }
      if (isNewerVersion(tag, appVersion)) {
        showToast(`发现新版本 ${tag}（当前 v${appVersion}）`, {
          actionLabel: '前往下载',
          actionUrl: data?.html_url || APP_INFO.releasesUrl,
        })
      } else {
        showToast(`当前已是最新版本（v${appVersion}）`)
      }
    } catch (err) {
      showToast(err?.message || '无法连接到 GitHub 检查更新，请稍后再试。', { status: 'error' })
    } finally {
      setCheckingUpdate(false)
    }
  }, [appVersion, checkingUpdate, isNative, sendNativeMessage, showToast])

  const requestScan = useCallback((force = false) => {
    resetRevealedMedia()
    if (force) {
      resetColorCache()
    }
    setWallpapers([])
    setErrorMessage(null)
    setScanProgress(null)
    setCurrentPage(1)
    setLoading(true)
    setStatus(force ? '正在强制重新扫描创意工坊…' : '正在解析创意工坊中的原图与原视频…')
    const requestId = sendNativeMessage('wallpapers.scan.request', { force: Boolean(force) })
    latestScanRequestId.current = requestId
    if (!requestId) {
      globalThis.setTimeout(() => {
        setWallpapers(MOCK_WALLPAPERS)
        setLoading(false)
        setStatus('浏览器预览模式')
      }, 250)
    }
  }, [sendNativeMessage])

  useEffect(() => {
    if (!isNative) {
      setWallpapers(MOCK_WALLPAPERS)
      setSettings({
        ...DEFAULT_SETTINGS,
        workshopRoot: 'C:\\Program Files (x86)\\Steam\\steamapps\\workshop\\content\\431960',
        exportDirectory: 'C:\\Users\\Public\\Pictures\\WallPull',
      })
      setLoading(false)
      setStatus('浏览器预览模式')
      return undefined
    }

    const handleNativeMessage = event => {
      let message
      try {
        message = typeof event.data === 'string' ? JSON.parse(event.data) : event.data
      } catch {
        return
      }
      if (!message || message.version !== 1) return
      if (
        ['wallpapers.scan.status', 'wallpapers.item', 'wallpapers.list'].includes(message.type) &&
        latestScanRequestId.current &&
        message.requestId &&
        message.requestId !== latestScanRequestId.current
      ) return

      if (message.type === 'app.state') {
        if (message.payload?.settings) {
          setSettings(previous => {
            const merged = { ...previous, ...message.payload.settings }
            setSavedSettings(merged)
            return merged
          })
          setSparkSizeText(String(message.payload.settings.sparkSizePercent ?? 0))
        }
        if (Array.isArray(message.payload?.detectedWorkshopRoots)) {
          setDetectedWorkshopRoots(message.payload.detectedWorkshopRoots)
        }
        if (Array.isArray(message.payload?.gpuAdapters)) {
          setGpuAdapters(message.payload.gpuAdapters)
        }
        if (typeof message.payload?.activeHardwareAccelerationMode === 'string') {
          setActiveHardwareAccelerationMode(message.payload.activeHardwareAccelerationMode)
        }
        if (typeof message.payload?.cacheSizeBytes === 'number') {
          setCacheSizeBytes(message.payload.cacheSizeBytes)
        }
        if (typeof message.payload?.maximized === 'boolean') {
          setIsMaximized(message.payload.maximized)
        }
        if (typeof message.payload?.customCaptionButtons === 'boolean') {
          setCustomCaptionButtons(message.payload.customCaptionButtons)
        }
        if (typeof message.payload?.appVersion === 'string' && message.payload.appVersion.trim()) {
          setAppVersion(message.payload.appVersion.trim())
        }
      }
      if (message.type === 'window.state') {
        if (typeof message.payload?.maximized === 'boolean') {
          setIsMaximized(message.payload.maximized)
        }
      }
      if (message.type === 'settings.value') {
        setSettings(previous => {
          const merged = { ...previous, ...message.payload }
          setSavedSettings(merged)
          return merged
        })
        setSparkSizeText(String(message.payload?.sparkSizePercent ?? 0))
      }
      if (message.type === 'wallpapers.scan.status') {
        const msg = message.payload?.message ?? '正在扫描…'
        setStatus(msg)
        setScanProgress({
          message: msg,
          phase: message.payload?.phase ?? 'scan',
          current: Number(message.payload?.current) || 0,
          total: Number(message.payload?.total) || 0,
        })
      }
      if (message.type === 'wallpapers.item') {
        const incoming = message.payload?.items ?? []
        if (incoming.length > 0) {
          startTransition(() => {
            setWallpapers(previous => {
              const byId = new Map(previous.map(item => [item.id, item]))
              incoming.forEach(item => byId.set(item.id, item))
              return [...byId.values()]
            })
          })
        }
      }
      if (message.type === 'wallpapers.list') {
        const nextItems = message.payload?.items ?? []
        setWallpapers(nextItems)
        const validIds = new Set(nextItems.map(entry => entry.id))
        setSelectedIds(previous => previous.filter(id => validIds.has(id)))
        if (Array.isArray(message.payload?.detectedWorkshopRoots)) {
          setDetectedWorkshopRoots(message.payload.detectedWorkshopRoots)
        }
        if (typeof message.payload?.cacheSizeBytes === 'number') {
          setCacheSizeBytes(message.payload.cacheSizeBytes)
        }
        setStatus(message.payload?.status ?? '扫描完成')
        setScanProgress(null)
        setLoading(false)
        setCurrentPage(1)
      }
      if (message.type === 'wallpapers.sync') {
        const nextItems = message.payload?.items ?? []
        setWallpapers(nextItems)
        const validIds = new Set(nextItems.map(entry => entry.id))
        setSelectedIds(previous => previous.filter(id => validIds.has(id)))
        if (Array.isArray(message.payload?.detectedWorkshopRoots)) {
          setDetectedWorkshopRoots(message.payload.detectedWorkshopRoots)
        }
        if (typeof message.payload?.cacheSizeBytes === 'number') {
          setCacheSizeBytes(message.payload.cacheSizeBytes)
        }
        setStatus(message.payload?.status ?? '扫描完成')
        setScanProgress(null)
        const addedCount = Number(message.payload?.addedCount) || 0
        const removedCount = Number(message.payload?.removedCount) || 0
        const firstAddedTitle = message.payload?.firstAddedTitle
        if (addedCount > 0) {
          showToast(
            addedCount === 1 && firstAddedTitle
              ? `已自动同步新订阅：${firstAddedTitle}`
              : `已自动同步 ${addedCount} 个新订阅壁纸`,
          )
        } else if (removedCount > 0) {
          showToast(`已同步移除 ${removedCount} 个已退订壁纸`)
        }
      }
      if (message.type === 'app.toast') {
        setCheckingUpdate(false)
        const msg = message.payload?.message
        if (msg) {
          showToast(msg, {
            status: message.payload?.status || 'done',
            actionLabel: message.payload?.actionLabel || null,
            actionUrl: message.payload?.actionUrl || null,
          })
        }
      }
      if (message.type === 'wallpapers.action.result') {
        if (!activeToolboxRequestId.current || !message.requestId || message.requestId === activeToolboxRequestId.current) {
          activeToolboxRequestId.current = null
          setToolboxBusy(false)
          setToolboxProgress(null)
          setToolboxCancelling(false)
        }
        const msg = message.payload?.message ?? '操作完成'
        setStatus(msg)
        showToast(msg, { destination: message.payload?.destination || null })
        if (Array.isArray(message.payload?.items)) {
          setWallpapers(message.payload.items)
        }
      }
      if (message.type === 'toolbox.idle') {
        if (!activeToolboxRequestId.current || !message.requestId || message.requestId === activeToolboxRequestId.current) {
          activeToolboxRequestId.current = null
          setToolboxBusy(false)
          setToolboxProgress(null)
          setToolboxCancelling(false)
        }
      }
      if (message.type === 'toolbox.cancelled') {
        activeToolboxRequestId.current = null
        setToolboxBusy(false)
        setToolboxProgress(null)
        setToolboxCancelling(false)
        showToast(message.payload?.message ?? '任务已安全停止')
      }
      if (message.type === 'wallpapers.sync-meta') {
        const archived = new Set(message.payload?.archivedIds ?? [])
        if (archived.size > 0) {
          setWallpapers(prev => prev.map(w => (archived.has(w.id) ? { ...w, isArchivedOffline: true } : w)))
          setDetailItem(prev => (prev && archived.has(prev.id) ? { ...prev, isArchivedOffline: true } : prev))
        }
      }
      if (message.type === 'wallpapers.we-properties.value') {
        setWePropertiesState({
          id: message.payload?.id ?? null,
          loading: false,
          properties: message.payload?.properties ?? [],
        })
      }
      if (message.type === 'toolbox.progress') {
        setToolboxProgress(message.payload ?? null)
      }
      if (message.type === 'toolbox.media.picked') {
        const incoming = message.payload?.files ?? []
        if (incoming.length > 0) {
          setToolboxFiles(prev => {
            const seen = new Set(prev.map(f => f.path))
            return [...prev, ...incoming.filter(f => !seen.has(f.path))]
          })
        }
      }
      if (message.type === 'toolbox.migration.status') {
        setMigrationStatus(message.payload ?? null)
      }
      if (message.type === 'wallpapers.scene-studio.opened') {
        const p = message.payload
        setStudioState({
          open: true,
          loading: false,
          rendering: false,
          wallpaperId: p?.wallpaperId ?? null,
          title: p?.title ?? '',
          manifest: p?.manifest ?? null,
          previewUrl: p?.previewUrl ?? '',
          previewWidth: p?.previewWidth ?? 0,
          previewHeight: p?.previewHeight ?? 0,
          hasPixels: p?.hasPixels ?? true,
        })
      }
      if (message.type === 'wallpapers.scene-studio.preview') {
        const p = message.payload
        setStudioState(previous => (
          previous.open && previous.wallpaperId === p?.wallpaperId
            ? {
                ...previous,
                rendering: false,
                previewUrl: p?.previewUrl ?? previous.previewUrl,
                previewWidth: p?.previewWidth ?? previous.previewWidth,
                previewHeight: p?.previewHeight ?? previous.previewHeight,
                hasPixels: p?.hasPixels ?? true,
              }
            : previous
        ))
      }
      if (message.type === 'wallpapers.duplicates.result') {
        setDupState(previous => ({
          ...previous,
          loading: false,
          result: message.payload ?? { groups: [], totalReclaimableBytes: 0, scannedCount: 0 },
        }))
      }
      if (message.type === 'wallpapers.deleted') {
        const deletedSet = new Set(message.payload?.deletedIds ?? [])
        const nextItems = message.payload?.items ?? []
        setWallpapers(nextItems)
        setSelectedIds(previous => previous.filter(id => !deletedSet.has(id)))
        setDetailItem(previous => {
          if (previous && deletedSet.has(previous.id)) {
            setDetailOriginRect(null)
            return null
          }
          return previous
        })
        if (message.payload?.settings) {
          setSettings(previous => {
            const merged = { ...previous, ...message.payload.settings }
            setSavedSettings(merged)
            return merged
          })
        }
        if (typeof message.payload?.cacheSizeBytes === 'number') {
          setCacheSizeBytes(message.payload.cacheSizeBytes)
        }
        if (message.payload?.status) {
          setStatus(message.payload.status)
        }
      }
      if (message.type === 'error') {
        setCheckingUpdate(false)
        if (!activeToolboxRequestId.current || !message.requestId || message.requestId === activeToolboxRequestId.current) {
          activeToolboxRequestId.current = null
          setToolboxBusy(false)
          setToolboxProgress(null)
          setToolboxCancelling(false)
        }
        const msg = message.payload?.message ?? '操作失败'
        const isScanError = Boolean(
          latestScanRequestId.current &&
          message.requestId &&
          message.requestId === latestScanRequestId.current,
        )
        if (isScanError) {
          setStatus(msg)
          setErrorMessage(msg)
          setScanProgress(null)
          setLoading(false)
        }
        showToast(msg, { status: 'error' })
        setStudioState(previous => (
          previous.loading && !previous.manifest
            ? { open: false, loading: false, rendering: false }
            : { ...previous, loading: false, rendering: false }
        ))
        setDupState(previous => ({ ...previous, loading: false }))
        setWePropertiesState(previous => ({ ...previous, loading: false }))
      }
    }

    globalThis.chrome.webview.addEventListener('message', handleNativeMessage)
    sendNativeMessage('app.ready')
    requestScan(false)
    return () => globalThis.chrome.webview.removeEventListener('message', handleNativeMessage)
  }, [isNative, requestScan, sendNativeMessage, showToast])

  useEffect(() => {
    document.documentElement.toggleAttribute('data-native', isNative)
  }, [isNative])

  useEffect(() => {
    if (!filterPopoverOpen) return undefined
    const handleOutside = event => {
      if (!filterPopoverRef.current?.contains(event.target)) {
        setFilterPopoverOpen(false)
      }
    }
    globalThis.addEventListener('pointerdown', handleOutside)
    return () => globalThis.removeEventListener('pointerdown', handleOutside)
  }, [filterPopoverOpen])

  useEffect(() => {
    setCurrentPage(1)
    setSelectedIds([])
  }, [colorFilter, filter, query, ratingFilter, sortBy, specFilter])

  useEffect(() => {
    if (loading || wallpapers.length === 0) return
    sniffWallpaperColors(wallpapers, info => {
      setColorVersion(v => v + 1)
      if (info && typeof info === 'object') {
        setColorIndexProgress({
          running: Boolean(info.running),
          indexed: Number(info.indexed) || 0,
          total: Number(info.total) || wallpapers.length,
        })
      }
    })
  }, [loading, wallpapers])

  const colorCounts = useMemo(() => {
    void colorVersion
    const counts = { dark: 0, light: 0, blue: 0, purple: 0, green: 0, warm: 0 }
    for (const item of wallpapers) {
      const bucket = getCachedColorBucket(item)
      if (bucket && Object.prototype.hasOwnProperty.call(counts, bucket)) {
        counts[bucket] += 1
      }
    }
    return counts
  }, [colorVersion, wallpapers])

  const favoriteIds = useMemo(
    () => (Array.isArray(settings.favoriteIds) ? settings.favoriteIds : []),
    [settings.favoriteIds],
  )
  const favoriteSet = useMemo(() => new Set(favoriteIds), [favoriteIds])

  const toggleFavorite = useCallback(id => {
    if (!id) return
    const current = Array.isArray(settings.favoriteIds) ? settings.favoriteIds : []
    const exists = current.includes(id)
    const nextFavorites = exists
      ? current.filter(v => v !== id)
      : [...current, id]
    persistSettings({ ...settings, favoriteIds: nextFavorites })
    showToast(exists ? '已取消收藏' : '已加入收藏 ♥')
  }, [persistSettings, settings, showToast])

  const filteredWallpapers = useMemo(() => {
    void colorVersion
    const normalizedQuery = deferredQuery.trim().toLocaleLowerCase()
    const matched = wallpapers.filter(item => {
      const matchesType =
        filter === 'all' ||
        (filter === 'favorite' ? favoriteSet.has(item.id) : item.type === filter)
      if (!matchesType) return false

      if (specFilter !== 'all') {
        if (specFilter === 'audio') {
          if (!item.hasAudio) return false
        } else if (specFilter === 'layered') {
          if (!item.hasSceneLayers) return false
        } else {
          const { width, height } = parseResolutionDimensions(item.resolution)
          if (specFilter === '4k' && Math.max(width, height) < 3800) return false
          if (specFilter === 'landscape' && !(width > height && width > 0)) return false
          if (specFilter === 'portrait' && !(height > width && height > 0)) return false
        }
      }

      if (ratingFilter === 'everyone' && item.contentRating && item.contentRating !== 'Everyone') {
        return false
      }
      if (ratingFilter === 'mature' &&
          item.contentRating !== 'Questionable' &&
          item.contentRating !== 'Mature') {
        return false
      }

      if (colorFilter) {
        const bucket = getCachedColorBucket(item)
        if (bucket !== colorFilter) return false
      }

      const matchesQuery =
        !normalizedQuery ||
        item.title.toLocaleLowerCase().includes(normalizedQuery) ||
        item.workshopId.includes(normalizedQuery)
      return matchesQuery
    })

    if (sortBy === 'size') {
      return [...matched].sort(
        (a, b) => (b.folderSize || b.fileSize || 0) - (a.folderSize || a.fileSize || 0),
      )
    }
    if (sortBy === 'resolution') {
      return [...matched].sort(
        (a, b) => parseResolutionPixels(b.resolution) - parseResolutionPixels(a.resolution),
      )
    }
    if (sortBy === 'title') {
      return [...matched].sort((a, b) => a.title.localeCompare(b.title, 'zh-CN'))
    }
    return matched
  }, [colorFilter, colorVersion, deferredQuery, favoriteSet, filter, ratingFilter, sortBy, specFilter, wallpapers])

  const effectiveColumns = Math.max(2, gridLayout.columns)
  const pageSize = effectiveColumns * gridLayout.rows
  const pageCount = Math.max(1, Math.ceil(filteredWallpapers.length / pageSize))
  const safePage = Math.min(currentPage, pageCount)
  const visibleWallpapers = useMemo(
    () => filteredWallpapers.slice((safePage - 1) * pageSize, safePage * pageSize),
    [filteredWallpapers, pageSize, safePage],
  )

  useEffect(() => {
    if (filteredWallpapers.length === 0) return
    const nextStart = safePage * pageSize
    preloadWallpaperBatch(filteredWallpapers, nextStart, pageSize * 2)
    preloadWallpaperBatch(filteredWallpapers, 0, Math.min(filteredWallpapers.length, 48))
  }, [filteredWallpapers, pageSize, safePage])

  const paginationItems = useMemo(() => {
    if (pageCount <= 7) {
      return Array.from({ length: pageCount }, (_, i) => i + 1)
    }
    const items = [1]
    const start = Math.max(2, safePage - 1)
    const end = Math.min(pageCount - 1, safePage + 1)
    if (start > 2) items.push('ellipsis-left')
    for (let p = start; p <= end; p += 1) items.push(p)
    if (end < pageCount - 1) items.push('ellipsis-right')
    items.push(pageCount)
    return items
  }, [pageCount, safePage])

  useEffect(() => {
    const element = stageSectionRef.current
    if (!element) return undefined

    const updateLayout = () => {
      if (element.clientWidth <= 0 || element.clientHeight <= 0) return
      const availableHeight = Math.max(220, element.clientHeight - 74)
      let rows = 2
      let cardSize = DEFAULT_CARD_SIZE
      if (availableHeight >= 610) {
        rows = 2
        cardSize = DEFAULT_CARD_SIZE
      } else if (availableHeight >= 496) {
        rows = 2
        cardSize = 186
      } else {
        rows = 1
        cardSize = Math.max(176, Math.min(DEFAULT_CARD_SIZE, availableHeight - 72))
      }

      const availableWidth = Math.max(0, element.clientWidth - 16)
      const columnGap = Math.max(42, Math.min(globalThis.innerWidth * 0.05, 82))
      const columns = Math.max(
        2,
        Math.min(5, Math.floor((availableWidth + columnGap) / (cardSize + columnGap))),
      )

      setGridLayout(prev =>
        prev.columns === columns && prev.rows === rows && prev.cardSize === cardSize
          ? prev
          : { columns, rows, cardSize },
      )
    }

    updateLayout()
    const observer = new ResizeObserver(updateLayout)
    observer.observe(element)
    return () => observer.disconnect()
  }, [])

  useEffect(() => {
    setCurrentPage(1)
  }, [pageSize])

  useEffect(() => {
    const hasBlockingModal = Boolean(
      detailItem ||
      studioState.open ||
      dupState.open ||
      toolboxOpen ||
      deleteTargets.length > 0,
    )
    const onKeyDown = event => {
      if (deleteTargets.length > 0) return
      if ((event.ctrlKey || event.metaKey) && event.key === ',') {
        if (!hasBlockingModal) {
          event.preventDefault()
          setPage(prev => (prev === 'settings' ? 'library' : 'settings'))
        }
        return
      }
      if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === 'f') {
        if (page === 'library' && !hasBlockingModal) {
          event.preventDefault()
          searchInputRef.current?.focus()
          searchInputRef.current?.select()
        }
        return
      }
      if (page !== 'library' || hasBlockingModal) return
      const tag = document.activeElement?.tagName
      if (tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT') return
      if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === 'a') {
        if (filteredWallpapers.length === 0) return
        event.preventDefault()
        setSelectedIds(previous => {
          const allSelected =
            filteredWallpapers.length > 0 &&
            filteredWallpapers.every(item => previous.includes(item.id))
          if (allSelected) {
            return []
          }
          const next = new Set(previous)
          filteredWallpapers.forEach(item => next.add(item.id))
          return [...next]
        })
        return
      }
      if (event.key === 'Delete' && isNative && selectedIds.length > 0) {
        event.preventDefault()
        const pickedSet = new Set(selectedIds)
        const targets = wallpapers.filter(item => pickedSet.has(item.id))
        if (targets.length > 0) setDeleteTargets(targets)
        return
      }
      if (event.key === 'Escape' && filterPopoverOpen) {
        setFilterPopoverOpen(false)
        return
      }
      if (event.key === 'Escape' && selectedIds.length > 0 && !contextMenu) {
        setSelectedIds([])
        return
      }
      if (event.key === 'ArrowLeft') {
        setCurrentPage(p => Math.max(1, p - 1))
      } else if (event.key === 'ArrowRight') {
        setCurrentPage(p => Math.min(pageCount, p + 1))
      }
    }
    globalThis.addEventListener('keydown', onKeyDown)
    return () => globalThis.removeEventListener('keydown', onKeyDown)
  }, [contextMenu, deleteTargets.length, detailItem, dupState.open, filterPopoverOpen, filteredWallpapers, isNative, page, pageCount, selectedIds, studioState.open, toolboxOpen, wallpapers])

  useEffect(() => {
    const section = stageSectionRef.current
    if (!section) return undefined
    const onWheel = event => {
      if (
        page !== 'library' ||
        pageCount <= 1 ||
        event.ctrlKey ||
        Math.abs(event.deltaY) < 12 ||
        detailItem ||
        studioState.open ||
        dupState.open ||
        toolboxOpen ||
        filterPopoverOpen ||
        contextMenu ||
        deleteTargets.length > 0
      ) return

      const scroller = section.querySelector('.fusion-stage')
      if (scroller && scroller.scrollHeight > scroller.clientHeight + 8) {
        const atTop = scroller.scrollTop <= 2
        const atBottom = scroller.scrollTop + scroller.clientHeight >= scroller.scrollHeight - 2
        if ((event.deltaY > 0 && !atBottom) || (event.deltaY < 0 && !atTop)) {
          return
        }
      }

      const now = performance.now()
      if (now - wheelTurnStampRef.current < 260) return
      wheelTurnStampRef.current = now

      if (event.deltaY > 0) {
        setCurrentPage(p => Math.min(pageCount, p + 1))
      } else {
        setCurrentPage(p => Math.max(1, p - 1))
      }
    }
    section.addEventListener('wheel', onWheel, { passive: true })
    return () => section.removeEventListener('wheel', onWheel)
  }, [contextMenu, deleteTargets.length, detailItem, dupState.open, filterPopoverOpen, page, pageCount, studioState.open, toolboxOpen])

  const detailIndex = useMemo(
    () => (detailItem ? filteredWallpapers.findIndex(item => item.id === detailItem.id) : -1),
    [detailItem, filteredWallpapers],
  )

  const handleOpenContextMenu = useCallback((item, x, y) => {
    setContextMenu({ item, x, y })
  }, [])

  const openDetails = useCallback((item, rect = null) => {
    setDetailOriginRect(rect)
    setDetailItem(item)
  }, [])

  const openLayerStudio = useCallback(item => {
    if (!isNative || !item?.id) return
    setStudioState({
      open: true,
      loading: true,
      rendering: false,
      wallpaperId: item.id,
      title: item.title,
      manifest: null,
      previewUrl: '',
      previewWidth: 0,
      previewHeight: 0,
      hasPixels: true,
    })
    sendNativeMessage('wallpapers.scene-studio.open', { id: item.id })
  }, [isNative, sendNativeMessage])

  const closeLayerStudio = useCallback(() => {
    setStudioState({ open: false, loading: false, rendering: false })
    if (isNative) {
      sendNativeMessage('wallpapers.scene-studio.close', {})
    }
  }, [isNative, sendNativeMessage])

  const handleStudioPreviewChange = useCallback((wallpaperId, layerIndices) => {
    if (!isNative || !wallpaperId) return
    setStudioState(previous => (previous.open ? { ...previous, rendering: true } : previous))
    sendNativeMessage('wallpapers.scene-studio.preview', { id: wallpaperId, layerIndices })
  }, [isNative, sendNativeMessage])

  const handleStudioExport = useCallback(payload => {
    if (!isNative) return
    sendNativeMessage('wallpapers.scene-studio.export', payload)
  }, [isNative, sendNativeMessage])

  const openDuplicateInspector = useCallback(() => {
    setDupState({ open: true, loading: true, result: null })
    if (isNative) {
      sendNativeMessage('wallpapers.duplicates.scan', {})
    } else {
      setDupState({ open: true, loading: false, result: { groups: [], totalReclaimableBytes: 0, scannedCount: 0 } })
    }
  }, [isNative, sendNativeMessage])

  const handleRecycleIds = useCallback(ids => {
    if (!isNative || !Array.isArray(ids) || ids.length === 0) return
    setDupState({ open: false, loading: false, result: null })
    sendNativeMessage('wallpapers.recycle-workshop.request', { ids })
  }, [isNative, sendNativeMessage])

  const toggleSelection = useCallback((id, modifiers = {}) => {
    if (!id) return
    if (modifiers?.shiftKey && lastSelectedIdRef.current) {
      const startIndex = filteredWallpapers.findIndex(item => item.id === lastSelectedIdRef.current)
      const endIndex = filteredWallpapers.findIndex(item => item.id === id)
      if (startIndex >= 0 && endIndex >= 0) {
        const from = Math.min(startIndex, endIndex)
        const to = Math.max(startIndex, endIndex)
        const rangeIds = filteredWallpapers.slice(from, to + 1).map(item => item.id)
        setSelectedIds(previous => {
          const next = new Set(previous)
          rangeIds.forEach(rangeId => next.add(rangeId))
          return [...next]
        })
        lastSelectedIdRef.current = id
        return
      }
    }

    lastSelectedIdRef.current = id
    setSelectedIds(previous => (previous.includes(id)
      ? previous.filter(value => value !== id)
      : [...previous, id]))
  }, [filteredWallpapers])

  const selectedSet = useMemo(() => new Set(selectedIds), [selectedIds])

  const selectedTotalBytes = useMemo(() => {
    if (selectedIds.length === 0) return 0
    const seenWorkshops = new Set()
    let total = 0
    wallpapers.forEach(item => {
      if (!selectedSet.has(item.id)) return
      const key = item.workshopId || item.id
      if (seenWorkshops.has(key)) return
      seenWorkshops.add(key)
      total += item.folderSize || item.fileSize || 0
    })
    return total
  }, [selectedIds.length, selectedSet, wallpapers])

  const allFilteredSelected = useMemo(
    () =>
      filteredWallpapers.length > 0 &&
      filteredWallpapers.every(item => selectedSet.has(item.id)),
    [filteredWallpapers, selectedSet],
  )

  const allSelectedFavorited = useMemo(
    () =>
      selectedIds.length > 0 &&
      selectedIds.every(id => favoriteSet.has(id)),
    [favoriteSet, selectedIds],
  )

  const toggleSelectAllFiltered = useCallback(() => {
    if (filteredWallpapers.length === 0) return
    if (allFilteredSelected) {
      setSelectedIds([])
      return
    }
    const next = new Set(selectedIds)
    filteredWallpapers.forEach(item => next.add(item.id))
    setSelectedIds([...next])
  }, [allFilteredSelected, filteredWallpapers, selectedIds])

  const toggleFavoriteBatch = useCallback(() => {
    if (selectedIds.length === 0) return
    const current = Array.isArray(settings.favoriteIds) ? settings.favoriteIds : []
    let nextFavorites
    if (allSelectedFavorited) {
      const removeSet = new Set(selectedIds)
      nextFavorites = current.filter(id => !removeSet.has(id))
      showToast(`已取消收藏 ${selectedIds.length} 项`)
    } else {
      const merged = new Set(current)
      selectedIds.forEach(id => merged.add(id))
      nextFavorites = [...merged]
      showToast(`已批量收藏 ${selectedIds.length} 项 ♥`)
    }
    persistSettings({ ...settings, favoriteIds: nextFavorites })
  }, [allSelectedFavorited, persistSettings, selectedIds, settings, showToast])

  const exportSelected = () => {
    sendNativeMessage('wallpapers.export.request', { ids: selectedIds })
  }

  const exportSelectedAs = () => {
    sendNativeMessage('wallpapers.export-as.request', { ids: selectedIds })
  }

  const closeDetails = () => {
    setDetailItem(null)
    setDetailOriginRect(null)
  }

  const requestDeleteItems = useCallback(target => {
    if (!target) return
    if (Array.isArray(target)) {
      if (target.length > 0) setDeleteTargets(target)
      return
    }
    if (selectedSet.has(target.id) && selectedIds.length > 1) {
      const picked = wallpapers.filter(w => selectedSet.has(w.id))
      if (picked.length > 0) {
        setDeleteTargets(picked)
        return
      }
    }
    setDeleteTargets([target])
  }, [selectedIds.length, selectedSet, wallpapers])

  const requestDeleteSelected = useCallback(() => {
    if (selectedIds.length === 0) return
    const picked = wallpapers.filter(w => selectedSet.has(w.id))
    if (picked.length > 0) setDeleteTargets(picked)
  }, [selectedIds.length, selectedSet, wallpapers])

  const confirmDeleteTargets = useCallback(() => {
    if (!isNative || deleteTargets.length === 0) {
      setDeleteTargets([])
      return
    }
    const ids = deleteTargets.map(item => item.id)
    setDeleteTargets([])
    sendNativeMessage('wallpapers.recycle-workshop.request', { ids })
  }, [deleteTargets, isNative, sendNativeMessage])

  const hasActiveFilter = sortBy !== 'default' || specFilter !== 'all' || ratingFilter !== 'all' || Boolean(colorFilter)

  const isSettingsDirty = useMemo(() => {
    const keys = Object.keys(DEFAULT_SETTINGS)
    return keys.some(key => {
      const cur = settings[key]
      const saved = savedSettings[key]
      if (Array.isArray(cur) || Array.isArray(saved)) {
        return JSON.stringify(cur ?? []) !== JSON.stringify(saved ?? [])
      }
      return (cur ?? '') !== (saved ?? '')
    })
  }, [savedSettings, settings])

  const isDark = settings.themeMode === 'dark'
  const navStyle = settings.navigationStyle === 'drawer' ? 'drawer' : 'island'
  const sparkColor = isValidHexColor(settings.sparkColor)
    ? settings.sparkColor
    : DEFAULT_SETTINGS.sparkColor
  const sparkSize = Math.max(0, Number(settings.sparkSizePercent) || 0)

  useEffect(() => {
    const root = document.documentElement
    root.setAttribute('data-theme', isDark ? 'wallpaper-vault-dark' : 'wallpaper-vault')
    root.classList.toggle('dark', isDark)
    root.style.setProperty('--color-primary', sparkColor)
    root.style.setProperty('--color-secondary', sparkColor)
    root.style.setProperty('--color-accent', sparkColor)
    root.style.setProperty('--selection-accent', sparkColor)
    root.style.setProperty(
      '--color-primary-ink',
      readableAccentInk(sparkColor, isDark),
    )
    const contentColor = readableTextColor(sparkColor)
    root.style.setProperty('--color-primary-content', contentColor)
    root.style.setProperty('--color-secondary-content', contentColor)
    root.style.setProperty('--color-accent-content', contentColor)
  }, [isDark, sparkColor])

  return (
    <ClickSpark sparkColor={sparkColor} sizePercent={sparkSize}>
      <TargetCursor
        targetSelector=".holo-card__rotor, .fusion-magnet-inner, button:not(.wake-slider__handle):not(.wv-caption-btn):not(:disabled), input:not([type='range']):not(:disabled), .glide-select__trigger:not(:disabled), .glide-select__option"
        cursorColor="#ffffff"
        blendMode="difference"
        size={30}
        cornerSize={10}
        thickness={2.5}
        padding={5}
        matchRadius
        showLabel={false}
      />
      <div className="app-shell flex h-full flex-col bg-base-100 text-base-content">
        <header className="navbar relative h-12 min-h-12 shrink-0 border-b border-transparent pl-8 pr-40">
          <div className="navbar-start">
            <div className="brand-wordmark" aria-label="WallPull">
              <TechText
                text="WallPull"
                fontFamily='"MiSans VF", "Segoe UI Variable Text", sans-serif'
                fontWeight={700}
                fontSize={22}
                letterSpacing={-0.03}
                color={isDark ? '#f4f4f8' : '#18181b'}
                accentColor={sparkColor}
                align="left"
                reach={90}
                specks={8}
                labels={false}
                selection
                draggable={false}
                sweep
                clickKick
                style={{ width: '100%', height: '100%' }}
              />
            </div>
          </div>

          <div className="navbar-end gap-1.5">
            {navStyle === 'island' ? (
              <div className="wv-utility-island" role="toolbar" aria-label="顶部工具栏">
                <button
                  type="button"
                  className={`wv-utility-island__btn ${toolboxOpen ? 'is-active' : ''}`}
                  aria-expanded={toolboxOpen}
                  onClick={() => setToolboxOpen(prev => !prev)}
                >
                  <Toolbox size={14} weight={toolboxOpen ? 'fill' : 'bold'} />
                  <span>工具箱</span>
                </button>
                <span className="wv-utility-island__divider" aria-hidden="true" />
                <button
                  type="button"
                  className="wv-utility-island__btn"
                  onClick={() => requestScan(true)}
                  disabled={loading}
                >
                  {loading
                    ? <span className="loading loading-spinner loading-xs" />
                    : <ArrowsClockwise size={14} weight="bold" />}
                  <span>扫描</span>
                </button>
                <span className="wv-utility-island__divider" aria-hidden="true" />
                <button
                  type="button"
                  className="wv-utility-island__btn w-7 px-0"
                  aria-label={isDark ? '切换到浅色模式' : '切换到暗色模式'}
                  onClick={() => persistSettings({
                    ...settings,
                    themeMode: isDark ? 'light' : 'dark',
                  })}
                >
                  {isDark ? <Sun size={15} weight="bold" /> : <Moon size={15} weight="bold" />}
                </button>
                <span className="wv-utility-island__divider" aria-hidden="true" />
                <button
                  type="button"
                  className={`wv-utility-island__btn ${page === 'settings' ? 'is-active' : ''}`}
                  aria-expanded={page === 'settings'}
                  onClick={() => setPage(prev => (prev === 'settings' ? 'library' : 'settings'))}
                >
                  <GearSix size={15} weight={page === 'settings' ? 'fill' : 'bold'} />
                  <span>设置</span>
                </button>
              </div>
            ) : (
              <>
                <button
                  type="button"
                  className={`btn btn-sm ${toolboxOpen ? 'bg-primary/14 text-primary' : 'btn-ghost'}`}
                  aria-expanded={toolboxOpen}
                  onClick={() => setToolboxOpen(prev => !prev)}
                >
                  <Toolbox size={15} weight={toolboxOpen ? 'fill' : 'bold'} />
                  工具箱
                </button>
                <button
                  type="button"
                  className="btn btn-ghost btn-sm"
                  aria-label={isDark ? '切换到浅色模式' : '切换到暗色模式'}
                  onClick={() => persistSettings({
                    ...settings,
                    themeMode: isDark ? 'light' : 'dark',
                  })}
                >
                  {isDark ? <Sun size={16} weight="bold" /> : <Moon size={16} weight="bold" />}
                </button>
                <button
                  type="button"
                  className={`btn btn-sm h-8 w-8 min-w-0 px-0 ${
                    page === 'settings' ? 'bg-primary/14 text-primary' : 'btn-ghost'
                  }`}
                  aria-label="打开设置"
                  aria-expanded={page === 'settings'}
                  onClick={() => setPage(prev => (prev === 'settings' ? 'library' : 'settings'))}
                >
                  <GearSix size={16} weight={page === 'settings' ? 'fill' : 'bold'} />
                </button>
                <button
                  className="btn btn-ghost btn-sm"
                  type="button"
                  onClick={() => requestScan(true)}
                  disabled={loading}
                >
                  {loading ? <span className="loading loading-spinner loading-xs" /> : null}
                  重新扫描
                </button>
              </>
            )}
          </div>
          {isNative && customCaptionButtons ? (
            <div
              className="absolute top-0 right-0 flex h-12 items-stretch"
              style={{ WebkitAppRegion: 'no-drag' }}
            >
              <button
                type="button"
                className="wv-caption-btn inline-flex h-12 w-[46px] items-center justify-center border-0 bg-transparent text-base-content/80 transition-colors hover:bg-base-content/8 hover:text-base-content"
                aria-label="最小化"
                onClick={() => sendNativeMessage('window.minimize')}
              >
                <svg width="10" height="10" viewBox="0 0 10 10" aria-hidden="true">
                  <path d="M0 5h10" stroke="currentColor" strokeWidth="1" />
                </svg>
              </button>
              <button
                type="button"
                className="wv-caption-btn inline-flex h-12 w-[46px] items-center justify-center border-0 bg-transparent text-base-content/80 transition-colors hover:bg-base-content/8 hover:text-base-content"
                aria-label={isMaximized ? '还原窗口' : '最大化'}
                onClick={() => sendNativeMessage('window.toggle-maximize')}
              >
                {isMaximized ? (
                  <svg width="10" height="10" viewBox="0 0 10 10" fill="none" aria-hidden="true">
                    <rect x="0.5" y="2.5" width="7" height="7" stroke="currentColor" strokeWidth="1" />
                    <path d="M2.5 2.5V0.5H9.5V7.5H7.5" stroke="currentColor" strokeWidth="1" />
                  </svg>
                ) : (
                  <svg width="10" height="10" viewBox="0 0 10 10" fill="none" aria-hidden="true">
                    <rect x="0.5" y="0.5" width="9" height="9" stroke="currentColor" strokeWidth="1" />
                  </svg>
                )}
              </button>
              <button
                type="button"
                className="wv-caption-btn inline-flex h-12 w-[46px] items-center justify-center border-0 bg-transparent text-base-content/80 transition-colors hover:bg-[#c42b1c] hover:text-white"
                aria-label="关闭"
                onClick={() => sendNativeMessage('window.close')}
              >
                <svg width="10" height="10" viewBox="0 0 10 10" aria-hidden="true">
                  <path d="M1 1l8 8M9 1L1 9" stroke="currentColor" strokeWidth="1.05" />
                </svg>
              </button>
            </div>
          ) : null}
        </header>

        <div className="relative flex min-h-0 flex-1 overflow-hidden">
          <main className="library-main relative mx-auto flex min-h-0 w-full max-w-[1600px] flex-1 flex-col gap-6 px-8 py-6">
            <section className="library-heading flex shrink-0 items-end justify-between gap-6">
              <div>
                <h1 className="text-2xl font-semibold tracking-tight">本机壁纸</h1>
                <div className="mt-1 flex flex-wrap items-center gap-2.5 text-sm text-base-content/65">
                  {loading && scanProgress?.phase === 'color-index' ? (
                    <LatticeLoader
                      status="working"
                      pattern="orbit"
                      grid={3}
                      cellSize={4}
                      gap={2}
                      fontSize={13}
                      color={sparkColor}
                      label={scanProgress.message}
                      showTimer={false}
                    />
                  ) : loading ? (
                    <ShinyText
                      text={status}
                      color={isDark ? '#a0a0b4' : '#6d5f7c'}
                      shineColor={isDark ? '#ffffff' : sparkColor}
                      speed={1.8}
                    />
                  ) : (
                    <>
                      <span>{status}</span>
                      {colorIndexProgress.running ? (
                        <LatticeLoader
                          status="working"
                          pattern="dots"
                          grid={3}
                          cellSize={3.5}
                          gap={1.5}
                          fontSize={12}
                          color={sparkColor}
                          label={`色彩索引 ${colorIndexProgress.indexed}/${colorIndexProgress.total}`}
                          showTimer={false}
                        />
                      ) : null}
                    </>
                  )}
                </div>
              </div>
              <div className="library-controls flex flex-wrap items-center justify-end gap-2.5">
                <div className="wv-segmented" role="group" aria-label="壁纸类型">
                  {TYPE_FILTERS.map(item => {
                    const active = filter === item.value
                    return (
                      <button
                        key={item.value}
                        type="button"
                        className="wv-segmented__item"
                        aria-pressed={active}
                        onClick={() => setFilter(item.value)}
                      >
                        {active ? (
                          <motion.span
                            layoutId="filter-seg-pill"
                            className="wv-segmented__pill"
                            transition={{ type: 'spring', duration: 0.3, bounce: 0 }}
                          />
                        ) : null}
                        <span className="relative z-10">{item.label}</span>
                      </button>
                    )
                  })}
                </div>
                <div className="relative flex items-center">
                  <input
                    ref={searchInputRef}
                    className="input input-sm w-48 pr-7 sm:w-56"
                    type="search"
                    value={query}
                    onChange={event => setQuery(event.target.value)}
                    placeholder="搜索标题或 ID (Ctrl+F)"
                    aria-label="搜索壁纸"
                  />
                  {query ? (
                    <button
                      type="button"
                      aria-label="清空搜索"
                      onClick={() => {
                        setQuery('')
                        searchInputRef.current?.focus()
                      }}
                      className="absolute right-2 inline-flex h-5 w-5 items-center justify-center rounded-full text-base-content/55 hover:bg-base-content/10 hover:text-base-content"
                    >
                      <X size={12} weight="bold" />
                    </button>
                  ) : null}
                </div>
                <div ref={filterPopoverRef} className="relative">
                  <button
                    type="button"
                    className={`btn btn-sm gap-1.5 ${
                      hasActiveFilter || filterPopoverOpen ? 'bg-primary/14 text-primary' : 'btn-ghost'
                    }`}
                    aria-expanded={filterPopoverOpen}
                    onClick={() => setFilterPopoverOpen(prev => !prev)}
                  >
                    <FadersHorizontal size={15} weight="bold" />
                    <span>筛选与排序</span>
                    {hasActiveFilter ? (
                      <span className="h-1.5 w-1.5 rounded-full bg-primary" aria-hidden="true" />
                    ) : null}
                  </button>
                  <AnimatePresence>
                    {filterPopoverOpen ? (
                      <motion.div
                        className="filter-popover space-y-3.5"
                        initial={{ opacity: 0, y: -6, scale: 0.97 }}
                        animate={{ opacity: 1, y: 0, scale: 1 }}
                        exit={{ opacity: 0, y: -4, scale: 0.98 }}
                        transition={{ duration: 0.14 }}
                      >
                        <div className="space-y-1.5">
                          <p className="text-[11px] font-semibold text-base-content/55 uppercase">排序方式</p>
                          <div className="flex flex-wrap gap-1">
                            {SORT_MODES.map(opt => (
                              <button
                                key={opt.value}
                                type="button"
                                className={`btn btn-xs h-7 px-2.5 ${
                                  sortBy === opt.value ? 'btn-primary' : 'btn-ghost'
                                }`}
                                onClick={() => setSortBy(opt.value)}
                              >
                                {opt.label}
                              </button>
                            ))}
                          </div>
                        </div>
                        <div className="space-y-1.5">
                          <p className="text-[11px] font-semibold text-base-content/55 uppercase">规格与特性</p>
                          <div className="flex flex-wrap gap-1">
                            {SPEC_FILTERS.map(opt => (
                              <button
                                key={opt.value}
                                type="button"
                                className={`btn btn-xs h-7 px-2.5 ${
                                  specFilter === opt.value ? 'btn-primary' : 'btn-ghost'
                                }`}
                                onClick={() => setSpecFilter(opt.value)}
                              >
                                {opt.label}
                              </button>
                            ))}
                          </div>
                        </div>
                        <div className="space-y-1.5">
                          <p className="text-[11px] font-semibold text-base-content/55 uppercase">内容分级筛选</p>
                          <div className="flex flex-wrap gap-1">
                            {RATING_FILTERS.map(opt => (
                              <button
                                key={opt.value}
                                type="button"
                                className={`btn btn-xs h-7 px-2.5 ${
                                  ratingFilter === opt.value ? 'btn-primary' : 'btn-ghost'
                                }`}
                                onClick={() => setRatingFilter(opt.value)}
                              >
                                {opt.label}
                              </button>
                            ))}
                          </div>
                        </div>
                        <div className="space-y-2">
                          <div className="flex items-center justify-between gap-2">
                            <p className="text-[11px] font-semibold text-base-content/55 uppercase">主色调筛选</p>
                            {colorIndexProgress.running || scanProgress?.phase === 'color-index' ? (
                              <LatticeLoader
                                status="working"
                                pattern="dots"
                                grid={3}
                                cellSize={3}
                                gap={1.5}
                                fontSize={11}
                                color={sparkColor}
                                label="索引中"
                                showTimer={false}
                              />
                            ) : (() => {
                              const activeBucket = COLOR_BUCKETS.find(b => b.value === (hoveredColorBucket ?? colorFilter))
                              return activeBucket ? (
                                <span className="text-[11px] font-medium text-primary tabular-nums">
                                  {activeBucket.label} · {colorCounts[activeBucket.value] || 0} 项
                                </span>
                              ) : null
                            })()}
                          </div>
                          <ColorSwatchPicker
                            aria-label="按主色调筛选"
                            shape="circle"
                            size={34}
                            className="w-full justify-between"
                            value={COLOR_BUCKETS.find(b => b.value === colorFilter)?.swatch ?? '#00000000'}
                            onValueChange={picked => {
                              const hex = String(formatColor(picked, 'hex') || '').toLowerCase()
                              const matched = COLOR_BUCKETS.find(b => b.swatch.toLowerCase() === hex)
                              if (matched) {
                                setColorFilter(matched.value)
                              }
                            }}
                          >
                            {COLOR_BUCKETS.map(bucket => (
                              <ColorSwatchPickerItem
                                key={bucket.value}
                                color={bucket.swatch}
                                colorName={`${bucket.label}（${colorCounts[bucket.value] || 0} 项）`}
                                className="tooltip tooltip-top"
                                data-tip={`${bucket.label}（${colorCounts[bucket.value] || 0} 项）`}
                                onMouseEnter={() => setHoveredColorBucket(bucket.value)}
                                onMouseLeave={() => setHoveredColorBucket(prev => (prev === bucket.value ? null : prev))}
                                onClick={event => {
                                  event.preventDefault()
                                  setColorFilter(prev => (prev === bucket.value ? null : bucket.value))
                                }}
                              />
                            ))}
                          </ColorSwatchPicker>
                        </div>
                        {hasActiveFilter ? (
                          <div className="flex justify-end border-t border-base-300/60 pt-2">
                            <button
                              type="button"
                              className="btn btn-ghost btn-xs"
                              onClick={() => {
                                setSortBy('default')
                                setSpecFilter('all')
                                setRatingFilter('all')
                                setColorFilter(null)
                              }}
                            >
                              重置全部筛选
                            </button>
                          </div>
                        ) : null}
                      </motion.div>
                    ) : null}
                  </AnimatePresence>
                </div>
              </div>
            </section>

            {errorMessage ? (
              <div
                role="alert"
                className="flex shrink-0 items-center justify-between gap-4 rounded-xl border border-error/25 bg-error/8 px-4 py-3 text-sm text-error"
              >
                <div className="flex items-center gap-2">
                  <WarningCircle size={18} weight="fill" />
                  <span>{errorMessage}</span>
                </div>
                <div className="flex items-center gap-2">
                  <button
                    type="button"
                    className="btn btn-sm btn-primary"
                    onClick={() => requestScan(true)}
                  >
                    重试扫描
                  </button>
                  <button
                    type="button"
                    className="btn btn-sm btn-ghost"
                    onClick={() => setErrorMessage(null)}
                  >
                    忽略
                  </button>
                </div>
              </div>
            ) : null}

            <section ref={stageSectionRef} className="flex min-h-0 flex-1 flex-col">
              {visibleWallpapers.length || loading ? (
                <FusionDemo
                  items={visibleWallpapers}
                  mode={settings.cardMode}
                  cardSize={gridLayout.cardSize}
                  gridColumns={effectiveColumns}
                  selectionBorderMode={settings.selectionBorderMode}
                  badgeScheme={settings.showArchivedBadge ? 'C' : 'B'}
                  showSize={sortBy === 'size'}
                  favoriteIds={favoriteIds}
                  onToggleFavorite={toggleFavorite}
                  onContextMenuItem={handleOpenContextMenu}
                  selectedIds={selectedIds}
                  onToggleSelect={toggleSelection}
                  onSelect={openDetails}
                  skeletonCount={loading ? Math.max(0, pageSize - visibleWallpapers.length) : 0}
                  isDark={isDark}
                  paused={
                    page !== 'library' ||
                    Boolean(detailItem) ||
                    studioState.open ||
                    dupState.open ||
                    toolboxOpen ||
                    deleteTargets.length > 0
                  }
                />
              ) : wallpapers.length > 0 ? (
                <div className="flex flex-1 flex-col items-center justify-center gap-3 text-center">
                  <div className="flex h-12 w-12 items-center justify-center rounded-2xl bg-base-200 text-base-content/55">
                    <MagnifyingGlass size={24} weight="regular" />
                  </div>
                  <div>
                    <p className="font-medium">没有匹配的壁纸</p>
                    <p className="mt-1 text-sm text-base-content/60">
                      当前搜索、收藏、比例或色调筛选下没有结果。
                    </p>
                  </div>
                  <button
                    type="button"
                    className="btn btn-ghost btn-sm mt-1"
                      onClick={() => {
                        setQuery('')
                        setFilter('all')
                        setSpecFilter('all')
                        setRatingFilter('all')
                        setColorFilter(null)
                      }}
                  >
                    清除全部筛选条件
                  </button>
                </div>
              ) : (
                <div className="flex flex-1 flex-col items-center justify-center gap-3 text-center">
                  <div className="flex h-12 w-12 items-center justify-center rounded-2xl bg-base-200 text-base-content/55">
                    <FolderOpen size={24} weight="regular" />
                  </div>
                  <div>
                    <p className="font-medium">未发现可展示的本机壁纸</p>
                    <p className="mt-1 text-sm text-base-content/60">
                      请确认 Wallpaper Engine 创意工坊目录已正确配置。
                    </p>
                  </div>
                  <div className="mt-1 flex items-center gap-2">
                    <button
                      type="button"
                      className="btn btn-primary btn-sm"
                      onClick={() => setPage('settings')}
                    >
                      前往设置检测目录
                    </button>
                    <button
                      type="button"
                      className="btn btn-ghost btn-sm"
                      onClick={() => requestScan(true)}
                    >
                      重新扫描
                    </button>
                  </div>
                </div>
              )}

              <div className="flex shrink-0 items-center justify-between border-t border-base-300/60 pt-4">
                <span className="text-sm text-base-content/65">共 {filteredWallpapers.length} 项</span>
                <nav className="flex items-center gap-1" aria-label="分页导航">
                  <button
                    type="button"
                    className="btn btn-ghost btn-sm h-8 w-8 min-w-0 px-0"
                    disabled={safePage <= 1}
                    onClick={() => setCurrentPage(p => Math.max(1, p - 1))}
                    aria-label="上一页"
                  >
                    <CaretLeft size={15} weight="bold" />
                  </button>
                  {paginationItems.map(entry =>
                    typeof entry === 'string' ? (
                      <span
                        key={entry}
                        className="inline-flex h-8 w-6 items-center justify-center text-sm text-base-content/45 select-none"
                        aria-hidden="true"
                      >
                        …
                      </span>
                    ) : (
                      <button
                        key={entry}
                        type="button"
                        className={`btn btn-sm h-8 min-w-8 px-2.5 ${
                          entry === safePage ? 'btn-primary' : 'btn-ghost'
                        }`}
                        aria-current={entry === safePage ? 'page' : undefined}
                        onClick={() => setCurrentPage(entry)}
                      >
                        {entry}
                      </button>
                    ),
                  )}
                  <button
                    type="button"
                    className="btn btn-ghost btn-sm h-8 w-8 min-w-0 px-0"
                    disabled={safePage >= pageCount}
                    onClick={() => setCurrentPage(p => Math.min(pageCount, p + 1))}
                    aria-label="下一页"
                  >
                    <CaretRight size={15} weight="bold" />
                  </button>
                </nav>
              </div>
            </section>

            <AnimatePresence>
              {selectedIds.length ? (
                <motion.div
                  className="selection-actions"
                  role="toolbar"
                  aria-label="已选择壁纸操作"
                  initial={{ opacity: 0, y: 16, scale: 0.96 }}
                  animate={{ opacity: 1, y: 0, scale: 1 }}
                  exit={{ opacity: 0, y: 14, scale: 0.97 }}
                  transition={{ duration: 0.18, ease: [0.2, 0, 0, 1] }}
                >
                  <div className="flex items-center gap-2 pr-1">
                    <CheckSquare size={16} weight="fill" className="text-primary" />
                    <span className="text-sm font-medium whitespace-nowrap">
                      已选 <strong className="font-semibold text-primary">{selectedIds.length}</strong> 项
                    </span>
                    <span className="text-xs text-base-content/55 tabular-nums whitespace-nowrap">
                      · {formatBytes(selectedTotalBytes)}
                    </span>
                  </div>
                  <div className="h-4 w-px bg-base-300" />
                  <div className="flex flex-wrap items-center gap-1.5">
                    <button
                      type="button"
                      className="btn btn-sm btn-ghost"
                      onClick={toggleSelectAllFiltered}
                    >
                      {allFilteredSelected ? '全不选' : `全选当前 (${filteredWallpapers.length})`}
                    </button>
                    <button
                      type="button"
                      className="btn btn-sm btn-ghost"
                      onClick={toggleFavoriteBatch}
                    >
                      <Heart
                        size={14}
                        weight={allSelectedFavorited ? 'fill' : 'regular'}
                        className={allSelectedFavorited ? 'text-rose-500' : ''}
                      />
                      {allSelectedFavorited ? '取消收藏' : '批量收藏'}
                    </button>
                    <button
                      type="button"
                      className="btn btn-sm btn-ghost"
                      disabled={!isNative}
                      onClick={exportSelectedAs}
                    >
                      另存到…
                    </button>
                    <button
                      type="button"
                      className="btn btn-sm btn-ghost text-error hover:bg-error/10"
                      disabled={!isNative}
                      onClick={requestDeleteSelected}
                    >
                      <Trash size={14} weight="bold" />
                      删除
                    </button>
                    <button
                      type="button"
                      className="btn btn-sm btn-primary"
                      disabled={!isNative}
                      onClick={exportSelected}
                    >
                      <DownloadSimple size={14} weight="bold" />
                      导出全部
                    </button>
                    <button
                      type="button"
                      className="btn btn-sm btn-ghost px-2"
                      aria-label="取消选择"
                      onClick={() => setSelectedIds([])}
                    >
                      <X size={14} weight="bold" />
                    </button>
                  </div>
                </motion.div>
              ) : null}
            </AnimatePresence>
          </main>
          <SettingsPage
            visible={page === 'settings'}
            layoutMode={navStyle}
            onClose={() => setPage('library')}
            settings={settings}
            setSettings={setSettings}
            isDark={isDark}
            isDirty={isSettingsDirty}
            cacheSizeBytes={cacheSizeBytes}
            detectedWorkshopRoots={detectedWorkshopRoots}
            gpuAdapters={gpuAdapters}
            activeHardwareAccelerationMode={activeHardwareAccelerationMode}
            sparkColor={sparkColor}
            sparkSize={sparkSize}
            sparkSizeText={sparkSizeText}
            setSparkSizeText={setSparkSizeText}
            isNative={isNative}
            appVersion={appVersion}
            checkingUpdate={checkingUpdate}
            onCheckUpdate={checkLatestUpdate}
            onOpenExternalUrl={openExternalUrl}
            sendNativeMessage={sendNativeMessage}
            persistSettings={persistSettings}
          />
        </div>

        <WallpaperDetailDialog
          item={detailItem}
          originRect={detailOriginRect}
          isDark={isDark}
          isFavorited={detailItem ? favoriteSet.has(detailItem.id) : false}
          hasPrev={detailIndex > 0}
          hasNext={detailIndex >= 0 && detailIndex < filteredWallpapers.length - 1}
          wePropertiesState={wePropertiesState}
          onPrev={() => {
            if (detailIndex > 0) setDetailItem(filteredWallpapers[detailIndex - 1])
          }}
          onNext={() => {
            if (detailIndex >= 0 && detailIndex < filteredWallpapers.length - 1) {
              setDetailItem(filteredWallpapers[detailIndex + 1])
            }
          }}
          onToggleFavorite={toggleFavorite}
          isNative={isNative}
          sendNativeMessage={sendNativeMessage}
          onOpenLayerStudio={item => {
            setDetailItem(null)
            openLayerStudio(item)
          }}
          onDelete={item => setDeleteTargets([item])}
          suppressHotkeys={deleteTargets.length > 0}
          onClose={closeDetails}
        />
        <CardContextMenu
          state={contextMenu}
          isSelected={contextMenu?.item ? selectedSet.has(contextMenu.item.id) : false}
          selectedCount={selectedIds.length}
          isFavorited={contextMenu?.item ? favoriteSet.has(contextMenu.item.id) : false}
          isNative={isNative}
          onClose={() => setContextMenu(null)}
          onToggleSelect={toggleSelection}
          onToggleFavorite={toggleFavorite}
          onOpenLayerStudio={openLayerStudio}
          onCopy={item => sendNativeMessage('wallpapers.copy.request', { id: item.id })}
          onSetDesktop={item => sendNativeMessage('wallpapers.set-desktop.request', { id: item.id })}
          onExport={item => sendNativeMessage('wallpapers.export.request', { ids: [item.id] })}
          onOpenFolder={item => sendNativeMessage('wallpapers.open-folder.request', { id: item.id })}
          onOpenWorkshop={item => sendNativeMessage('wallpapers.open-workshop.request', { id: item.id })}
          onDelete={requestDeleteItems}
        />
        <DeleteConfirmDialog
          items={deleteTargets}
          isNative={isNative}
          onOpenWorkshop={item => sendNativeMessage('wallpapers.open-workshop.request', { id: item.id })}
          onConfirm={confirmDeleteTargets}
          onCancel={() => setDeleteTargets([])}
        />
        <SceneLayerStudioDialog
          open={studioState.open}
          state={studioState}
          isNative={isNative}
          onPreviewChange={handleStudioPreviewChange}
          onExport={handleStudioExport}
          onClose={closeLayerStudio}
        />
        <DuplicateInspectorDialog
          open={dupState.open}
          loading={dupState.loading}
          result={dupState.result}
          isNative={isNative}
          onRescan={() => {
            setDupState(prev => ({ ...prev, loading: true }))
            if (isNative) sendNativeMessage('wallpapers.duplicates.scan', {})
          }}
          onPreview={item => {
            setDupState(prev => ({ ...prev, open: false }))
            setDetailItem(item)
          }}
          onOpenWorkshop={item => sendNativeMessage('wallpapers.open-workshop.request', { id: item.id })}
          onRecycleIds={handleRecycleIds}
          onClose={() => setDupState(prev => ({ ...prev, open: false }))}
        />
        <SuperToolboxDialog
          open={toolboxOpen}
          busy={toolboxBusy}
          taskProgress={toolboxProgress}
          cancelling={toolboxCancelling}
          onCancelTask={() => {
            setToolboxCancelling(true)
            sendNativeMessage('toolbox.task.cancel', {})
          }}
          onClose={() => setToolboxOpen(false)}
          wallpapers={wallpapers}
          favoriteIds={favoriteIds}
          toolboxFiles={toolboxFiles}
          setToolboxFiles={setToolboxFiles}
          migrationStatus={migrationStatus}
          settings={settings}
          persistSettings={persistSettings}
          isNative={isNative}
          sendNativeMessage={sendNativeMessage}
          onOpenDuplicates={openDuplicateInspector}
        />
        {createPortal(
          <AnimatePresence>
            {!toolboxOpen && toolboxBusy && toolboxProgress ? (
              <motion.div
                key="bg-toolbox-progress"
                style={{ zIndex: 200 }}
                className={`pointer-events-auto fixed left-1/2 w-[min(92vw,460px)] -translate-x-1/2 ${
                  selectedIds.length > 0 &&
                  page === 'library' &&
                  !detailItem &&
                  !toolboxOpen &&
                  !studioState.open &&
                  !dupState.open &&
                  deleteTargets.length === 0
                    ? 'bottom-[84px]'
                    : 'bottom-6'
                }`}
                initial={{ opacity: 0, y: 12, scale: 0.96 }}
                animate={{ opacity: 1, y: 0, scale: 1 }}
                exit={{ opacity: 0, y: 8, scale: 0.96 }}
                transition={{ duration: 0.18 }}
              >
                <FluxProgressBar
                  compact
                  progress={toolboxProgress}
                  cancelling={toolboxCancelling}
                  onCancel={() => {
                    setToolboxCancelling(true)
                    sendNativeMessage('toolbox.task.cancel', {})
                  }}
                />
              </motion.div>
            ) : toastState ? (
              <motion.div
                key={`${toastState.status}-${toastState.message}`}
                style={{ zIndex: 200 }}
                className={`pointer-events-auto fixed left-1/2 -translate-x-1/2 ${
                  selectedIds.length > 0 &&
                  page === 'library' &&
                  !detailItem &&
                  !toolboxOpen &&
                  !studioState.open &&
                  !dupState.open &&
                  deleteTargets.length === 0
                    ? 'bottom-[84px]'
                    : 'bottom-6'
                }`}
                initial={{ opacity: 0, y: 12, scale: 0.96 }}
                animate={{ opacity: 1, y: 0, scale: 1 }}
                exit={{ opacity: 0, y: 8, scale: 0.96 }}
                transition={{ duration: 0.18 }}
              >
                <CallChip
                  icon="sparkle"
                  name="WallPull"
                  argument={toastState.message}
                  status={toastState.status}
                  showTimer={toastState.status === 'running'}
                  color={isDark ? '#f4f4f8' : '#18181b'}
                  surfaceColor={isDark ? 'rgba(28, 28, 40, 0.92)' : 'rgba(255, 255, 255, 0.92)'}
                  actionLabel={toastState.actionLabel || (toastState.destination && isNative ? '打开目录' : null)}
                  onAction={toastState.actionUrl
                    ? () => openExternalUrl({ url: toastState.actionUrl })
                    : (toastState.destination && isNative
                        ? () => sendNativeMessage('shell.open-path.request', { path: toastState.destination })
                        : null)}
                />
              </motion.div>
            ) : null}
          </AnimatePresence>,
          document.body,
        )}
      </div>
    </ClickSpark>
  )
}
