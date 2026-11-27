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
  PaperPlaneTilt,
  Sun,
  Toolbox,
  Trash,
  WarningCircle,
  X,
} from '@phosphor-icons/react'
import { AnimatePresence, motion } from 'motion/react'
import FusionDemo from './components/FusionDemo.jsx'
import CardContextMenu from './components/CardContextMenu.jsx'
import ClickSpark from './components/ClickSpark.jsx'
import DeleteConfirmDialog from './components/DeleteConfirmDialog.jsx'
import DuplicateInspectorDialog from './components/DuplicateInspectorDialog.jsx'
import SceneLayerStudioDialog from './components/SceneLayerStudioDialog.jsx'
import SuperToolboxDialog from './components/SuperToolboxDialog.jsx'
import VideoFrameCaptureDialog from './components/VideoFrameCaptureDialog.jsx'
import ImageCropDialog from './components/ImageCropDialog.jsx'
import FilterPopover from './components/FilterPopover.jsx'
import FloatingActivityIsland from './components/ui/FloatingActivityIsland.jsx'
import OtpPinInput from './components/ui/OtpPinInput.jsx'
import StackedToaster from './components/ui/StackedToaster.jsx'
import LatticeLoader from './components/reactbits/LatticeLoader.jsx'
import ShinyText from './components/reactbits/ShinyText.jsx'
import TechText from './components/reactbits/TechText.jsx'
import SettingsPage from './components/SettingsPage.jsx'
import WallpaperDetailDialog from './components/WallpaperDetailDialog.jsx'
import TargetCursor from './components/reactbits/TargetCursor.jsx'
import { preloadWallpaperBatch, resetRevealedMedia } from './utils/mediaRevealState.js'
import { getCachedColorBucket, resetColorCache, sniffWallpaperColors } from './utils/colorSniffer.js'
import { captureVideoFrameToPng } from './utils/videoFrameCapture.js'
import {
  APP_INFO,
  COLOR_BUCKETS,
  DEFAULT_CARD_SIZE,
  DEFAULT_SETTINGS,
  MOCK_WALLPAPERS,
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
  const [toasts, setToasts] = useState([])
  const [loading, setLoading] = useState(true)
  const [isMaximized, setIsMaximized] = useState(false)
  const [customCaptionButtons, setCustomCaptionButtons] = useState(false)
  const [appVersion, setAppVersion] = useState(APP_INFO.version)
  const [checkingUpdate, setCheckingUpdate] = useState(false)
  const toastTimersRef = useRef(new Map())
  const toastHoveredRef = useRef(false)
  const nextToastIdRef = useRef(1)
  const [sparkSizeText, setSparkSizeText] = useState(String(DEFAULT_SETTINGS.sparkSizePercent))
  const [stageBounds, setStageBounds] = useState({
    width: 1280,
    height: 720,
    viewportWidth: 1440,
  })
  const [ffmpegStatus, setFfmpegStatus] = useState(null)
  const [frameCaptureState, setFrameCaptureState] = useState(null)
  const [cropState, setCropState] = useState(null)
  const [cropActionSeq, setCropActionSeq] = useState(0)
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
  const [localsendStatus, setLocalsendStatus] = useState({ enabled: true, alias: 'WallPull PC', port: 53417, localIps: [], peers: [] })
  const [localsendProgress, setLocalsendProgress] = useState(null)
  const [peerPickerState, setPeerPickerState] = useState(null)
  const [pairingPromptState, setPairingPromptState] = useState(null)
  const [scanProgress, setScanProgress] = useState(null)
  const [colorIndexProgress, setColorIndexProgress] = useState({ running: false, indexed: 0, total: 0 })
  const deferredQuery = useDeferredValue(query)
  const stageSectionRef = useRef(null)
  const wheelTurnStampRef = useRef(0)
  const latestScanRequestId = useRef(null)
  const activeToolboxRequestId = useRef(null)
  const latestUpdateCheckReqIdRef = useRef(null)
  const latestWePropsReqIdRef = useRef(null)
  const latestSettingsSaveReqIdRef = useRef(null)
  const pairingPromptRef = useRef(null)
  pairingPromptRef.current = pairingPromptState
  const lastSelectedIdRef = useRef(null)
  const hasHydratedFiltersRef = useRef(false)
  const [globalAudio, setGlobalAudio] = useState(null)
  const globalAudioRef = useRef(null)
  const pendingAutoPlayRef = useRef(false)
  const isNative = Boolean(globalThis.chrome?.webview)

  useEffect(() => () => {
    const timers = toastTimersRef.current
    timers.forEach(t => globalThis.clearTimeout(t))
    timers.clear()
  }, [])

  useEffect(() => {
    const preventDropNavigation = event => {
      event.preventDefault()
    }
    globalThis.addEventListener('dragover', preventDropNavigation)
    globalThis.addEventListener('drop', preventDropNavigation)
    return () => {
      globalThis.removeEventListener('dragover', preventDropNavigation)
      globalThis.removeEventListener('drop', preventDropNavigation)
    }
  }, [])

  const sendNativeMessage = useCallback((type, payload = {}) => {
    if (!isNative) return null
    const requestId = createRequestId()
    if (type === 'wallpapers.we-properties.get') {
      latestWePropsReqIdRef.current = requestId
      setWePropertiesState({ id: payload?.id ?? null, loading: true, properties: [] })
    }
    if (type === 'app.check-update.request') {
      latestUpdateCheckReqIdRef.current = requestId
    }
    if (type === 'settings.update.request') {
      latestSettingsSaveReqIdRef.current = requestId
    }
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
      activeToolboxRequestId.current = requestId
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

  const savedSettingsRef = useRef(savedSettings)
  savedSettingsRef.current = savedSettings
  const settingsRef = useRef(settings)
  settingsRef.current = settings

  const persistSettings = useCallback((patchOrFull, uiSettings = null) => {
    const base = savedSettingsRef.current
    const nextSaved = { ...base, ...patchOrFull }
    const isPatchOnly = uiSettings === null && Object.keys(patchOrFull || {}).length < Object.keys(base || {}).length
    const nextUi = uiSettings ?? (isPatchOnly ? { ...settingsRef.current, ...patchOrFull } : nextSaved)
    setSettings(nextUi)
    setSavedSettings(nextSaved)
    sendNativeMessage('settings.update.request', nextSaved)
  }, [sendNativeMessage])

  const updateFilterPreferences = useCallback(patch => {
    const nextMedia = patch.mediaFilter !== undefined ? patch.mediaFilter : filter
    const nextSpec = patch.specFilter !== undefined ? patch.specFilter : specFilter
    const nextRating = patch.ratingFilter !== undefined ? patch.ratingFilter : ratingFilter
    const nextSort = patch.sortBy !== undefined ? patch.sortBy : sortBy
    const nextColor = patch.colorFilter !== undefined ? patch.colorFilter : colorFilter

    if (patch.mediaFilter !== undefined) setFilter(nextMedia)
    if (patch.specFilter !== undefined) setSpecFilter(nextSpec)
    if (patch.ratingFilter !== undefined) setRatingFilter(nextRating)
    if (patch.sortBy !== undefined) setSortBy(nextSort)
    if (patch.colorFilter !== undefined) setColorFilter(nextColor)
    setCurrentPage(1)
    setSelectedIds(prev => (prev.length ? [] : prev))

    persistSettings({
      mediaFilter: nextMedia,
      specFilter: nextSpec,
      ratingFilter: nextRating,
      sortBy: nextSort,
      colorFilter: nextColor,
    })
  }, [colorFilter, filter, persistSettings, ratingFilter, sortBy, specFilter])

  const dismissToast = useCallback(id => {
    const timer = toastTimersRef.current.get(id)
    if (timer) {
      globalThis.clearTimeout(timer)
      toastTimersRef.current.delete(id)
    }
    setToasts(prev => prev.filter(t => t.id !== id))
  }, [])

  const scheduleToastDismiss = useCallback((id, delayMs) => {
    const existing = toastTimersRef.current.get(id)
    if (existing) globalThis.clearTimeout(existing)
    const timer = globalThis.setTimeout(() => {
      toastTimersRef.current.delete(id)
      if (toastHoveredRef.current) {
        scheduleToastDismiss(id, 1200)
        return
      }
      setToasts(prev => prev.filter(t => t.id !== id))
    }, delayMs)
    toastTimersRef.current.set(id, timer)
  }, [])

  const showToast = useCallback((message, options = {}) => {
    if (!message) return
    const nextStatus = options.status || 'done'
    const id = nextToastIdRef.current++
    const entry = {
      id,
      message,
      status: nextStatus,
      destination: options.destination || null,
      actionLabel: options.actionLabel || null,
      actionUrl: options.actionUrl || null,
    }
    setToasts(prev => [...prev.slice(-4), entry])
    if (nextStatus !== 'running') {
      scheduleToastDismiss(id, options.destination || options.actionUrl ? 5000 : 2800)
    }
  }, [scheduleToastDismiss])

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
          const incomingSettings = message.payload.settings
          setSettings(previous => ({ ...previous, ...incomingSettings }))
          setSavedSettings(previous => ({ ...previous, ...incomingSettings }))
          setSparkSizeText(String(incomingSettings.sparkSizePercent ?? 0))
          if (!hasHydratedFiltersRef.current) {
            hasHydratedFiltersRef.current = true
            if (typeof incomingSettings.mediaFilter === 'string') setFilter(incomingSettings.mediaFilter)
            if (typeof incomingSettings.specFilter === 'string') setSpecFilter(incomingSettings.specFilter)
            if (typeof incomingSettings.ratingFilter === 'string') setRatingFilter(incomingSettings.ratingFilter)
            if (typeof incomingSettings.sortBy === 'string') setSortBy(incomingSettings.sortBy)
            if (incomingSettings.colorFilter !== undefined) setColorFilter(incomingSettings.colorFilter ?? null)
          }
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
        if (message.payload?.ffmpegStatus) {
          setFfmpegStatus(message.payload.ffmpegStatus)
        }
        sendNativeMessage('localsend.status.request', {})
      }
      if (message.type === 'ffmpeg.status') {
        if (message.payload) {
          setFfmpegStatus(message.payload)
        }
      }
      if (message.type === 'window.state') {
        if (typeof message.payload?.maximized === 'boolean') {
          setIsMaximized(message.payload.maximized)
        }
      }
      if (message.type === 'settings.value') {
        if (
          latestSettingsSaveReqIdRef.current &&
          message.requestId &&
          message.requestId !== latestSettingsSaveReqIdRef.current
        ) {
          return
        }
        const incoming = message.payload || {}
        const entries = Object.entries(incoming)
        const sameValue = (a, b) => {
          if (a === b) return true
          if (Array.isArray(a) && Array.isArray(b)) {
            return a.length === b.length && a.every((v, idx) => v === b[idx])
          }
          return false
        }
        setSavedSettings(previous => {
          const changed = entries.some(([k, v]) => !sameValue(previous[k], v))
          return changed ? { ...previous, ...incoming } : previous
        })
        setSettings(previous => {
          let changed = false
          const next = { ...previous }
          for (const [k, v] of entries) {
            if ((previous[k] ?? '') === (savedSettingsRef.current[k] ?? '') && !sameValue(previous[k], v)) {
              next[k] = v
              changed = true
            }
          }
          return changed ? next : previous
        })
        if ((settingsRef.current.sparkSizePercent ?? '') === (savedSettingsRef.current.sparkSizePercent ?? '')) {
          const nextSparkText = String(incoming.sparkSizePercent ?? 0)
          setSparkSizeText(prev => (prev === nextSparkText ? prev : nextSparkText))
        }
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
        const prepend = Boolean(message.payload?.prepend)
        if (incoming.length > 0) {
          startTransition(() => {
            setWallpapers(previous => {
              if (prepend) {
                const incomingIds = new Set(incoming.map(item => item.id))
                return [...incoming, ...previous.filter(item => !incomingIds.has(item.id))]
              }
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
      if (message.type === 'localsend.status') {
        if (message.payload) {
          setLocalsendStatus(message.payload)
        }
      }
      if (message.type === 'localsend.progress') {
        const p = message.payload
        setLocalsendProgress(p && typeof p === 'object' ? p : null)
      }
      if (message.type === 'localsend.pairing.required') {
        const p = message.payload
        if (p?.peerFingerprint) {
          setPairingPromptState({
            peerFingerprint: p.peerFingerprint,
            peerAlias: p.peerAlias || 'WallPull iPad',
            pendingAction: p,
            pin: '',
            submitting: false,
            error: '',
          })
        }
      }
      if (message.type === 'localsend.pair.result') {
        const p = message.payload
        if (p?.ok) {
          showToast(p.message || '配对成功')
          const pending = pairingPromptRef.current?.pendingAction
          setPairingPromptState(null)
          if (pending) {
            const msgType = pending.isStudio ? 'localsend.send-studio.request' : 'localsend.send.request'
            const retryPayload = pending.isStudio
              ? {
                  peerFingerprint: pending.peerFingerprint,
                  visibleLayerIndices: pending.visibleLayerIndices,
                  trimBounds: pending.trimBounds,
                  includeBackground: pending.includeBackground,
                  targetMode: pending.targetMode || 'vault',
                }
              : {
                  peerFingerprint: pending.peerFingerprint,
                  ids: pending.ids,
                  assetIndex: pending.assetIndex,
                  targetMode: pending.targetMode || 'vault',
                }
            sendNativeMessage(msgType, retryPayload)
          }
        } else {
          setPairingPromptState(prev => (
            prev
              ? { ...prev, submitting: false, error: p?.message || '配对码错误' }
              : null
          ))
        }
      }
      if (message.type === 'localsend.peers.dirty') {
        sendNativeMessage('localsend.status.request', {})
      }
      if (message.type === 'app.toast') {
        if (latestUpdateCheckReqIdRef.current && message.requestId === latestUpdateCheckReqIdRef.current) {
          latestUpdateCheckReqIdRef.current = null
          setCheckingUpdate(false)
        }
        const msg = message.payload?.message
        if (msg) {
          showToast(msg, {
            status: message.payload?.status || 'done',
            actionLabel: message.payload?.actionLabel || null,
            actionUrl: message.payload?.actionUrl || null,
          })
        }
      }
      if (message.type === 'media.crop-action.cancelled') {
        setCropActionSeq(seq => seq + 1)
      }
      if (message.type === 'wallpapers.action.result') {
        setCropActionSeq(seq => seq + 1)
        if (activeToolboxRequestId.current && message.requestId === activeToolboxRequestId.current) {
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
        if (activeToolboxRequestId.current && message.requestId === activeToolboxRequestId.current) {
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
        if (!latestWePropsReqIdRef.current || !message.requestId || message.requestId === latestWePropsReqIdRef.current) {
          setWePropertiesState({
            id: message.payload?.id ?? null,
            loading: false,
            properties: message.payload?.properties ?? [],
          })
        }
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
        setStudioState(previous => (
          previous.open && previous.wallpaperId === p?.wallpaperId
            ? {
                ...previous,
                loading: false,
                rendering: false,
                wallpaperId: p?.wallpaperId ?? previous.wallpaperId,
                title: p?.title ?? previous.title,
                manifest: p?.manifest ?? null,
                previewUrl: p?.previewUrl ?? '',
                baselinePreviewUrl: p?.baselinePreviewUrl || p?.previewUrl || '',
                previewWidth: p?.previewWidth ?? 0,
                previewHeight: p?.previewHeight ?? 0,
                hasPixels: p?.hasPixels ?? true,
              }
            : previous
        ))
      }
      if (message.type === 'wallpapers.scene-studio.preview') {
        const p = message.payload
        if (p?.error) {
          showToast(p.error, { status: 'error' })
        }
        setStudioState(previous => (
          previous.open && previous.wallpaperId === p?.wallpaperId
            ? {
                ...previous,
                rendering: false,
                previewUrl: p?.previewUrl ?? previous.previewUrl,
                previewWidth: p?.previewWidth ?? previous.previewWidth,
                previewHeight: p?.previewHeight ?? previous.previewHeight,
                hasPixels: p?.hasPixels ?? previous.hasPixels,
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
          setSettings(previous => ({ ...previous, ...message.payload.settings }))
          setSavedSettings(previous => ({ ...previous, ...message.payload.settings }))
        }
        if (typeof message.payload?.cacheSizeBytes === 'number') {
          setCacheSizeBytes(message.payload.cacheSizeBytes)
        }
        if (message.payload?.status) {
          setStatus(message.payload.status)
        }
      }
      if (message.type === 'error') {
        setCropActionSeq(seq => seq + 1)
        if (latestUpdateCheckReqIdRef.current && message.requestId === latestUpdateCheckReqIdRef.current) {
          latestUpdateCheckReqIdRef.current = null
          setCheckingUpdate(false)
        }
        if (activeToolboxRequestId.current && message.requestId === activeToolboxRequestId.current) {
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
    setSelectedIds(prev => (prev.length ? [] : prev))
  }, [colorFilter, filter, query, ratingFilter, sortBy, specFilter])

  useEffect(() => {
    if (loading || wallpapers.length === 0) return undefined
    return sniffWallpaperColors(wallpapers, info => {
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

  const favoriteIds = useMemo(
    () => (Array.isArray(settings.favoriteIds) ? settings.favoriteIds : []),
    [settings.favoriteIds],
  )
  const favoriteSet = useMemo(() => new Set(favoriteIds), [favoriteIds])

  const contextFilteredWallpapers = useMemo(() => {
    const normalizedQuery = deferredQuery.trim().toLocaleLowerCase()
    return wallpapers.filter(item => {
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

      return (
        !normalizedQuery ||
        item.title.toLocaleLowerCase().includes(normalizedQuery) ||
        item.workshopId.includes(normalizedQuery)
      )
    })
  }, [deferredQuery, favoriteSet, filter, ratingFilter, specFilter, wallpapers])

  const colorCounts = useMemo(() => {
    void colorVersion
    const counts = { dark: 0, light: 0, blue: 0, purple: 0, green: 0, warm: 0 }
    for (const item of contextFilteredWallpapers) {
      const bucket = getCachedColorBucket(item)
      if (bucket && Object.prototype.hasOwnProperty.call(counts, bucket)) {
        counts[bucket] += 1
      }
    }
    return counts
  }, [colorVersion, contextFilteredWallpapers])

  const toggleFavorite = useCallback(id => {
    if (!id) return
    const current = Array.isArray(savedSettingsRef.current.favoriteIds) ? savedSettingsRef.current.favoriteIds : []
    const exists = current.includes(id)
    const nextFavorites = exists
      ? current.filter(v => v !== id)
      : [...current, id]
    persistSettings({ favoriteIds: nextFavorites })
    showToast(exists ? '已取消收藏' : '已加入收藏 ♥')
  }, [persistSettings, showToast])

  const filteredWallpapers = useMemo(() => {
    void colorVersion
    const matched = colorFilter
      ? contextFilteredWallpapers.filter(item => getCachedColorBucket(item) === colorFilter)
      : contextFilteredWallpapers

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
  }, [colorFilter, colorVersion, contextFilteredWallpapers, sortBy])

  const galleryCardLayout = settings.galleryCardLayout || 'square'

  const gridLayout = useMemo(() => {
    const availableHeight = Math.max(220, stageBounds.height - 74)
    const availableWidth = Math.max(0, stageBounds.width - 16)

    let cardSize = DEFAULT_CARD_SIZE
    let cardHeight = DEFAULT_CARD_SIZE
    let maxCols = 5

    if (galleryCardLayout === 'widescreen' || galleryCardLayout === 'adaptive') {
      cardSize = availableHeight >= 610 ? 300 : (availableHeight >= 496 ? 252 : 224)
      cardHeight = Math.round(cardSize * 0.625)
      maxCols = 4
    } else {
      cardSize = availableHeight >= 610
        ? DEFAULT_CARD_SIZE
        : (availableHeight >= 496
          ? 186
          : Math.max(176, Math.min(DEFAULT_CARD_SIZE, availableHeight - 72)))
      cardHeight = cardSize
      maxCols = 5
    }

    const rows = availableHeight >= 496 ? 2 : 1
    const columnGap = Math.max(42, Math.min(stageBounds.viewportWidth * 0.05, 82))
    const roundedGap = Math.round(columnGap)
    const columns = Math.max(
      2,
      Math.min(maxCols, Math.floor((availableWidth + columnGap) / (cardSize + columnGap))),
    )

    return { columns, rows, cardSize, cardHeight, columnGap: roundedGap }
  }, [galleryCardLayout, stageBounds.height, stageBounds.viewportWidth, stageBounds.width])

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
    preloadWallpaperBatch(filteredWallpapers, nextStart, pageSize)
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

    const measure = () => {
      if (element.clientWidth <= 0 || element.clientHeight <= 0) return
      const nextWidth = element.clientWidth
      const nextHeight = element.clientHeight
      const nextViewportWidth = globalThis.innerWidth || nextWidth
      setStageBounds(prev =>
        prev.width === nextWidth &&
        prev.height === nextHeight &&
        prev.viewportWidth === nextViewportWidth
          ? prev
          : { width: nextWidth, height: nextHeight, viewportWidth: nextViewportWidth },
      )
    }

    measure()
    const observer = new ResizeObserver(measure)
    observer.observe(element)
    globalThis.addEventListener('resize', measure, { passive: true })
    return () => {
      observer.disconnect()
      globalThis.removeEventListener('resize', measure)
    }
  }, [])

  const prevPageSizeRef = useRef(pageSize)
  useEffect(() => {
    const prevSize = prevPageSizeRef.current
    if (prevSize !== pageSize) {
      prevPageSizeRef.current = pageSize
      setCurrentPage(prevPage => {
        const firstIdx = Math.max(0, (prevPage - 1) * prevSize)
        return Math.floor(firstIdx / pageSize) + 1
      })
    }
  }, [pageSize])

  const handleCaptureVideoFrame = useCallback((videoEl, item) => {
    try {
      const cap = captureVideoFrameToPng(videoEl)
      setFrameCaptureState({
        capture: cap,
        heading: `${item?.title || '视频'} · 截帧`,
        suggestedName: item?.title || 'wallpull-frame',
      })
    } catch (err) {
      showToast(err?.message || '截取当前视频帧失败')
    }
  }, [showToast])

  const handlePngAction = useCallback((mode, dataUrl, stem) => {
    if (!isNative || !dataUrl) return
    sendNativeMessage('media.png-action.request', { mode, dataUrl, stem })
  }, [isNative, sendNativeMessage])

  const handleCropAction = useCallback((mode, rect, stem) => {
    if (!isNative || !cropState) return
    sendNativeMessage('media.crop-action.request', {
      sourceKind: cropState.sourceKind || 'dataUrl',
      wallpaperId: cropState.wallpaperId ?? null,
      assetIndex: cropState.assetIndex ?? null,
      layerIndices: cropState.layerIndices ?? null,
      trimBounds: Boolean(cropState.trimBounds),
      includeBackground: Boolean(cropState.includeBackground),
      dataUrl: cropState.dataUrl ?? null,
      rect,
      mode,
      stem,
    })
  }, [cropState, isNative, sendNativeMessage])

  useEffect(() => {
    const hasBlockingModal = Boolean(
      detailItem ||
      studioState.open ||
      dupState.open ||
      toolboxOpen ||
      deleteTargets.length > 0 ||
      peerPickerState ||
      pairingPromptState ||
      frameCaptureState ||
      cropState,
    )
    const onKeyDown = event => {
      if (event.key === 'Escape') {
        if (pairingPromptState) {
          event.preventDefault()
          event.stopPropagation()
          if (!pairingPromptState.submitting) {
            setPairingPromptState(null)
          }
          return
        }
        if (peerPickerState) {
          event.preventDefault()
          event.stopPropagation()
          setPeerPickerState(null)
          return
        }
      }
      if (deleteTargets.length > 0 || peerPickerState || pairingPromptState) return
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
      if (tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT') {
        if (event.key === 'Escape') {
          document.activeElement?.blur?.()
        }
        return
      }
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
        event.preventDefault()
        event.stopPropagation()
        setCurrentPage(p => Math.max(1, Math.min(p, pageCount) - 1))
      } else if (event.key === 'ArrowRight') {
        event.preventDefault()
        event.stopPropagation()
        setCurrentPage(p => Math.min(pageCount, Math.min(p, pageCount) + 1))
      }
    }
    globalThis.addEventListener('keydown', onKeyDown, true)
    return () => globalThis.removeEventListener('keydown', onKeyDown, true)
  }, [contextMenu, cropState, deleteTargets.length, detailItem, dupState.open, filterPopoverOpen, filteredWallpapers, frameCaptureState, isNative, page, pageCount, pairingPromptState, peerPickerState, selectedIds, studioState.open, toolboxOpen, wallpapers])

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
        deleteTargets.length > 0 ||
        peerPickerState ||
        pairingPromptState ||
        frameCaptureState ||
        cropState
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
        setCurrentPage(p => Math.min(pageCount, Math.min(p, pageCount) + 1))
      } else {
        setCurrentPage(p => Math.max(1, Math.min(p, pageCount) - 1))
      }
    }
    section.addEventListener('wheel', onWheel, { passive: true })
    return () => section.removeEventListener('wheel', onWheel)
  }, [contextMenu, cropState, deleteTargets.length, detailItem, dupState.open, filterPopoverOpen, frameCaptureState, page, pageCount, pairingPromptState, peerPickerState, studioState.open, toolboxOpen])

  const detailIndex = useMemo(
    () => (detailItem ? filteredWallpapers.findIndex(item => item.id === detailItem.id) : -1),
    [detailItem, filteredWallpapers],
  )

  useEffect(() => {
    if (detailItem?.type === 'video' && globalAudioRef.current && !globalAudioRef.current.paused) {
      globalAudioRef.current.pause()
      setGlobalAudio(prev => (prev ? { ...prev, playing: false } : null))
    }
  }, [detailItem?.id, detailItem?.type])

  const handleOpenContextMenu = useCallback((item, x, y) => {
    setContextMenu({ item, x, y })
  }, [])

  const playGlobalAudioTrack = useCallback((targetItem, idx = 0) => {
    const tracks = targetItem?.audioTracks
    if (!Array.isArray(tracks) || tracks.length === 0) return
    const safeIdx = ((idx % tracks.length) + tracks.length) % tracks.length
    const track = tracks[safeIdx]
    if (!track?.url) return
    pendingAutoPlayRef.current = true
    setGlobalAudio(prev => {
      const sameUrl = prev?.track?.url === track.url
      if (sameUrl && globalAudioRef.current) {
        globalAudioRef.current.play()?.catch(() => {})
        return { ...prev, item: targetItem, trackIndex: safeIdx, track, playing: true }
      }
      return {
        item: targetItem,
        trackIndex: safeIdx,
        track,
        playing: true,
        currentTime: 0,
        duration: 0,
      }
    })
  }, [])

  const toggleGlobalAudio = useCallback(() => {
    const audio = globalAudioRef.current
    if (!audio || !globalAudio?.track?.url) return
    if (audio.paused) {
      audio.play()?.then(() => {
        setGlobalAudio(prev => (prev ? { ...prev, playing: true } : null))
      }).catch(() => {})
    } else {
      audio.pause()
      setGlobalAudio(prev => (prev ? { ...prev, playing: false } : null))
    }
  }, [globalAudio?.track?.url])

  const seekGlobalAudio = useCallback(sec => {
    const audio = globalAudioRef.current
    if (!audio || !Number.isFinite(sec)) return
    audio.currentTime = Math.max(0, sec)
    setGlobalAudio(prev => (prev ? { ...prev, currentTime: Math.max(0, sec) } : null))
  }, [])

  const stepGlobalAudioTrack = useCallback(delta => {
    if (!globalAudio?.item?.audioTracks?.length) return
    playGlobalAudioTrack(globalAudio.item, globalAudio.trackIndex + delta)
  }, [globalAudio, playGlobalAudioTrack])

  const closeGlobalAudio = useCallback(() => {
    if (globalAudioRef.current) {
      globalAudioRef.current.pause()
      globalAudioRef.current.currentTime = 0
    }
    pendingAutoPlayRef.current = false
    setGlobalAudio(null)
  }, [])

  const openDetails = useCallback((item, rect = null) => {
    if (item?.type === 'video' && globalAudioRef.current && !globalAudioRef.current.paused) {
      globalAudioRef.current.pause()
      setGlobalAudio(prev => (prev ? { ...prev, playing: false } : null))
    }
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
      baselinePreviewUrl: '',
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
    const current = Array.isArray(savedSettingsRef.current.favoriteIds) ? savedSettingsRef.current.favoriteIds : []
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
    persistSettings({ favoriteIds: nextFavorites })
  }, [allSelectedFavorited, persistSettings, selectedIds, showToast])

  const exportSelected = () => {
    sendNativeMessage('wallpapers.export.request', { ids: selectedIds })
  }

  const exportSelectedAs = () => {
    sendNativeMessage('wallpapers.export-as.request', { ids: selectedIds })
  }

  const dispatchLocalSendRequest = useCallback((msgType, payload) => {
    const peers = localsendStatus?.peers ?? []
    if (peers.length <= 1) {
      sendNativeMessage(msgType, {
        ...payload,
        peerFingerprint: peers[0]?.fingerprint ?? null,
      })
      return
    }
    setPeerPickerState({ msgType, payload })
  }, [localsendStatus, sendNativeMessage])

  const sendSelectedToTablet = () => {
    if (selectedIds.length === 0) return
    dispatchLocalSendRequest('localsend.send.request', {
      ids: selectedIds,
      targetMode: 'vault',
    })
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

  const confirmDeleteTargets = useCallback((alsoDeleteVault = false) => {
    if (!isNative || deleteTargets.length === 0) {
      setDeleteTargets([])
      return
    }
    const ids = deleteTargets.map(item => item.id)
    setDeleteTargets([])
    sendNativeMessage('wallpapers.recycle-workshop.request', {
      ids,
      alsoDeleteVault: Boolean(alsoDeleteVault),
    })
  }, [deleteTargets, isNative, sendNativeMessage])

  const activeFilterCount =
    (sortBy !== 'default' ? 1 : 0) +
    (specFilter !== 'all' ? 1 : 0) +
    (ratingFilter !== 'all' ? 1 : 0) +
    (colorFilter ? 1 : 0)
  const hasActiveFilter = activeFilterCount > 0
  const activeColorBucket = colorFilter
    ? COLOR_BUCKETS.find(b => b.value === colorFilter) ?? null
    : null

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
    root.style.setProperty('--primary', sparkColor)
    root.style.setProperty('--primary-strong', sparkColor)
    root.style.setProperty('--ring', sparkColor)
    root.style.setProperty(
      '--primary-subtle',
      `color-mix(in oklab, ${sparkColor} ${isDark ? 18 : 10}%, transparent)`,
    )
    root.style.setProperty(
      '--primary-soft',
      `color-mix(in oklab, ${sparkColor} ${isDark ? 26 : 16}%, transparent)`,
    )
    root.style.setProperty('--color-secondary', sparkColor)
    root.style.setProperty('--color-accent', sparkColor)
    root.style.setProperty('--selection-accent', sparkColor)
    root.style.setProperty(
      '--color-primary-ink',
      readableAccentInk(sparkColor, isDark),
    )
    const contentColor = readableTextColor(sparkColor)
    root.style.setProperty('--color-primary-content', contentColor)
    root.style.setProperty('--primary-foreground', contentColor)
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
                fontFamily='"MiSans VF", "Segoe UI Variable Text", "Microsoft YaHei UI", system-ui, sans-serif'
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
                {(loading || colorIndexProgress.running) ? (
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
                    ) : null}
                    {!loading && colorIndexProgress.running ? (
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
                  </div>
                ) : null}
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
                        onClick={() => updateFilterPreferences({ mediaFilter: item.value })}
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
                {activeColorBucket ? (
                  <button
                    type="button"
                    aria-label={`清除主色调筛选：${activeColorBucket.label}`}
                    onClick={() => updateFilterPreferences({ colorFilter: null })}
                    className="inline-flex h-8 items-center gap-1.5 rounded-full border border-base-300/80 bg-base-200/75 px-2.5 text-xs font-medium text-base-content/85 transition-colors hover:bg-base-200"
                  >
                    <span
                      className="h-2.5 w-2.5 shrink-0 rounded-full ring-1 ring-black/15"
                      style={{ backgroundColor: activeColorBucket.swatch }}
                    />
                    <span>{activeColorBucket.label}</span>
                    <X size={12} weight="bold" className="text-base-content/55" />
                  </button>
                ) : null}
                <div ref={filterPopoverRef} className="relative">
                  <button
                    type="button"
                    className={`btn btn-sm gap-1.5 ${
                      hasActiveFilter
                        ? 'bg-primary/12 text-[var(--color-primary-ink)] border border-primary/28 pr-2.5 pl-3'
                        : filterPopoverOpen
                          ? 'bg-base-100 text-[var(--color-primary-ink)] border border-primary/35 shadow-xs'
                          : 'btn-ghost'
                    }`}
                    aria-expanded={filterPopoverOpen}
                    onClick={() => setFilterPopoverOpen(prev => !prev)}
                  >
                    <FadersHorizontal size={15} weight="bold" />
                    <span>筛选与排序</span>
                    {hasActiveFilter ? (
                      <span className="inline-flex h-[18px] min-w-[18px] items-center justify-center rounded-full bg-primary px-1 text-[11px] font-bold leading-none text-primary-content tabular-nums">
                        {activeFilterCount}
                      </span>
                    ) : null}
                  </button>
                  <FilterPopover
                    open={filterPopoverOpen}
                    galleryCardLayout={galleryCardLayout}
                    sortBy={sortBy}
                    specFilter={specFilter}
                    ratingFilter={ratingFilter}
                    colorFilter={colorFilter}
                    activeFilterCount={activeFilterCount}
                    hasActiveFilter={hasActiveFilter}
                    colorCounts={colorCounts}
                    colorIndexRunning={colorIndexProgress.running || scanProgress?.phase === 'color-index'}
                    sparkColor={sparkColor}
                    onChangeCardLayout={nextLayout => persistSettings({ galleryCardLayout: nextLayout })}
                    onUpdateFilters={updateFilterPreferences}
                    onResetFilters={() => {
                      updateFilterPreferences({
                        sortBy: 'default',
                        specFilter: 'all',
                        ratingFilter: 'all',
                        colorFilter: null,
                      })
                    }}
                  />
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
                  layoutMode={galleryCardLayout}
                  cardSize={gridLayout.cardSize}
                  cardHeight={gridLayout.cardHeight}
                  columnGap={gridLayout.columnGap}
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
                  skeletonCount={loading && wallpapers.length === 0 ? pageSize : 0}
                  isDark={isDark}
                  paused={
                    Boolean(detailItem) ||
                    studioState.open ||
                    dupState.open ||
                    toolboxOpen ||
                    Boolean(frameCaptureState) ||
                    Boolean(cropState)
                  }
                />
              ) : wallpapers.length > 0 ? (
                <div className="flex flex-1 flex-col items-center justify-center gap-3 text-center">
                  <div className="flex h-12 w-12 items-center justify-center rounded-2xl bg-base-200 text-base-content/55">
                    <MagnifyingGlass size={24} weight="regular" />
                  </div>
                  <div>
                    <p className="font-medium">没有匹配的壁纸</p>
                  </div>
                  <button
                    type="button"
                    className="btn btn-ghost btn-sm mt-1"
                      onClick={() => {
                        setQuery('')
                        updateFilterPreferences({
                          mediaFilter: 'all',
                          specFilter: 'all',
                          ratingFilter: 'all',
                          colorFilter: null,
                        })
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
                    onClick={() => setCurrentPage(p => Math.max(1, Math.min(p, pageCount) - 1))}
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
                    onClick={() => setCurrentPage(p => Math.min(pageCount, Math.min(p, pageCount) + 1))}
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
                      className="btn btn-sm btn-ghost text-primary hover:bg-primary/10"
                      disabled={!isNative}
                      onClick={sendSelectedToTablet}
                    >
                      <PaperPlaneTilt size={14} weight="bold" />
                      发到平板
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
            savedSettings={savedSettings}
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
            localsendStatus={localsendStatus}
            onRefreshLocalsend={() => sendNativeMessage('localsend.scan.request', {})}
            onRotatePin={() => sendNativeMessage('localsend.rotate-pin.request', {})}
            onUnpairAll={() => sendNativeMessage('localsend.unpair-all.request', {})}
            suppressEscape={Boolean(peerPickerState || pairingPromptState || toolboxOpen || dupState.open || detailItem || studioState.open || deleteTargets.length > 0 || frameCaptureState || cropState)}
            onCheckUpdate={checkLatestUpdate}
            onOpenExternalUrl={openExternalUrl}
            sendNativeMessage={sendNativeMessage}
            persistSettings={persistSettings}
            ffmpegStatus={ffmpegStatus}
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
          globalAudio={globalAudio}
          onPlayGlobalAudio={playGlobalAudioTrack}
          onToggleGlobalAudio={toggleGlobalAudio}
          onSeekGlobalAudio={seekGlobalAudio}
          onSendToTablet={(item, assetIndex) => dispatchLocalSendRequest('localsend.send.request', {
            ids: [item.id],
            assetIndex,
            targetMode: 'vault',
          })}
          onPushClipboardToTablet={(item, assetIndex) => dispatchLocalSendRequest('localsend.send.request', {
            ids: [item.id],
            assetIndex,
            targetMode: 'clipboard',
          })}
          onOpenLayerStudio={item => {
            setDetailItem(null)
            openLayerStudio(item)
          }}
          onCaptureFrame={handleCaptureVideoFrame}
          onOpenCrop={payload => setCropState(payload)}
          onDelete={item => setDeleteTargets([item])}
          suppressHotkeys={Boolean(deleteTargets.length > 0 || peerPickerState || pairingPromptState || frameCaptureState || cropState)}
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
          onSendToTablet={item => {
            const ids =
              selectedSet.has(item.id) && selectedIds.length > 1 ? selectedIds : [item.id]
            dispatchLocalSendRequest('localsend.send.request', {
              ids,
              targetMode: 'vault',
            })
          }}
          onPushClipboardToTablet={item => dispatchLocalSendRequest('localsend.send.request', {
            ids: [item.id],
            targetMode: 'clipboard',
          })}
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
          suppressHotkeys={Boolean(peerPickerState || pairingPromptState || cropState)}
          onPreviewChange={handleStudioPreviewChange}
          onExport={handleStudioExport}
          onOpenCrop={payload => setCropState(payload)}
          onSendToTablet={req => dispatchLocalSendRequest('localsend.send-studio.request', req)}
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
          ffmpegStatus={ffmpegStatus}
        />
        <VideoFrameCaptureDialog
          open={Boolean(frameCaptureState)}
          capture={frameCaptureState?.capture || null}
          heading={frameCaptureState?.heading || '视频高清截帧'}
          suggestedName={frameCaptureState?.suggestedName || 'wallpull-frame'}
          isNative={isNative}
          onPngAction={handlePngAction}
          onOpenCrop={cap => {
            const heading = frameCaptureState?.suggestedName
              ? `${frameCaptureState.suggestedName} · 截帧比例裁切`
              : '视频截帧比例裁切'
            const suggestedName = frameCaptureState?.suggestedName || 'wallpull-frame'
            setFrameCaptureState(null)
            setCropState({
              src: cap.dataUrl,
              heading,
              suggestedName,
              sourceKind: 'dataUrl',
              dataUrl: cap.dataUrl,
              nativeSize: cap.width > 0 && cap.height > 0 ? { w: cap.width, h: cap.height } : null,
            })
          }}
          onClose={() => setFrameCaptureState(null)}
        />
        <ImageCropDialog
          open={Boolean(cropState)}
          sourceKind={cropState?.sourceKind || 'dataUrl'}
          src={cropState?.src || ''}
          heading={cropState?.heading || '智能比例裁切台'}
          suggestedName={cropState?.suggestedName || 'wallpull-crop'}
          nativeSize={cropState?.nativeSize || null}
          actionDoneSeq={cropActionSeq}
          isNative={isNative}
          onCropAction={handleCropAction}
          onPngAction={handlePngAction}
          onClose={() => setCropState(null)}
        />
        <audio
          ref={globalAudioRef}
          src={globalAudio?.track?.url || undefined}
          preload="metadata"
          onCanPlay={event => {
            if (pendingAutoPlayRef.current) {
              pendingAutoPlayRef.current = false
              event.currentTarget.play()?.catch(() => {})
            }
          }}
          onLoadedMetadata={event => {
            const dur = event.currentTarget.duration
            setGlobalAudio(prev => (prev ? { ...prev, duration: Number.isFinite(dur) ? dur : 0 } : null))
          }}
          onTimeUpdate={event => {
            const cur = event.currentTarget.currentTime
            const dur = event.currentTarget.duration
            setGlobalAudio(prev => (prev
              ? {
                  ...prev,
                  currentTime: Number.isFinite(cur) ? cur : 0,
                  duration: Number.isFinite(dur) ? dur : prev.duration,
                }
              : null))
          }}
          onPlay={() => setGlobalAudio(prev => (prev ? { ...prev, playing: true } : null))}
          onPause={() => setGlobalAudio(prev => (prev ? { ...prev, playing: false } : null))}
          onEnded={() => stepGlobalAudioTrack(1)}
        />
        <StackedToaster
          toasts={toasts}
          isDark={isDark}
          offsetBottomClass={
            selectedIds.length > 0 &&
            page === 'library' &&
            !detailItem &&
            !toolboxOpen &&
            !studioState.open &&
            !dupState.open &&
            deleteTargets.length === 0
              ? 'bottom-[84px]'
              : 'bottom-6'
          }
          onDismiss={dismissToast}
          onHoverChange={hovered => { toastHoveredRef.current = hovered }}
          onAction={toast => {
            if (toast.actionUrl) openExternalUrl({ url: toast.actionUrl })
            else if (toast.destination && isNative) sendNativeMessage('shell.open-path.request', { path: toast.destination })
          }}
        />
        <FloatingActivityIsland
          localsendProgress={localsendProgress}
          toolboxProgress={toolboxProgress}
          toolboxBusy={!toolboxOpen && toolboxBusy}
          toolboxCancelling={toolboxCancelling}
          onCancelToolbox={() => {
            setToolboxCancelling(true)
            sendNativeMessage('toolbox.task.cancel', {})
          }}
          globalAudio={globalAudio}
          onToggleAudio={toggleGlobalAudio}
          onPrevAudio={() => stepGlobalAudioTrack(-1)}
          onNextAudio={() => stepGlobalAudioTrack(1)}
          onSeekAudio={seekGlobalAudio}
          onCloseAudio={closeGlobalAudio}
          isDark={isDark}
          raised={Boolean(
            selectedIds.length > 0 &&
            page === 'library' &&
            !detailItem &&
            !toolboxOpen &&
            !studioState.open &&
            !dupState.open &&
            deleteTargets.length === 0
          )}
        />
        {createPortal(
          <AnimatePresence>
            {peerPickerState ? (
              <motion.div
                key="peer-picker-backdrop"
                className="fixed inset-0 z-70 flex items-center justify-center bg-black/38 p-5 backdrop-blur-[3px]"
                initial={{ opacity: 0 }}
                animate={{ opacity: 1 }}
                exit={{ opacity: 0 }}
                transition={{ duration: 0.16 }}
                onMouseDown={e => {
                  if (e.target === e.currentTarget) setPeerPickerState(null)
                }}
              >
                <motion.div
                  role="dialog"
                  aria-modal="true"
                  aria-label="选择接收设备"
                  className="w-full max-w-sm rounded-[22px] border border-base-300/85 bg-base-100/92 p-5 shadow-2xl backdrop-blur-2xl"
                  initial={{ opacity: 0, scale: 0.95, y: 10 }}
                  animate={{ opacity: 1, scale: 1, y: 0 }}
                  exit={{ opacity: 0, scale: 0.96, y: 6 }}
                  transition={{ duration: 0.16, ease: [0.2, 0, 0, 1] }}
                >
                  <div className="mb-3.5 flex items-center justify-between">
                    <h3 className="text-sm font-semibold">选择接收设备</h3>
                    <button
                      type="button"
                      className="btn btn-xs btn-ghost h-7 w-7 min-w-0 rounded-full p-0"
                      aria-label="关闭选择设备"
                      onClick={() => setPeerPickerState(null)}
                    >
                      <X size={14} weight="bold" />
                    </button>
                  </div>
                  <div className="space-y-2">
                    {(localsendStatus?.peers ?? []).map(peer => (
                      <button
                        key={peer.fingerprint}
                        type="button"
                        className="flex w-full items-center justify-between rounded-xl border border-base-300/75 bg-base-200/45 px-3.5 py-2.5 text-left transition hover:border-primary/50 hover:bg-primary/8"
                        onClick={() => {
                          const req = peerPickerState
                          setPeerPickerState(null)
                          sendNativeMessage(req.msgType, {
                            ...req.payload,
                            peerFingerprint: peer.fingerprint,
                          })
                        }}
                      >
                        <div className="min-w-0">
                          <p className="truncate text-sm font-medium">{peer.alias}</p>
                          <p className="tabular-nums text-xs text-base-content/55">{peer.ip}:{peer.port}</p>
                        </div>
                        <span className={`badge badge-sm ${peer.isWallpullIpad ? 'badge-primary' : 'badge-ghost'}`}>
                          {peer.isWallpullIpad ? 'WallPull iPad' : (peer.deviceModel || 'WallPull')}
                        </span>
                      </button>
                    ))}
                  </div>
                </motion.div>
              </motion.div>
            ) : null}
          </AnimatePresence>,
          document.body,
        )}
        {createPortal(
          <AnimatePresence>
            {pairingPromptState ? (
              <motion.div
                key="pairing-pin-backdrop"
                className="fixed inset-0 z-75 flex items-center justify-center bg-black/45 p-5 backdrop-blur-[4px]"
                initial={{ opacity: 0 }}
                animate={{ opacity: 1 }}
                exit={{ opacity: 0 }}
                transition={{ duration: 0.16 }}
                onMouseDown={e => {
                  if (e.target === e.currentTarget && !pairingPromptState.submitting) {
                    setPairingPromptState(null)
                  }
                }}
              >
                <motion.form
                  role="dialog"
                  aria-modal="true"
                  aria-label="设备配对验证"
                  className="w-full max-w-sm rounded-[22px] border border-base-300/85 bg-base-100/95 p-5 shadow-2xl backdrop-blur-2xl"
                  initial={{ opacity: 0, scale: 0.95, y: 10 }}
                  animate={{ opacity: 1, scale: 1, y: 0 }}
                  exit={{ opacity: 0, scale: 0.96, y: 6 }}
                  transition={{ duration: 0.16, ease: [0.2, 0, 0, 1] }}
                  onSubmit={event => {
                    event.preventDefault()
                    if (!pairingPromptState || pairingPromptState.submitting) return
                    const cleanPin = pairingPromptState.pin.replace(/\D/g, '').slice(0, 4)
                    if (cleanPin.length !== 4) {
                      setPairingPromptState(prev => (prev ? { ...prev, error: '请输入 4 位数字配对码' } : null))
                      return
                    }
                    setPairingPromptState(prev => (prev ? { ...prev, submitting: true, error: '' } : null))
                    sendNativeMessage('localsend.pair.request', {
                      peerFingerprint: pairingPromptState.peerFingerprint,
                      pin: cleanPin,
                    })
                  }}
                >
                  <div className="mb-3 flex items-center justify-between">
                    <h3 className="text-sm font-semibold">配对「{pairingPromptState.peerAlias}」</h3>
                    <button
                      type="button"
                      className="btn btn-xs btn-ghost h-7 w-7 min-w-0 rounded-full p-0"
                      aria-label="取消配对"
                      disabled={pairingPromptState.submitting}
                      onClick={() => setPairingPromptState(null)}
                    >
                      <X size={14} weight="bold" />
                    </button>
                  </div>
                  <p className="mb-4 text-center text-xs text-base-content/65">
                    输入平板「跨端互联」中显示的 4 位配对码
                  </p>
                  <OtpPinInput
                    length={4}
                    label="跨端配对码"
                    value={pairingPromptState.pin}
                    error={pairingPromptState.error}
                    disabled={pairingPromptState.submitting}
                    autoFocus
                    onChange={nextPin => {
                      setPairingPromptState(prev => (prev ? { ...prev, pin: nextPin, error: '' } : null))
                    }}
                    onComplete={cleanPin => {
                      if (!pairingPromptState || pairingPromptState.submitting) return
                      setPairingPromptState(prev => (prev ? { ...prev, submitting: true, error: '' } : null))
                      sendNativeMessage('localsend.pair.request', {
                        peerFingerprint: pairingPromptState.peerFingerprint,
                        pin: cleanPin,
                      })
                    }}
                  />
                  {pairingPromptState.error ? (
                    <p className="mt-2.5 text-center text-xs font-medium text-error">{pairingPromptState.error}</p>
                  ) : null}
                  <div className="mt-5 flex items-center justify-end gap-2">
                    <button
                      type="button"
                      className="btn btn-ghost btn-sm"
                      disabled={pairingPromptState.submitting}
                      onClick={() => setPairingPromptState(null)}
                    >
                      取消
                    </button>
                    <button
                      type="submit"
                      className="btn btn-primary btn-sm"
                      disabled={pairingPromptState.submitting || pairingPromptState.pin.length !== 4}
                    >
                      {pairingPromptState.submitting ? <span className="loading loading-spinner loading-xs" /> : null}
                      确认配对
                    </button>
                  </div>
                </motion.form>
              </motion.div>
            ) : null}
          </AnimatePresence>,
          document.body,
        )}
      </div>
    </ClickSpark>
  )
}
