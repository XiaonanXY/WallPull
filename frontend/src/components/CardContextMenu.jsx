import { useEffect, useLayoutEffect, useRef, useState } from 'react'
import { createPortal } from 'react-dom'
import { AnimatePresence, motion } from 'motion/react'
import {
  CheckCircle,
  Compass,
  Copy,
  Desktop,
  DeviceTablet,
  DownloadSimple,
  FolderOpen,
  Heart,
  PaperPlaneTilt,
  Stack,
  Trash,
} from '@phosphor-icons/react'

export default function CardContextMenu({
  state,
  isSelected = false,
  selectedCount = 0,
  isFavorited = false,
  isNative = false,
  onClose,
  onToggleSelect,
  onOpenLayerStudio,
  onCopy,
  onSetDesktop,
  onSendToTablet,
  onPushClipboardToTablet,
  onExport,
  onToggleFavorite,
  onOpenFolder,
  onOpenWorkshop,
  onDelete,
}) {
  const menuRef = useRef(null)
  const [measuredHeight, setMeasuredHeight] = useState(356)

  useEffect(() => {
    if (!state) return undefined
    const close = () => onClose?.()
    const onPointerDown = event => {
      if (menuRef.current?.contains(event.target)) return
      close()
    }
    const onKeyDown = event => {
      if (event.key === 'Escape') close()
    }
    globalThis.addEventListener('pointerdown', onPointerDown)
    globalThis.addEventListener('keydown', onKeyDown)
    globalThis.addEventListener('scroll', close, { capture: true, passive: true })
    globalThis.addEventListener('resize', close, { passive: true })
    return () => {
      globalThis.removeEventListener('pointerdown', onPointerDown)
      globalThis.removeEventListener('keydown', onKeyDown)
      globalThis.removeEventListener('scroll', close, { capture: true })
      globalThis.removeEventListener('resize', close)
    }
  }, [onClose, state])

  useLayoutEffect(() => {
    if (!state || !menuRef.current) return
    const h = menuRef.current.offsetHeight
    if (h > 0) setMeasuredHeight(h)
  }, [state])

  const menuWidth = 208
  const left = state
    ? Math.max(12, Math.min(state.x, (globalThis.innerWidth || 1280) - menuWidth - 12))
    : 0
  const top = state
    ? Math.max(12, Math.min(state.y, (globalThis.innerHeight || 860) - measuredHeight - 12))
    : 0

  const batchDeleteLabel =
    isSelected && selectedCount > 1
      ? `删除已选 (${selectedCount} 项)`
      : '删除壁纸'

  const batchSendTabletLabel =
    isSelected && selectedCount > 1
      ? `发送到 iPad (${selectedCount} 项)`
      : '发送到 iPad'

  return createPortal(
    <AnimatePresence>
      {state ? (
        <motion.div
          ref={menuRef}
          role="menu"
          aria-label="壁纸快捷操作"
          style={{ left, top, width: menuWidth }}
          className="fixed z-60 flex flex-col gap-0.5 rounded-2xl border border-base-300 bg-base-100/95 p-1.5 text-sm text-base-content shadow-xl backdrop-blur-xl"
          initial={{ opacity: 0, scale: 0.95, y: 4 }}
          animate={{ opacity: 1, scale: 1, y: 0 }}
          exit={{ opacity: 0, scale: 0.97 }}
          transition={{ duration: 0.14, ease: [0.2, 0, 0, 1] }}
        >
          <button
            type="button"
            role="menuitem"
            className="flex h-8 w-full items-center gap-2.5 rounded-xl px-3 text-left font-medium whitespace-nowrap hover:bg-base-content/7"
            onClick={() => {
              onToggleSelect?.(state.item.id)
              onClose?.()
            }}
          >
            <CheckCircle
              size={15}
              weight={isSelected ? 'fill' : 'regular'}
              className={isSelected ? 'shrink-0 text-primary' : 'shrink-0'}
            />
            <span>{isSelected ? '取消多选' : '加入多选'}</span>
          </button>
          <button
            type="button"
            role="menuitem"
            className="flex h-8 w-full items-center gap-2.5 rounded-xl px-3 text-left font-medium whitespace-nowrap hover:bg-base-content/7"
            onClick={() => {
              onToggleFavorite?.(state.item.id)
              onClose?.()
            }}
          >
            <Heart
              size={15}
              weight={isFavorited ? 'fill' : 'regular'}
              className={isFavorited ? 'shrink-0 text-rose-500' : 'shrink-0'}
            />
            <span>{isFavorited ? '取消收藏' : '加入收藏'}</span>
          </button>
          <button
            type="button"
            role="menuitem"
            disabled={!isNative}
            className="flex h-8 w-full items-center gap-2.5 rounded-xl px-3 text-left font-medium whitespace-nowrap hover:bg-base-content/7 disabled:opacity-45"
            onClick={() => {
              onCopy?.(state.item)
              onClose?.()
            }}
          >
            <Copy size={15} className="shrink-0" />
            <span>{state.item.type === 'video' ? '复制原视频' : '复制原图'}</span>
          </button>
          <button
            type="button"
            role="menuitem"
            disabled={!isNative}
            className="flex h-8 w-full items-center gap-2.5 rounded-xl px-3 text-left font-medium whitespace-nowrap hover:bg-base-content/7 disabled:opacity-45"
            onClick={() => {
              onSetDesktop?.(state.item)
              onClose?.()
            }}
          >
            <Desktop size={15} className="shrink-0" />
            <span>设为桌面壁纸</span>
          </button>
          <button
            type="button"
            role="menuitem"
            disabled={!isNative}
            className="flex h-8 w-full items-center gap-2.5 rounded-xl px-3 text-left font-medium whitespace-nowrap hover:bg-base-content/7 disabled:opacity-45"
            onClick={() => {
              onExport?.(state.item)
              onClose?.()
            }}
          >
            <DownloadSimple size={15} className="shrink-0" />
            <span>直接导出原文件</span>
          </button>
          <button
            type="button"
            role="menuitem"
            disabled={!isNative}
            className="flex h-8 w-full items-center gap-2.5 rounded-xl px-3 text-left font-medium whitespace-nowrap text-primary hover:bg-primary/10 disabled:opacity-45"
            onClick={() => {
              onSendToTablet?.(state.item)
              onClose?.()
            }}
          >
            <PaperPlaneTilt size={15} weight="bold" className="shrink-0" />
            <span>{batchSendTabletLabel}</span>
          </button>
          {state?.item?.type === 'image' ? (
            <button
              type="button"
              role="menuitem"
              disabled={!isNative}
              className="flex h-8 w-full items-center gap-2.5 rounded-xl px-3 text-left font-medium whitespace-nowrap hover:bg-base-content/7 disabled:opacity-45"
              onClick={() => {
                onPushClipboardToTablet?.(state.item)
                onClose?.()
              }}
            >
              <DeviceTablet size={15} weight="bold" className="shrink-0" />
              <span>推至 iPad 剪贴板</span>
            </button>
          ) : null}
          {state?.item?.hasSceneLayers ? (
            <button
              type="button"
              role="menuitem"
              disabled={!isNative}
              className="flex h-8 w-full items-center gap-2.5 rounded-xl px-3 text-left font-medium whitespace-nowrap text-primary hover:bg-primary/10 disabled:opacity-45"
              onClick={() => {
                onOpenLayerStudio?.(state.item)
                onClose?.()
              }}
            >
              <Stack size={15} weight="bold" className="shrink-0" />
              <span>透视拆解台</span>
            </button>
          ) : null}
          <div className="my-0.5 h-px bg-base-300/70" />
          <button
            type="button"
            role="menuitem"
            disabled={!isNative}
            className="flex h-8 w-full items-center gap-2.5 rounded-xl px-3 text-left font-medium whitespace-nowrap hover:bg-base-content/7 disabled:opacity-45"
            onClick={() => {
              onOpenFolder?.(state.item)
              onClose?.()
            }}
          >
            <FolderOpen size={15} className="shrink-0" />
            <span>打开原文件位置</span>
          </button>
          {!(String(state.item.workshopId || '').startsWith('99') && String(state.item.workshopId || '').length >= 15) && state.item.workshopId ? (
            <button
              type="button"
              role="menuitem"
              disabled={!isNative}
              className="flex h-8 w-full items-center gap-2.5 rounded-xl px-3 text-left font-medium whitespace-nowrap hover:bg-base-content/7 disabled:opacity-45"
              onClick={() => {
                onOpenWorkshop?.(state.item)
                onClose?.()
              }}
            >
              <Compass size={15} className="shrink-0" />
              <span>Steam 创意工坊</span>
            </button>
          ) : null}
          <div className="my-0.5 h-px bg-base-300/70" />
          <button
            type="button"
            role="menuitem"
            disabled={!isNative}
            className="flex h-8 w-full items-center gap-2.5 rounded-xl px-3 text-left font-medium whitespace-nowrap text-error hover:bg-error/10 disabled:opacity-45"
            onClick={() => {
              onDelete?.(state.item)
              onClose?.()
            }}
          >
            <Trash size={15} weight="bold" className="shrink-0" />
            <span>{batchDeleteLabel}</span>
          </button>
        </motion.div>
      ) : null}
    </AnimatePresence>,
    document.body,
  )
}
