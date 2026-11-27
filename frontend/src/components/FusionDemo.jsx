import { memo, useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { motion } from 'motion/react'
import { MusicNotes, ShieldCheck, Stack } from '@phosphor-icons/react'
import Magnet from './Magnet.jsx'
import HoloCard from './reactbits/HoloCard.jsx'
import PulseHeart from './reactbits/PulseHeart.jsx'
import SpringCheck from './reactbits/SpringCheck.jsx'
import BorderGlow from './BorderGlow.jsx'
import MediaSurface from './MediaSurface.jsx'
import ShinyText from './reactbits/ShinyText.jsx'
import { SPARK_EVENT } from './ClickSpark.jsx'
import { formatBytes, parseResolutionDimensions } from '../appConfig.js'
import { saveVideoTime } from '../utils/mediaRevealState.js'
import './FusionDemo.css'

const CARD_RADIUS = 16

function computeAdaptiveCardHeight(item, cardSize, fallbackRatio = 0) {
  const { width, height } = parseResolutionDimensions(item?.resolution)
  let ratio = 0
  if (width > 0 && height > 0) {
    ratio = width / height
  } else if (fallbackRatio > 0) {
    ratio = fallbackRatio
  } else if (item?.type === 'video') {
    ratio = 16 / 10
  } else {
    ratio = 1
  }
  const clamped = Math.max(0.56, Math.min(2.4, ratio))
  return Math.max(88, Math.round(cardSize / clamped))
}

const PreviewCard = memo(function PreviewCard({
  item,
  mode,
  selected,
  selectionMode = false,
  favorited = false,
  badgeScheme = 'B',
  cardSize,
  cardHeight,
  selectionBorderMode,
  paused = false,
  onContextMenuItem,
  onToggleFavorite,
  onSelect,
  onToggleSelect,
  onIntrinsicRatio,
}) {
  const selectModifiersRef = useRef({ shiftKey: false, ctrlKey: false })
  const showArchiveBadge = badgeScheme === 'C' && Boolean(item.isArchivedOffline)
  const resolvedHeight = cardHeight || cardSize
  const { width: resW, height: resH } = parseResolutionDimensions(item?.resolution)
  const hasKnownResolution = resW > 0 && resH > 0
  const handleIntrinsicSize = useCallback(
    size => {
      if (size?.width > 0 && size?.height > 0) {
        onIntrinsicRatio?.(item.id, size.width / size.height)
      }
    },
    [item.id, onIntrinsicRatio],
  )
  const mediaPanel = (
    <div
      className="fusion-card-surface"
      style={{ borderRadius: CARD_RADIUS }}
    >
      <BorderGlow
        active={selected}
        borderRadius={CARD_RADIUS}
        mode={selectionBorderMode}
      >
        <MediaSurface
          key={item.id}
          item={item}
          paused={paused}
          onIntrinsicSize={!hasKnownResolution ? handleIntrinsicSize : null}
        />
        {onToggleSelect ? (
          <div
            className={`fusion-select-wrap absolute top-2.5 left-2.5 z-10 transition-opacity ${
              selected ? 'opacity-100' : selectionMode ? 'opacity-92' : 'opacity-0'
            }`}
            onClickCapture={event => {
              selectModifiersRef.current = {
                shiftKey: event.shiftKey,
                ctrlKey: event.ctrlKey || event.metaKey,
              }
            }}
            onClick={event => event.stopPropagation()}
            onKeyDown={event => event.stopPropagation()}
          >
            <SpringCheck
              checked={selected}
              onChange={() => onToggleSelect(item.id, selectModifiersRef.current)}
              label=""
              strike="none"
              boxSize={28}
              boxRadius={999}
              bounce={0.32}
              color="#ffffff"
              fillColor="var(--color-primary)"
              checkColor="var(--color-primary-content)"
              ariaLabel={selected ? '取消多选此壁纸' : '多选此壁纸'}
            />
          </div>
        ) : null}
        {onToggleFavorite ? (
          <div
            className="fusion-fav-wrap absolute top-2.5 right-2.5 z-10 opacity-0 transition-opacity focus-within:opacity-100"
            onClick={event => event.stopPropagation()}
            onKeyDown={event => event.stopPropagation()}
          >
            <PulseHeart
              liked={favorited}
              onChange={() => onToggleFavorite(item.id)}
              showCount={false}
              size={17}
              corner={999}
              pillColor="rgba(0, 0, 0, 0.44)"
              idleColor="rgba(255, 255, 255, 0.92)"
              likedColor="#ff4d6d"
              label={favorited ? '取消收藏' : '加入收藏'}
            />
          </div>
        ) : null}
        {item.assetCount > 1 || item.hasAudio || item.hasSceneLayers || showArchiveBadge ? (
          <div className="pointer-events-none absolute bottom-2.5 left-2.5 z-10 flex flex-wrap items-center gap-1.5">
            {item.hasSceneLayers ? (
              <span
                aria-hidden="true"
                className="inline-flex items-center gap-1 rounded-full bg-primary/85 px-2 py-0.5 text-[11px] font-medium text-primary-content backdrop-blur-md"
              >
                <Stack size={11} weight="bold" />
                可拆图层
              </span>
            ) : null}
            {item.assetCount > 1 ? (
              <span
                aria-hidden="true"
                className="inline-flex items-center rounded-full bg-black/48 px-2 py-0.5 text-[11px] font-medium text-white/95 backdrop-blur-md"
              >
                {item.assetCount} 张
              </span>
            ) : null}
            {item.hasAudio ? (
              <span
                aria-hidden="true"
                className="inline-flex items-center gap-1 rounded-full bg-black/48 px-2 py-0.5 text-[11px] font-medium text-white/95 backdrop-blur-md"
              >
                <MusicNotes size={11} weight="fill" />
                配乐
              </span>
            ) : null}
            {showArchiveBadge ? (
              <span
                aria-hidden="true"
                className="fusion-archive-badge inline-flex items-center gap-1 rounded-full bg-emerald-600/88 px-2 py-0.5 text-[11px] font-medium text-white opacity-0 backdrop-blur-md transition-opacity"
              >
                <ShieldCheck size={11} weight="fill" />
                已典藏
              </span>
            ) : null}
          </div>
        ) : null}
        {item.type === 'video' ? (
          <span
            aria-hidden="true"
            className="pointer-events-none absolute right-2.5 bottom-2.5 z-10 inline-flex items-center gap-1 rounded-full bg-black/48 px-2 py-0.5 text-[11px] font-medium tracking-tight text-white/95 backdrop-blur-md"
          >
            {item.duration || '视频'}
          </span>
        ) : null}
      </BorderGlow>
    </div>
  )

  let content = mediaPanel
  if (mode === 'magnet') {
    content = (
      <Magnet
        magnetStrength={7}
        wrapperClassName="fusion-magnet"
        innerClassName="fusion-magnet-inner"
      >
        {mediaPanel}
      </Magnet>
    )
  } else if (mode === 'tilt') {
    content = (
      <HoloCard
        width={cardSize}
        aspectRatio={cardSize / resolvedHeight}
        radius={CARD_RADIUS}
        tiltMax={15}
        hoverScale={1.03}
      >
        {mediaPanel}
      </HoloCard>
    )
  }

  const handleClick = event => {
    globalThis.dispatchEvent(new CustomEvent(SPARK_EVENT, {
      detail: { x: event.clientX, y: event.clientY },
    }))
    if (event.ctrlKey || event.metaKey || event.shiftKey) {
      onToggleSelect?.(item.id, {
        shiftKey: event.shiftKey,
        ctrlKey: event.ctrlKey || event.metaKey,
      })
      return
    }
    const videoEl = event.currentTarget.querySelector('video')
    if (videoEl && videoEl.currentTime > 0) {
      saveVideoTime(item.id, videoEl.currentTime)
    }
    const rect = event.currentTarget.getBoundingClientRect()
    onSelect?.(item, {
      left: rect.left,
      top: rect.top,
      width: rect.width,
      height: rect.height,
    })
  }

  const handleKeyDown = event => {
    if (event.key === 'Enter' || event.key === ' ') {
      event.preventDefault()
      if (event.ctrlKey || event.metaKey || event.shiftKey) {
        onToggleSelect?.(item.id, {
          shiftKey: event.shiftKey,
          ctrlKey: event.ctrlKey || event.metaKey,
        })
      } else {
        const videoEl = event.currentTarget.querySelector('video')
        if (videoEl && videoEl.currentTime > 0) {
          saveVideoTime(item.id, videoEl.currentTime)
        }
        const rect = event.currentTarget.getBoundingClientRect()
        onSelect?.(item, {
          left: rect.left,
          top: rect.top,
          width: rect.width,
          height: rect.height,
        })
      }
    }
  }

  const handleContextMenu = event => {
    event.preventDefault()
    onContextMenuItem?.(item, event.clientX, event.clientY)
  }

  return (
    <article
      className="fusion-card"
      role="button"
      tabIndex={0}
      onClick={handleClick}
      onContextMenu={handleContextMenu}
      onKeyDown={handleKeyDown}
      aria-label={item.title}
      aria-selected={selected}
      data-spark="off"
    >
      {content}
    </article>
  )
})

const FusionDemo = memo(function FusionDemo({
  items,
  mode,
  layoutMode = 'square',
  onSelect,
  onContextMenuItem,
  favoriteIds = [],
  onToggleFavorite,
  selectedIds = [],
  onToggleSelect,
  badgeScheme = 'B',
  cardSize = 230,
  cardHeight = 230,
  columnGap = 64,
  gridColumns = 0,
  selectionBorderMode = 'snake',
  showSize = false,
  skeletonCount = 0,
  isDark = false,
  paused = false,
}) {
  const selectedSet = useMemo(() => new Set(selectedIds), [selectedIds])
  const favoriteSet = useMemo(() => new Set(favoriteIds), [favoriteIds])
  const selectionMode = selectedIds.length > 0
  const resolvedCardHeight = cardHeight || cardSize
  const isAdaptive = layoutMode === 'adaptive'
  const [intrinsicRatios, setIntrinsicRatios] = useState({})

  const handleIntrinsicRatio = useCallback((id, ratio) => {
    if (!id || !Number.isFinite(ratio) || ratio <= 0) return
    setIntrinsicRatios(prev => {
      if (prev[id] && Math.abs(prev[id] - ratio) < 0.01) return prev
      return { ...prev, [id]: ratio }
    })
  }, [])

  const cols = Math.max(2, gridColumns || 4)
  const layoutSig = `${layoutMode}:${cols}`
  const prevLayoutSigRef = useRef(layoutSig)
  const prevItemIdsRef = useRef(new Set(items.map(it => it.id)))
  const isLayoutSwitching = prevLayoutSigRef.current !== layoutSig

  useEffect(() => {
    prevLayoutSigRef.current = layoutSig
    prevItemIdsRef.current = new Set(items.map(it => it.id))
  }, [items, layoutSig])

  const layoutPlan = useMemo(() => {
    const gapX = columnGap > 0 ? columnGap : 64
    const gapY = 44
    const metaHeight = 52
    const colHeights = new Array(cols).fill(0)

    const itemSlots = items.map((item, index) => {
      const col = index % cols
      const slotHeight = isAdaptive
        ? computeAdaptiveCardHeight(item, cardSize, intrinsicRatios[item.id])
        : resolvedCardHeight
      const x = col * (cardSize + gapX)
      const y = colHeights[col]
      colHeights[col] += slotHeight + metaHeight + gapY
      return { item, slotHeight, x, y }
    })

    const skeletonSlots = Array.from({ length: skeletonCount }, (_, i) => {
      const col = (items.length + i) % cols
      const x = col * (cardSize + gapX)
      const y = colHeights[col]
      colHeights[col] += resolvedCardHeight + metaHeight + gapY
      return { key: `skeleton-${i}`, x, y }
    })

    const totalCount = items.length + skeletonCount
    const totalWidth = cols * cardSize + (cols - 1) * gapX
    const totalHeight = Math.max(0, Math.max(...colHeights) - (totalCount > 0 ? gapY : 0))
    // Keep DOM order strictly sorted by item.id while visual order is driven by (x, y) transforms.
    // Reordering DOM nodes via insertBefore pauses & resets active <video> elements in Chromium/WebView2.
    const renderSlots = [...itemSlots].sort((a, b) => a.item.id.localeCompare(b.item.id))
    return { itemSlots, renderSlots, skeletonSlots, totalWidth, totalHeight }
  }, [cardSize, cols, columnGap, intrinsicRatios, isAdaptive, items, resolvedCardHeight, skeletonCount])

  const renderSlot = (item, slotHeight, x, y) => {
    const sizeText = showSize ? ` · ${formatBytes(item.folderSize || item.fileSize)}` : ''
    const metaLabel = `${item.type === 'video' ? '视频' : '图片'}${
      item.resolution ? `  ${item.resolution}` : ''
    }${sizeText}`
    const totalSlotHeight = slotHeight + 52
    const isNewlyRevealed = isLayoutSwitching && !prevItemIdsRef.current.has(item.id)
    return (
      <motion.div
        key={item.id}
        initial={
          isNewlyRevealed
            ? { x, y, width: cardSize, height: totalSlotHeight, opacity: 0, scale: 0.9 }
            : false
        }
        animate={{ x, y, width: cardSize, height: totalSlotHeight, opacity: 1, scale: 1 }}
        transition={{ type: 'spring', stiffness: 340, damping: 30, mass: 0.8 }}
        className="fusion-grid-slot"
      >
        <div className="fusion-card-positioner">
          <PreviewCard
            item={item}
            mode={mode}
            selected={selectedSet.has(item.id)}
            selectionMode={selectionMode}
            favorited={favoriteSet.has(item.id)}
            badgeScheme={badgeScheme}
            cardSize={cardSize}
            cardHeight={slotHeight}
            selectionBorderMode={selectionBorderMode}
            paused={paused}
            onContextMenuItem={onContextMenuItem}
            onToggleFavorite={onToggleFavorite}
            onSelect={onSelect}
            onToggleSelect={onToggleSelect}
            onIntrinsicRatio={handleIntrinsicRatio}
          />
        </div>

        <div className="fusion-meta">
          <p className="truncate font-medium">
            <ShinyText
              text={item.title}
              color={isDark ? '#d8d8e2' : '#18181b'}
              shineColor={isDark ? '#ffffff' : '#9a9ab0'}
              speed={1.6}
              shineWidth={42}
              trigger="hover"
              className="block truncate"
            />
          </p>
          <p className="mt-1 flex items-center gap-2 text-sm text-base-content/60">
            <ShinyText
              text={metaLabel}
              color={isDark ? '#9090a2' : '#646474'}
              shineColor={isDark ? '#ececf4' : '#c6c6d4'}
              speed={1.8}
              shineWidth={38}
              trigger="hover"
              className="block truncate"
            />
          </p>
        </div>
      </motion.div>
    )
  }

  return (
    <section
      className="fusion-stage"
      aria-label="壁纸预览"
      data-columns={gridColumns}
      style={{
        '--card-size': `${cardSize}px`,
        '--card-height': `${resolvedCardHeight}px`,
        '--grid-columns': gridColumns || 'auto-fit',
      }}
    >
      <div
        className="fusion-grid"
        style={{
          width: `${layoutPlan.totalWidth}px`,
          height: `${layoutPlan.totalHeight}px`,
        }}
      >
        {layoutPlan.renderSlots.map(({ item, slotHeight, x, y }) =>
          renderSlot(item, slotHeight, x, y),
        )}
        {layoutPlan.skeletonSlots.map(({ key, x, y }) => (
          <div
            key={key}
            className="fusion-grid-slot"
            aria-hidden="true"
            style={{
              width: `${cardSize}px`,
              height: `${resolvedCardHeight + 52}px`,
              transform: `translate3d(${x}px, ${y}px, 0)`,
            }}
          >
            <div className="fusion-card-positioner">
              <div className="skeleton h-full w-full rounded-[16px]" />
            </div>
            <div className="fusion-meta space-y-2">
              <div className="skeleton h-4 w-36" />
              <div className="skeleton h-3 w-24" />
            </div>
          </div>
        ))}
      </div>
    </section>
  )
})

export default FusionDemo
