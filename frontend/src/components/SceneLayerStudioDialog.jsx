import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { createPortal } from 'react-dom'
import { motion } from 'motion/react'
import {
  ArrowCounterClockwise,
  CaretDown,
  CaretRight,
  Copy,
  Desktop,
  DownloadSimple,
  Eraser,
  Eye,
  EyeSlash,
  Image as ImageIcon,
  Stack,
  X,
} from '@phosphor-icons/react'

const ROLE_LABELS = {
  background: { label: '背景', badgeClass: 'bg-sky-500/15 text-sky-600 dark:text-sky-300' },
  character: { label: '角色立绘', badgeClass: 'bg-primary/15 text-primary' },
  effect: { label: '光效氛围', badgeClass: 'bg-amber-500/15 text-amber-600 dark:text-amber-300' },
  subject: { label: '主体图层', badgeClass: 'bg-emerald-500/15 text-emerald-600 dark:text-emerald-300' },
}

const BACKDROP_MODES = [
  { value: 'checker', label: '透明棋盘' },
  { value: 'dark', label: '纯黑底' },
  { value: 'light', label: '纯白底' },
]

const CHECKER_STYLE = {
  backgroundColor: '#d4d4dc',
  backgroundImage: [
    'linear-gradient(45deg, #c2c2cc 25%, transparent 25%)',
    'linear-gradient(-45deg, #c2c2cc 25%, transparent 25%)',
    'linear-gradient(45deg, transparent 75%, #c2c2cc 75%)',
    'linear-gradient(-45deg, transparent 75%, #c2c2cc 75%)',
  ].join(', '),
  backgroundSize: '20px 20px',
  backgroundPosition: '0 0, 0 10px, 10px -10px, -10px 0',
}

export default function SceneLayerStudioDialog({
  open,
  state,
  isNative,
  onPreviewChange,
  onExport,
  onClose,
}) {
  const [visibleSet, setVisibleSet] = useState(() => new Set())
  const [expandedGroups, setExpandedGroups] = useState(() => new Set())
  const [backdrop, setBackdrop] = useState('checker')
  const [trimBounds, setTrimBounds] = useState(true)
  const [zoom, setZoom] = useState(1)
  const [pan, setPan] = useState({ x: 0, y: 0 })
  const panRef = useRef(null)
  const previewTimerRef = useRef(null)
  const initializedForRef = useRef(null)

  const manifest = state?.manifest ?? null
  const groups = useMemo(() => manifest?.groups ?? [], [manifest])
  const layers = useMemo(() => manifest?.layers ?? [], [manifest])

  useEffect(() => {
    if (!open || !manifest || !state?.wallpaperId) {
      if (!open) {
        initializedForRef.current = null
      }
      return
    }

    const sessionKey = `${state.wallpaperId}:${layers.length}`
    if (initializedForRef.current === sessionKey) {
      return
    }

    initializedForRef.current = sessionKey
    const defaults = new Set(layers.filter(l => l.defaultVisible).map(l => l.index))
    setVisibleSet(defaults)
    setZoom(1)
    setPan({ x: 0, y: 0 })
    setTrimBounds(true)
    if (groups.length <= 3) {
      setExpandedGroups(new Set(groups.map(g => g.key)))
    } else {
      setExpandedGroups(new Set())
    }
  }, [groups, layers, manifest, open, state?.wallpaperId])

  useEffect(() => {
    if (!open) return undefined
    const onKeyDown = event => {
      if (event.key === 'Escape') {
        event.preventDefault()
        onClose?.()
      }
    }
    globalThis.addEventListener('keydown', onKeyDown)
    return () => {
      globalThis.removeEventListener('keydown', onKeyDown)
      if (previewTimerRef.current) {
        globalThis.clearTimeout(previewTimerRef.current)
      }
    }
  }, [onClose, open])

  const commitVisibleSet = useCallback(nextSet => {
    setVisibleSet(nextSet)
    if (!state?.wallpaperId) return
    if (previewTimerRef.current) {
      globalThis.clearTimeout(previewTimerRef.current)
    }
    previewTimerRef.current = globalThis.setTimeout(() => {
      onPreviewChange?.(state.wallpaperId, [...nextSet])
    }, 55)
  }, [onPreviewChange, state?.wallpaperId])

  const toggleGroup = useCallback(group => {
    const anyOn = group.layerIndices.some(idx => visibleSet.has(idx))
    const next = new Set(visibleSet)
    if (anyOn) {
      group.layerIndices.forEach(idx => next.delete(idx))
    } else {
      group.layerIndices.forEach(idx => next.add(idx))
    }
    commitVisibleSet(next)
  }, [commitVisibleSet, visibleSet])

  const soloGroup = useCallback(group => {
    commitVisibleSet(new Set(group.layerIndices))
  }, [commitVisibleSet])

  const toggleLayer = useCallback(layerIndex => {
    const next = new Set(visibleSet)
    if (next.has(layerIndex)) {
      next.delete(layerIndex)
    } else {
      next.add(layerIndex)
    }
    commitVisibleSet(next)
  }, [commitVisibleSet, visibleSet])

  const restoreDefaults = useCallback(() => {
    commitVisibleSet(new Set(layers.filter(l => l.defaultVisible).map(l => l.index)))
  }, [commitVisibleSet, layers])

  const stripBackgroundAndEffects = useCallback(() => {
    const bgOrFx = new Set()
    groups.forEach(group => {
      if (group.role === 'background' || group.role === 'effect') {
        group.layerIndices.forEach(idx => bgOrFx.add(idx))
      }
    })
    const next = new Set(
      layers
        .filter(layer => !bgOrFx.has(layer.index) && (layer.defaultVisible || layer.role === 'character'))
        .map(layer => layer.index),
    )
    setTrimBounds(true)
    commitVisibleSet(next)
  }, [commitVisibleSet, groups, layers])

  const clearAllLayers = useCallback(() => {
    commitVisibleSet(new Set())
  }, [commitVisibleSet])

  const includeBackground = useMemo(() => {
    const bgIndices = groups
      .filter(group => group.role === 'background')
      .flatMap(group => group.layerIndices)
    return bgIndices.some(idx => visibleSet.has(idx))
  }, [groups, visibleSet])

  const characterGroups = useMemo(
    () => groups.filter(group => group.role === 'character' || group.role === 'subject'),
    [groups],
  )

  const layerByIndex = useMemo(() => {
    const map = new Map()
    layers.forEach(layer => map.set(layer.index, layer))
    return map
  }, [layers])

  if (!open) return null

  const stageStyle = backdrop === 'checker'
    ? CHECKER_STYLE
    : backdrop === 'dark'
      ? { backgroundColor: '#111118' }
      : { backgroundColor: '#f7f7fb' }

  return createPortal(
    <div
      className="fixed inset-0 z-55 flex items-center justify-center bg-black/62 p-4 backdrop-blur-sm"
      onMouseDown={event => {
        if (event.target === event.currentTarget) onClose?.()
      }}
    >
      <motion.div
        role="dialog"
        aria-modal="true"
        aria-label="2D 壁纸透视拆解台"
        className="flex h-[88vh] w-full max-w-6xl flex-col overflow-hidden rounded-[22px] border border-base-300 bg-base-100 text-base-content shadow-2xl"
        initial={{ opacity: 0, scale: 0.96, y: 12 }}
        animate={{ opacity: 1, scale: 1, y: 0 }}
        transition={{ duration: 0.2, ease: [0.2, 0, 0, 1] }}
      >
        <header className="flex shrink-0 items-center justify-between gap-4 border-b border-base-300/70 px-6 py-4">
          <div className="flex min-w-0 items-center gap-3">
            <div className="flex h-9 w-9 shrink-0 items-center justify-center rounded-xl bg-primary/14 text-primary">
              <Stack size={19} weight="bold" />
            </div>
            <div className="min-w-0">
              <h2 className="truncate text-base font-semibold tracking-tight">
                透视拆解台 · {state?.title || '正在解析图层'}
              </h2>
              <p className="text-xs text-base-content/60">
                {manifest
                  ? `${manifest.canvasWidth} × ${manifest.canvasHeight} 原画布 · 共 ${layers.length} 个可拆图层（已开 ${visibleSet.size} 层）`
                  : '正在解包 scene.pkg 中的图层与骨骼网格…'}
              </p>
            </div>
          </div>

          <div className="flex items-center gap-2">
            <div className="join rounded-full border border-base-300 p-0.5" role="group" aria-label="画布底色">
              {BACKDROP_MODES.map(opt => (
                <button
                  key={opt.value}
                  type="button"
                  onClick={() => setBackdrop(opt.value)}
                  className={`btn btn-xs h-7 rounded-full border-0 px-3 ${
                    backdrop === opt.value ? 'btn-primary' : 'btn-ghost'
                  }`}
                >
                  {opt.label}
                </button>
              ))}
            </div>
            <button
              type="button"
              className="btn btn-ghost btn-sm h-8 w-8 min-w-0 px-0"
              aria-label="关闭透视拆解台"
              onClick={onClose}
            >
              <X size={16} weight="bold" />
            </button>
          </div>
        </header>

        <div className="flex min-h-0 flex-1 overflow-hidden">
          <div
            className="relative flex min-w-0 flex-1 items-center justify-center overflow-hidden border-r border-base-300/70"
            style={{ ...stageStyle, cursor: zoom > 1 ? 'grab' : 'default' }}
            onWheel={event => {
              event.preventDefault()
              setZoom(prev => {
                const factor = event.deltaY < 0 ? 1.15 : 0.87
                const next = Math.max(1, Math.min(4.5, Number((prev * factor).toFixed(2))))
                if (next <= 1) setPan({ x: 0, y: 0 })
                return next
              })
            }}
            onPointerDown={event => {
              if (event.button !== 0 || zoom <= 1) return
              panRef.current = { x: event.clientX, y: event.clientY, startX: pan.x, startY: pan.y }
            }}
            onPointerMove={event => {
              const drag = panRef.current
              if (!drag) return
              setPan({
                x: drag.startX + (event.clientX - drag.x),
                y: drag.startY + (event.clientY - drag.y),
              })
            }}
            onPointerUp={() => { panRef.current = null }}
            onPointerCancel={() => { panRef.current = null }}
            onDoubleClick={() => {
              if (zoom > 1) {
                setZoom(1)
                setPan({ x: 0, y: 0 })
              } else {
                setZoom(2)
              }
            }}
          >
            {state?.previewUrl ? (
              <img
                src={state.previewUrl}
                alt={state.title || '图层预览'}
                draggable={false}
                className="max-h-full max-w-full object-contain select-none"
                style={
                  zoom > 1
                    ? {
                        transform: `translate3d(${pan.x}px, ${pan.y}px, 0) scale(${zoom})`,
                        transformOrigin: 'center center',
                      }
                    : undefined
                }
              />
            ) : (
              <div className="flex flex-col items-center gap-3 text-base-content/70">
                <span className="loading loading-spinner loading-md text-primary" />
                <span className="text-sm">正在解码 4K 图层纹理与骨骼网格…</span>
              </div>
            )}

            {state?.rendering ? (
              <div className="pointer-events-none absolute top-3 left-3 inline-flex items-center gap-2 rounded-full bg-black/62 px-3 py-1.5 text-xs font-medium text-white backdrop-blur-md">
                <span className="loading loading-spinner loading-xs" />
                正在实时重绘图层…
              </div>
            ) : null}

            {state?.manifest && !state?.loading && visibleSet.size === 0 ? (
              <div className="pointer-events-none absolute rounded-2xl bg-base-100/90 px-4 py-2.5 text-sm shadow-lg backdrop-blur-md">
                所有图层均已关闭，请在右侧勾选角色或底图
              </div>
            ) : null}

            {zoom > 1 ? (
              <button
                type="button"
                className="btn btn-xs absolute right-3 bottom-3 rounded-full bg-black/60 text-white backdrop-blur-md hover:bg-black/75"
                onClick={() => {
                  setZoom(1)
                  setPan({ x: 0, y: 0 })
                }}
              >
                {Math.round(zoom * 100)}% · 重置视图
              </button>
            ) : null}
          </div>

          <aside className="flex w-92 shrink-0 flex-col bg-base-200/35">
            <div className="flex shrink-0 flex-wrap items-center gap-1.5 border-b border-base-300/60 px-4 py-3">
              <button
                type="button"
                className="btn btn-xs btn-ghost rounded-full"
                disabled={!manifest}
                onClick={restoreDefaults}
              >
                <ArrowCounterClockwise size={13} weight="bold" />
                还原默认
              </button>
              <button
                type="button"
                className="btn btn-xs btn-primary rounded-full"
                disabled={!manifest}
                onClick={stripBackgroundAndEffects}
              >
                <Eraser size={13} weight="bold" />
                去背景纯立绘
              </button>
              <button
                type="button"
                className="btn btn-xs btn-ghost rounded-full"
                disabled={!manifest}
                onClick={clearAllLayers}
              >
                全关
              </button>
            </div>

            <div className="flex-1 space-y-2 overflow-y-auto p-3">
              {groups.map(group => {
                const activeCount = group.layerIndices.filter(idx => visibleSet.has(idx)).length
                const allOff = activeCount === 0
                const expanded = expandedGroups.has(group.key)
                const roleMeta = ROLE_LABELS[group.role] || ROLE_LABELS.subject

                return (
                  <div
                    key={group.key}
                    className={`rounded-2xl border transition-colors ${
                      allOff
                        ? 'border-base-300/50 bg-base-100/45 opacity-70'
                        : 'border-base-300/80 bg-base-100 shadow-xs'
                    }`}
                  >
                    <div className="flex items-center gap-2 px-3 py-2.5">
                      <button
                        type="button"
                        aria-label={expanded ? '收起子图层' : '展开子图层'}
                        className="inline-flex h-6 w-6 shrink-0 items-center justify-center rounded-lg text-base-content/55 hover:bg-base-content/8"
                        onClick={() => {
                          setExpandedGroups(prev => {
                            const next = new Set(prev)
                            if (next.has(group.key)) next.delete(group.key)
                            else next.add(group.key)
                            return next
                          })
                        }}
                      >
                        {expanded ? <CaretDown size={13} weight="bold" /> : <CaretRight size={13} weight="bold" />}
                      </button>

                      <button
                        type="button"
                        aria-label={allOff ? `显示 ${group.title}` : `隐藏 ${group.title}`}
                        className={`inline-flex h-7 w-7 shrink-0 items-center justify-center rounded-full transition-colors ${
                          allOff
                            ? 'bg-base-content/8 text-base-content/45 hover:bg-base-content/15'
                            : 'bg-primary/14 text-primary hover:bg-primary/22'
                        }`}
                        onClick={() => toggleGroup(group)}
                      >
                        {allOff ? <EyeSlash size={14} weight="bold" /> : <Eye size={14} weight="bold" />}
                      </button>

                      <div
                        className="min-w-0 flex-1 cursor-pointer"
                        onClick={() => {
                          setExpandedGroups(prev => {
                            const next = new Set(prev)
                            if (next.has(group.key)) next.delete(group.key)
                            else next.add(group.key)
                            return next
                          })
                        }}
                      >
                        <div className="flex items-center gap-1.5">
                          <span className="truncate text-sm font-semibold">{group.title}</span>
                          <span className={`shrink-0 rounded-full px-1.5 py-0.5 text-[10px] font-semibold ${roleMeta.badgeClass}`}>
                            {roleMeta.label}
                          </span>
                        </div>
                        <p className="text-[11px] text-base-content/55">
                          {activeCount}/{group.layerIndices.length} 个子图层开启
                        </p>
                      </div>

                      <button
                        type="button"
                        className="btn btn-xs btn-ghost h-6 min-h-0 px-2 text-[11px]"
                        onClick={() => soloGroup(group)}
                      >
                        独显
                      </button>

                      {group.role !== 'background' ? (
                        <button
                          type="button"
                          className="btn btn-xs btn-ghost h-6 min-h-0 px-2 text-[11px] text-primary"
                          disabled={!isNative}
                          onClick={() => onExport?.({
                            mode: 'group',
                            groupKey: group.key,
                            layerIndices: [...visibleSet],
                            trimBounds,
                            includeBackground: false,
                          })}
                        >
                          <DownloadSimple size={12} weight="bold" />
                          立绘
                        </button>
                      ) : null}
                    </div>

                    {expanded ? (
                      <div className="space-y-1 border-t border-base-300/50 px-3 py-2">
                        {group.layerIndices.map(layerIdx => {
                          const layer = layerByIndex.get(layerIdx)
                          if (!layer) return null
                          const checked = visibleSet.has(layerIdx)
                          return (
                            <label
                              key={layerIdx}
                              className="flex cursor-pointer items-center justify-between gap-2 rounded-lg px-2 py-1 text-xs hover:bg-base-content/6"
                            >
                              <span className="flex min-w-0 items-center gap-2">
                                <input
                                  type="checkbox"
                                  className="checkbox checkbox-xs checkbox-primary"
                                  checked={checked}
                                  onChange={() => toggleLayer(layerIdx)}
                                />
                                <span className={`truncate ${checked ? 'text-base-content' : 'text-base-content/45 line-through'}`}>
                                  {layer.name}
                                </span>
                              </span>
                              <span className="flex shrink-0 items-center gap-1">
                                {!layer.defaultVisible ? (
                                  <span className="rounded bg-amber-500/15 px-1 py-0.5 text-[10px] text-amber-600 dark:text-amber-300">
                                    原隐藏
                                  </span>
                                ) : null}
                                {layer.hasPuppetMesh ? (
                                  <span className="rounded bg-primary/12 px-1 py-0.5 text-[10px] text-primary">
                                    网格
                                  </span>
                                ) : null}
                              </span>
                            </label>
                          )
                        })}
                      </div>
                    ) : null}
                  </div>
                )
              })}
            </div>
          </aside>
        </div>

        <footer className="flex shrink-0 flex-wrap items-center justify-between gap-3 border-t border-base-300/70 bg-base-100 px-6 py-3.5">
          <label className="flex cursor-pointer items-center gap-2 text-xs font-medium text-base-content/80">
            <input
              type="checkbox"
              className="checkbox checkbox-xs checkbox-primary"
              checked={trimBounds}
              onChange={event => setTrimBounds(event.target.checked)}
            />
            <span>导出透明立绘时自动裁切周围空白</span>
          </label>

          <div className="flex flex-wrap items-center gap-2">
            <button
              type="button"
              className="btn btn-ghost btn-sm"
              disabled={!isNative || !manifest || visibleSet.size === 0}
              onClick={() => onExport?.({
                mode: 'copy',
                layerIndices: [...visibleSet],
                trimBounds,
                includeBackground,
              })}
            >
              <Copy size={15} weight="bold" />
              复制透明图
            </button>
            <button
              type="button"
              className="btn btn-ghost btn-sm"
              disabled={!isNative || !manifest || visibleSet.size === 0}
              onClick={() => onExport?.({
                mode: 'set-desktop',
                layerIndices: [...visibleSet],
                trimBounds: false,
                includeBackground: true,
              })}
            >
              <Desktop size={15} weight="bold" />
              设为桌面
            </button>
            {characterGroups.length >= 2 ? (
              <button
                type="button"
                className="btn btn-outline btn-primary btn-sm"
                disabled={!isNative || !manifest}
                onClick={() => onExport?.({
                  mode: 'all-characters',
                  layerIndices: [...visibleSet],
                  trimBounds,
                  includeBackground: false,
                })}
              >
                <ImageIcon size={15} weight="bold" />
                一键导出全部角色立绘 ({characterGroups.length})
              </button>
            ) : null}
            <button
              type="button"
              className="btn btn-primary btn-sm"
              disabled={!isNative || !manifest || visibleSet.size === 0}
              onClick={() => onExport?.({
                mode: 'composite',
                layerIndices: [...visibleSet],
                trimBounds,
                includeBackground,
              })}
            >
              <DownloadSimple size={15} weight="bold" />
              导出当前拆解 PNG
            </button>
          </div>
        </footer>
      </motion.div>
    </div>,
    document.body,
  )
}
