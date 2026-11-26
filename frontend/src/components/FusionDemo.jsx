import { memo, useMemo, useRef } from 'react'
import { MusicNotes, ShieldCheck, Stack } from '@phosphor-icons/react'
import Magnet from './Magnet.jsx'
import HoloCard from './reactbits/HoloCard.jsx'
import PulseHeart from './reactbits/PulseHeart.jsx'
import SpringCheck from './reactbits/SpringCheck.jsx'
import BorderGlow from './BorderGlow.jsx'
import MediaSurface from './MediaSurface.jsx'
import ShinyText from './reactbits/ShinyText.jsx'
import { SPARK_EVENT } from './ClickSpark.jsx'
import { formatBytes } from '../appConfig.js'
import { saveVideoTime } from '../utils/mediaRevealState.js'
import './FusionDemo.css'

const CARD_RADIUS = 16

const PreviewCard = memo(function PreviewCard({
  item,
  mode,
  selected,
  selectionMode = false,
  favorited = false,
  badgeScheme = 'B',
  cardSize,
  selectionBorderMode,
  paused = false,
  onContextMenuItem,
  onToggleFavorite,
  onSelect,
  onToggleSelect,
}) {
  const selectModifiersRef = useRef({ shiftKey: false, ctrlKey: false })
  const showArchiveBadge = badgeScheme === 'C' && Boolean(item.isArchivedOffline)
  const mediaPanel = (
    <div
      className="fusion-card-surface"
      style={{
        width: cardSize,
        height: cardSize,
        borderRadius: CARD_RADIUS,
      }}
    >
      <BorderGlow
        active={selected}
        borderRadius={CARD_RADIUS}
        mode={selectionBorderMode}
      >
        <MediaSurface
          key={item.previewVideoUrl || item.previewUrl || item.mediaUrl}
          item={item}
          paused={paused}
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
        aspectRatio={1}
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
  onSelect,
  onContextMenuItem,
  favoriteIds = [],
  onToggleFavorite,
  selectedIds = [],
  onToggleSelect,
  badgeScheme = 'B',
  cardSize = 230,
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

  return (
    <section
      className="fusion-stage"
      aria-label="壁纸预览"
      data-columns={gridColumns}
      style={{
        '--card-size': `${cardSize}px`,
        '--grid-columns': gridColumns || 'auto-fit',
      }}
    >
      <div className="fusion-grid">
        {items.map(item => {
          const sizeText = showSize ? ` · ${formatBytes(item.folderSize || item.fileSize)}` : ''
          const metaLabel = `${item.type === 'video' ? '视频' : '图片'}${
            item.resolution ? `  ${item.resolution}` : ''
          }${sizeText}`
          return (
            <div key={item.id} className="fusion-grid-slot">
              <div className="fusion-card-positioner">
                <PreviewCard
                  item={item}
                  mode={mode}
                  selected={selectedSet.has(item.id)}
                  selectionMode={selectionMode}
                  favorited={favoriteSet.has(item.id)}
                  badgeScheme={badgeScheme}
                  cardSize={cardSize}
                  selectionBorderMode={selectionBorderMode}
                  paused={paused}
                  onContextMenuItem={onContextMenuItem}
                  onToggleFavorite={onToggleFavorite}
                  onSelect={onSelect}
                  onToggleSelect={onToggleSelect}
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
            </div>
          )
        })}
        {Array.from({ length: skeletonCount }, (_, index) => (
          <div key={`skeleton-${index}`} className="fusion-grid-slot" aria-hidden="true">
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
