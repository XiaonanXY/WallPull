import { useEffect, useRef, useState } from 'react'
import { ArrowsClockwise, ChatCircleDots, Cpu, DeviceTablet, GithubLogo, Info, X } from '@phosphor-icons/react'
import { AnimatePresence, motion } from 'motion/react'
import { formatColor } from '@appica/ui-react'
import {
  ColorSwatchPicker,
  ColorSwatchPickerItem,
} from '@appica/ui-react/color-swatch-picker'
import WakeSlider from './reactbits/WakeSlider.jsx'
import {
  APP_INFO,
  CARD_MODES,
  HARDWARE_ACCELERATION_MODES,
  NAVIGATION_STYLES,
  SELECTION_BORDER_MODES,
  THEME_COLORS,
  THEME_MODES,
  formatBytes,
  isValidHexColor,
} from '../appConfig.js'

function extractSixDigitHex(color) {
  if (!color) return null
  if (typeof color === 'string') {
    const trimmed = color.trim()
    if (/^#[0-9a-f]{8}$/i.test(trimmed)) return trimmed.slice(0, 7).toLowerCase()
    if (isValidHexColor(trimmed)) return trimmed.toLowerCase()
    return null
  }
  try {
    const formatted = formatColor(color, 'hex')
    if (typeof formatted === 'string') {
      const trimmed = formatted.trim()
      if (/^#[0-9a-f]{8}$/i.test(trimmed)) return trimmed.slice(0, 7).toLowerCase()
      if (isValidHexColor(trimmed)) return trimmed.toLowerCase()
    }
  } catch {
    // fallback below
  }
  if (typeof color.red === 'number' && typeof color.green === 'number' && typeof color.blue === 'number') {
    const toByte = value => Math.max(0, Math.min(255, Math.round(value)))
    return `#${[color.red, color.green, color.blue]
      .map(channel => toByte(channel).toString(16).padStart(2, '0'))
      .join('')}`
  }
  return null
}

export default function SettingsPage({
  visible = true,
  layoutMode = 'island',
  onClose,
  settings,
  savedSettings = null,
  setSettings,
  isDark = false,
  isDirty = false,
  cacheSizeBytes = 0,
  detectedWorkshopRoots = [],
  gpuAdapters = [],
  activeHardwareAccelerationMode = 'gpu',
  sparkColor,
  sparkSize,
  sparkSizeText,
  setSparkSizeText,
  isNative,
  appVersion = APP_INFO.version,
  checkingUpdate = false,
  localsendStatus = null,
  onRefreshLocalsend,
  onRotatePin,
  onUnpairAll,
  suppressEscape = false,
  onCheckUpdate,
  onOpenExternalUrl,
  sendNativeMessage,
  persistSettings,
}) {
  const [savedNotice, setSavedNotice] = useState(false)
  const noticeTimerRef = useRef(null)
  const restartTimerRef = useRef(null)
  const sliderMax = 100
  const currentAccelMode = settings.hardwareAccelerationMode === 'cpu' ? 'cpu' : 'gpu'
  const currentThemeMode = settings.themeMode === 'dark' ? 'dark' : 'light'
  const needsRestartForAccel = currentAccelMode !== activeHardwareAccelerationMode
  const hasInvalidColor = !isValidHexColor(settings.sparkColor)

  useEffect(() => () => {
    if (noticeTimerRef.current) globalThis.clearTimeout(noticeTimerRef.current)
    if (restartTimerRef.current) globalThis.clearTimeout(restartTimerRef.current)
  }, [])

  useEffect(() => {
    if (!visible || suppressEscape) return undefined
    const handleEscape = event => {
      if (event.key === 'Escape') {
        event.preventDefault()
        onClose?.()
      }
    }
    globalThis.addEventListener('keydown', handleEscape)
    return () => globalThis.removeEventListener('keydown', handleEscape)
  }, [onClose, suppressEscape, visible])

  const commitSettingPatch = patch => {
    if (savedSettings) {
      persistSettings?.({ ...savedSettings, ...patch }, { ...settings, ...patch })
    } else {
      persistSettings?.({ ...settings, ...patch })
    }
  }

  const handleSave = () => {
    if (hasInvalidColor) return
    persistSettings(settings)
    setSavedNotice(true)
    if (noticeTimerRef.current) globalThis.clearTimeout(noticeTimerRef.current)
    noticeTimerRef.current = globalThis.setTimeout(() => setSavedNotice(false), 2000)
  }

  const saveAndRestart = () => {
    if (hasInvalidColor) return
    persistSettings(settings)
    if (restartTimerRef.current) globalThis.clearTimeout(restartTimerRef.current)
    restartTimerRef.current = globalThis.setTimeout(() => {
      sendNativeMessage('app.restart.request')
    }, 150)
  }

  const settingsBody = (
    <>
      <div className="flex items-start justify-between gap-4">
        <div>
          <h1 className="text-2xl font-semibold tracking-tight">设置</h1>
        </div>
        <div className="flex items-center gap-2">
          {savedNotice ? (
            <span className="badge badge-success badge-sm">设置已保存</span>
          ) : null}
          <button
            type="button"
            className="btn btn-ghost btn-sm h-8 w-8 min-w-0 px-0"
            aria-label="关闭设置"
            onClick={onClose}
          >
            <X size={16} weight="bold" />
          </button>
        </div>
      </div>

      <div className={`${layoutMode === 'drawer' ? 'mt-5 space-y-5' : 'mt-8 space-y-6'}`}>
          <section className="space-y-6 rounded-2xl border border-base-300/70 bg-base-200/45 p-6">
            <h2 className="text-xs font-semibold tracking-wider text-base-content/55 uppercase">
              目录与存储
            </h2>
            <fieldset className="fieldset">
              <legend className="fieldset-legend">Wallpaper Engine 创意工坊路径</legend>
              <div className="flex items-center gap-2">
                <input
                  className="input input-sm flex-1"
                  value={settings.workshopRoot ?? ''}
                  onChange={event =>
                    setSettings(previous => ({ ...previous, workshopRoot: event.target.value }))}
                  placeholder={detectedWorkshopRoots[0] || '留空时自动检测本机 Steam 库'}
                />
                <button
                  className="btn btn-ghost btn-sm shrink-0"
                  type="button"
                  disabled={!isNative}
                  onClick={() => sendNativeMessage('settings.detect-workshop.request')}
                >
                  自动检测
                </button>
                <button
                  className="btn btn-ghost btn-sm shrink-0"
                  type="button"
                  disabled={!isNative}
                  onClick={() => sendNativeMessage('settings.pick-workshop.request')}
                >
                  选择
                </button>
              </div>
              {detectedWorkshopRoots.length > 0 && !settings.workshopRoot ? (
                <p className="label whitespace-normal">
                  已自动识别：{detectedWorkshopRoots.join('；')}
                </p>
              ) : null}
            </fieldset>

            <fieldset className="fieldset">
              <legend className="fieldset-legend">默认导出路径</legend>
              <div className="flex items-center gap-2">
                <input
                  className="input input-sm flex-1"
                  value={settings.exportDirectory ?? ''}
                  onChange={event =>
                    setSettings(previous => ({ ...previous, exportDirectory: event.target.value }))}
                />
                <button
                  className="btn btn-ghost btn-sm shrink-0"
                  type="button"
                  disabled={!isNative}
                  onClick={() => sendNativeMessage('settings.pick-export.request')}
                >
                  选择
                </button>
              </div>
            </fieldset>

            <div className="flex flex-wrap items-center justify-between gap-3 border-t border-base-300/60 pt-4">
              <div>
                <p className="text-sm font-medium">本地缓存</p>
                <p className="mt-0.5 text-xs text-base-content/60 tabular-nums">
                  {cacheSizeBytes > 0 ? formatBytes(cacheSizeBytes) : '0 B'}
                </p>
              </div>
              <button
                type="button"
                className="btn btn-ghost btn-sm"
                disabled={!isNative}
                onClick={() => sendNativeMessage('settings.clear-cache.request')}
              >
                清理缓存
              </button>
            </div>
          </section>

          <section className="space-y-6 rounded-2xl border border-base-300/70 bg-base-200/45 p-6">
            <h2 className="text-xs font-semibold tracking-wider text-base-content/55 uppercase">
              外观与交互
            </h2>
            <fieldset className="fieldset">
              <legend className="fieldset-legend">外观模式</legend>
              <div className="flex flex-wrap items-center gap-2" role="group" aria-label="外观模式">
                {THEME_MODES.map(item => {
                  const isActive = currentThemeMode === item.value
                  return (
                    <button
                      key={item.value}
                      type="button"
                      className={`btn btn-sm ${isActive ? 'btn-primary' : 'btn-ghost'}`}
                      aria-pressed={isActive}
                      onClick={() => commitSettingPatch({ themeMode: item.value })}
                    >
                      {item.label}
                    </button>
                  )
                })}
              </div>
            </fieldset>

            <fieldset className="fieldset">
              <legend className="fieldset-legend">界面主题色</legend>
              <div className="flex flex-wrap items-center gap-4">
                <ColorSwatchPicker
                  aria-label="界面主题色板"
                  shape="circle"
                  size={34}
                  value={sparkColor}
                  onValueChange={color => {
                    const hex = extractSixDigitHex(color)
                    if (hex) {
                      commitSettingPatch({ sparkColor: hex })
                    }
                  }}
                >
                  {THEME_COLORS.map(color => (
                    <ColorSwatchPickerItem key={color} color={color} />
                  ))}
                </ColorSwatchPicker>
                <input
                  className={`input input-sm w-36 ${
                    isValidHexColor(settings.sparkColor) ? '' : 'input-error'
                  }`}
                  value={settings.sparkColor}
                  onChange={event =>
                    setSettings(previous => ({ ...previous, sparkColor: event.target.value }))}
                  placeholder="#7C3AED"
                  aria-label="自定义界面主题色号"
                />
              </div>
            </fieldset>

            <fieldset className="fieldset">
              <legend className="fieldset-legend">点击火花大小</legend>
              <div className="flex items-center gap-4">
                <div className="flex-1">
                  <WakeSlider
                    value={Math.min(sparkSize, sliderMax)}
                    min={0}
                    max={sliderMax}
                    step={1}
                    bars={36}
                    height={44}
                    restHeight={10}
                    gap={4}
                    fillColor={sparkColor}
                    trackColor={isDark ? '#2a2a3a' : '#e4e2ec'}
                    crestColor="#ffffff"
                    onChange={value => {
                      setSparkSizeText(String(value))
                      setSettings(previous => ({
                        ...previous,
                        sparkSizePercent: value,
                      }))
                    }}
                    ariaLabel="点击火花大小滑块"
                  />
                </div>
                <input
                  className="input input-sm w-24"
                  type="text"
                  inputMode="numeric"
                  pattern="[0-9]*"
                  value={sparkSizeText}
                  onChange={event => {
                    const value = event.target.value
                    if (!/^\d*$/.test(value)) return
                    setSparkSizeText(value)
                    setSettings(previous => ({
                      ...previous,
                      sparkSizePercent: value === '' ? 0 : Number(value),
                    }))
                  }}
                  aria-label="火花大小百分比"
                />
              </div>
            </fieldset>

            <fieldset className="fieldset">
              <legend className="fieldset-legend">选中边框动画</legend>
              <div className="flex flex-wrap gap-2" role="group" aria-label="选中边框动画">
                {SELECTION_BORDER_MODES.map(item => {
                  const isActive = settings.selectionBorderMode === item.value
                  return (
                    <button
                      key={item.value}
                      type="button"
                      className={`btn btn-sm ${isActive ? 'btn-primary' : 'btn-ghost'}`}
                      aria-pressed={isActive}
                      onClick={() => commitSettingPatch({ selectionBorderMode: item.value })}
                    >
                      {item.label}
                    </button>
                  )
                })}
              </div>
            </fieldset>

            <fieldset className="fieldset">
              <legend className="fieldset-legend">顶栏与设置样式</legend>
              <div className="flex flex-wrap gap-2" role="group" aria-label="顶栏与设置样式">
                {NAVIGATION_STYLES.map(item => {
                  const isActive = (settings.navigationStyle || 'island') === item.value
                  return (
                    <button
                      key={item.value}
                      type="button"
                      className={`btn btn-sm ${isActive ? 'btn-primary' : 'btn-ghost'}`}
                      aria-pressed={isActive}
                      onClick={() => commitSettingPatch({ navigationStyle: item.value })}
                    >
                      {item.label}
                    </button>
                  )
                })}
              </div>
            </fieldset>

            <fieldset className="fieldset">
              <legend className="fieldset-legend">卡片悬浮物理手感</legend>
              <div className="flex flex-wrap gap-2" role="group" aria-label="卡片悬浮手感">
                {CARD_MODES.map(item => {
                  const isActive = (settings.cardMode || 'tilt') === item.value
                  return (
                    <button
                      key={item.value}
                      type="button"
                      className={`btn btn-sm ${isActive ? 'btn-primary' : 'btn-ghost'}`}
                      aria-pressed={isActive}
                      onClick={() => commitSettingPatch({ cardMode: item.value })}
                    >
                      {item.value === 'tilt' ? '全息 3D 倾斜' : '磁吸弹性跟随'}
                    </button>
                  )
                })}
              </div>
            </fieldset>
          </section>

          <section className="space-y-6 rounded-2xl border border-base-300/70 bg-base-200/45 p-6">
            <h2 className="text-xs font-semibold tracking-wider text-base-content/55 uppercase">
              窗口与后台常驻
            </h2>

            <div className="flex flex-wrap items-center justify-between gap-4">
              <div>
                <p className="text-sm font-medium">关闭窗口时最小化到系统托盘</p>
              </div>
              <button
                type="button"
                role="switch"
                className="wv-switch"
                aria-label="关闭时最小化到系统托盘"
                aria-checked={Boolean(settings.closeToTray)}
                onClick={() => commitSettingPatch({ closeToTray: !settings.closeToTray })}
              >
                <span className="wv-switch__thumb" />
              </button>
            </div>
          </section>

          <section className="space-y-6 rounded-2xl border border-base-300/70 bg-base-200/45 p-6">
            <div className="flex flex-wrap items-center justify-between gap-2">
              <h2 className="flex items-center gap-1.5 text-xs font-semibold tracking-wider text-base-content/55">
                <DeviceTablet size={14} weight="bold" />
                跨端互联
              </h2>
              <span className="badge badge-sm border-base-300/80 bg-base-100/75 tabular-nums font-medium text-base-content/70">
                {settings.localsendEnabled === false
                  ? '已关闭'
                  : (localsendStatus?.localIps?.[0]
                      ? `${localsendStatus.localIps[0]}:${localsendStatus.port || 53417}`
                      : `端口 ${localsendStatus?.port || 53417}`)}
              </span>
            </div>

            <div className="flex flex-wrap items-center justify-between gap-4">
              <div>
                <p className="text-sm font-medium">启用局域网跨端传输</p>
              </div>
              <button
                type="button"
                role="switch"
                className="wv-switch"
                aria-label="启用局域网跨端传输"
                aria-checked={settings.localsendEnabled !== false}
                onClick={() => commitSettingPatch({
                  localsendEnabled: settings.localsendEnabled === false,
                })}
              >
                <span className="wv-switch__thumb" />
              </button>
            </div>

            <fieldset className="fieldset">
              <legend className="fieldset-legend">本机显示名称</legend>
              <div className="flex items-center gap-2">
                <input
                  type="text"
                  maxLength={48}
                  className="input input-sm flex-1"
                  value={settings.localsendAlias ?? 'WallPull PC'}
                  onChange={event => setSettings(prev => ({ ...prev, localsendAlias: event.target.value }))}
                  onBlur={event => {
                    const nextAlias = event.target.value.trim() || 'WallPull PC'
                    const savedAlias = savedSettings?.localsendAlias || 'WallPull PC'
                    if (nextAlias !== savedAlias) {
                      commitSettingPatch({ localsendAlias: nextAlias })
                    }
                  }}
                  placeholder="WallPull PC"
                />
              </div>
            </fieldset>

            <div className="flex flex-wrap items-center justify-between gap-3 border-t border-base-300/60 pt-4">
              <div className="flex flex-wrap items-center gap-2">
                <span className="text-sm font-medium">配对码</span>
                <span className="badge badge-sm border-base-300/80 bg-base-100/90 tabular-nums text-xs font-bold tracking-widest text-primary">
                  {localsendStatus?.pairPin || '----'}
                </span>
                <button
                  type="button"
                  className="btn btn-ghost btn-xs h-7 px-2.5"
                  disabled={!isNative}
                  onClick={() => onRotatePin?.()}
                >
                  换码
                </button>
              </div>
              {(localsendStatus?.trustedCount || 0) > 0 ? (
                <button
                  type="button"
                  className="btn btn-ghost btn-xs h-7 px-2.5 text-error hover:bg-error/10"
                  disabled={!isNative}
                  onClick={() => onUnpairAll?.()}
                >
                  解除配对 ({localsendStatus.trustedCount})
                </button>
              ) : null}
            </div>

            <div className="flex flex-wrap items-center justify-between gap-3 border-t border-base-300/60 pt-4">
              <div className="min-w-0 flex-1">
                <p className="text-sm font-medium">
                  在线接收设备{localsendStatus?.peers?.length ? `（${localsendStatus.peers.length}）` : ''}
                </p>
                {localsendStatus?.peers?.length ? (
                  <div className="mt-1.5 flex flex-wrap items-center gap-1.5">
                    {localsendStatus.peers.map(peer => (
                      <span
                        key={peer.fingerprint}
                        className="inline-flex items-center gap-1.5 rounded-full border border-base-300/80 bg-base-100/85 px-2.5 py-0.5 text-xs text-base-content/85"
                      >
                        <span className={`h-1.5 w-1.5 rounded-full ${peer.isWallpullIpad ? 'bg-primary' : 'bg-success'}`} />
                        <span className="font-medium">{peer.alias}</span>
                        <span className="tabular-nums text-[11px] text-base-content/50">{peer.ip}</span>
                      </span>
                    ))}
                  </div>
                ) : (
                  <p className="mt-0.5 text-xs text-base-content/60">暂未发现在线设备</p>
                )}
              </div>
              <button
                type="button"
                className="btn btn-ghost btn-sm shrink-0"
                disabled={!isNative}
                onClick={() => onRefreshLocalsend?.()}
              >
                <ArrowsClockwise size={14} weight="bold" />
                刷新设备
              </button>
            </div>
          </section>

          <section className="space-y-6 rounded-2xl border border-base-300/70 bg-base-200/45 p-6">
            <h2 className="text-xs font-semibold tracking-wider text-base-content/55 uppercase">
              硬件与渲染
            </h2>
            <fieldset className="fieldset">
              <legend className="fieldset-legend flex items-center gap-2">
                <Cpu size={16} weight="regular" />
                <span>硬件加速与渲染引擎</span>
              </legend>
              <div className="flex flex-wrap items-center gap-2" role="group" aria-label="硬件加速模式">
                {HARDWARE_ACCELERATION_MODES.map(item => {
                  const isActive = currentAccelMode === item.value
                  return (
                    <button
                      key={item.value}
                      type="button"
                      className={`btn btn-sm ${isActive ? 'btn-primary' : 'btn-ghost'}`}
                      aria-pressed={isActive}
                      onClick={() => commitSettingPatch({ hardwareAccelerationMode: item.value })}
                    >
                      {item.label}
                    </button>
                  )
                })}
                {needsRestartForAccel && isNative ? (
                  <button
                    type="button"
                    className="btn btn-sm btn-ghost"
                    onClick={saveAndRestart}
                  >
                    立即重启生效
                  </button>
                ) : null}
              </div>
              {gpuAdapters.length > 0 ? (
                <p className="label whitespace-normal">
                  本机已检测到显卡：
                  {gpuAdapters
                    .map(gpu => gpu.memoryBytes > 0
                      ? `${gpu.name}（显存 ${formatBytes(gpu.memoryBytes)}）`
                      : gpu.name)
                    .join(' / ')}
                </p>
              ) : null}
              {needsRestartForAccel ? (
                <p className="label text-primary whitespace-normal">
                  已保存新的硬件加速模式，重启应用后生效。
                </p>
              ) : null}
            </fieldset>
          </section>

          <section className="space-y-4 rounded-2xl border border-base-300/70 bg-base-200/45 p-6">
            <div className="flex flex-wrap items-center justify-between gap-2">
              <h2 className="flex items-center gap-1.5 text-xs font-semibold tracking-wider text-base-content/55 uppercase">
                <Info size={14} weight="bold" />
                关于与反馈
              </h2>
              <span className="badge badge-sm border-base-300/80 bg-base-100/75 font-medium text-base-content/75">
                {APP_INFO.name} v{appVersion} · {APP_INFO.license}
              </span>
            </div>

            <div className="flex flex-wrap items-center justify-between gap-2.5">
              <span className="text-sm font-medium text-base-content">
                作者：{APP_INFO.author}
              </span>
              <div className="flex flex-wrap items-center gap-2">
                <button
                  type="button"
                  className="btn btn-sm btn-outline border-base-300/80 bg-base-100/75 hover:bg-base-100"
                  onClick={() => onOpenExternalUrl?.({ url: APP_INFO.repoUrl })}
                >
                  <GithubLogo size={15} weight="fill" />
                  GitHub 链接
                </button>
                <button
                  type="button"
                  className="btn btn-sm btn-primary"
                  onClick={() => onOpenExternalUrl?.({
                    url: APP_INFO.feedbackUrl,
                    copyText: APP_INFO.feedbackGroupNumber,
                    toastMessage: `已复制群号：${APP_INFO.feedbackGroupNumber}`,
                  })}
                >
                  <ChatCircleDots size={15} weight="fill" />
                  交流反馈
                </button>
                <button
                  type="button"
                  className="btn btn-sm btn-outline border-base-300/80 bg-base-100/75 hover:bg-base-100"
                  disabled={checkingUpdate}
                  onClick={() => onCheckUpdate?.()}
                >
                  <ArrowsClockwise
                    size={15}
                    weight="bold"
                    className={checkingUpdate ? 'animate-spin' : ''}
                  />
                  {checkingUpdate ? '正在检查…' : '检查更新'}
                </button>
              </div>
            </div>
          </section>

          {isDirty ? (
            <motion.div
              className="sticky bottom-4 z-10 flex items-center justify-end gap-3 rounded-2xl border border-base-300 bg-base-100/92 px-4 py-3 shadow-lg backdrop-blur-md"
              initial={{ opacity: 0, y: 8 }}
              animate={{ opacity: 1, y: 0 }}
              transition={{ duration: 0.18 }}
            >
              {hasInvalidColor ? (
                <span className="text-sm text-error">请输入有效的 6 位十六进制色号（如 #7C3AED）</span>
              ) : null}
              <button
                className="btn btn-primary btn-sm"
                type="button"
                disabled={hasInvalidColor}
                onClick={handleSave}
              >
                保存设置
              </button>
            </motion.div>
          ) : null}
        </div>
    </>
  )

  if (layoutMode === 'drawer') {
    return (
      <AnimatePresence>
        {visible ? (
          <motion.div
            key="settings-drawer-backdrop"
            className="fixed inset-0 top-12 z-45 flex justify-end bg-black/14"
            initial={{ opacity: 0 }}
            animate={{ opacity: 1 }}
            exit={{ opacity: 0 }}
            transition={{ duration: 0.16 }}
            onMouseDown={event => {
              if (event.target === event.currentTarget) onClose?.()
            }}
          >
            <motion.aside
              role="dialog"
              aria-modal="true"
              aria-label="设置抽屉"
              className="settings-page h-full w-full max-w-[540px] overflow-y-auto border-l border-base-300/85 bg-base-100/88 px-6 py-6 text-base-content shadow-2xl backdrop-blur-2xl"
              initial={{ x: 460, opacity: 0.5 }}
              animate={{ x: 0, opacity: 1 }}
              exit={{ x: 460, opacity: 0 }}
              transition={{ type: 'spring', stiffness: 400, damping: 36 }}
            >
              {settingsBody}
            </motion.aside>
          </motion.div>
        ) : null}
      </AnimatePresence>
    )
  }

  return (
    <AnimatePresence>
      {visible ? (
        <motion.div
          key="settings-modal-backdrop"
          className="fixed inset-0 z-45 flex items-center justify-center bg-black/38 p-5 backdrop-blur-[3px]"
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
            aria-label="设置"
            className="settings-page max-h-[84vh] w-full max-w-3xl overflow-y-auto rounded-[24px] border border-base-300/85 bg-base-100/92 px-7 py-6 text-base-content shadow-2xl backdrop-blur-2xl"
            initial={{ opacity: 0, scale: 0.95, y: 12 }}
            animate={{ opacity: 1, scale: 1, y: 0 }}
            exit={{ opacity: 0, scale: 0.96, y: 8 }}
            transition={{ duration: 0.18, ease: [0.2, 0, 0, 1] }}
          >
            {settingsBody}
          </motion.div>
        </motion.div>
      ) : null}
    </AnimatePresence>
  )
}
