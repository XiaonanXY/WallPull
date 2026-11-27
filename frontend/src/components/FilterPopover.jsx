import { useMemo, useState } from 'react'
import { ArrowsClockwise, MusicNotes, Stack } from '@phosphor-icons/react'
import { AnimatePresence, motion, useReducedMotion } from 'motion/react'
import {
  COLOR_BUCKETS,
  GALLERY_CARD_LAYOUTS,
  RATING_FILTERS,
  SORT_MODES,
  SPEC_FILTERS,
} from '../appConfig.js'
import ArcChipGroup from './arc/ArcChipGroup.jsx'
import ArcSegmentedControl from './arc/ArcSegmentedControl.jsx'
import { arcMotion } from './arc/arcMotion.js'
import LatticeLoader from './reactbits/LatticeLoader.jsx'
import CrispColorSwatches from './ui/CrispColorSwatches.jsx'

export default function FilterPopover({
  open,
  galleryCardLayout,
  sortBy,
  specFilter,
  ratingFilter,
  colorFilter,
  activeFilterCount = 0,
  hasActiveFilter,
  colorCounts,
  colorIndexRunning,
  sparkColor,
  onChangeCardLayout,
  onUpdateFilters,
  onResetFilters,
}) {
  const reduced = Boolean(useReducedMotion())
  const [hoveredColorBucket, setHoveredColorBucket] = useState(null)

  const specOptions = useMemo(
    () =>
      SPEC_FILTERS.map(opt => {
        if (opt.value === 'audio') {
          return {
            value: opt.value,
            label: '含配乐',
            icon: <MusicNotes size={12} weight="bold" />,
          }
        }
        if (opt.value === 'layered') {
          return {
            value: opt.value,
            label: '可拆图层',
            icon: <Stack size={12} weight="bold" />,
          }
        }
        return opt
      }),
    [],
  )

  const activeBucket = COLOR_BUCKETS.find(
    b => b.value === (hoveredColorBucket ?? colorFilter),
  )

  return (
    <AnimatePresence>
      {open ? (
        <motion.div
          className="filter-popover"
          initial={reduced ? { opacity: 0 } : { opacity: 0, y: -6, scale: 0.97 }}
          animate={{ opacity: 1, y: 0, scale: 1 }}
          exit={
            reduced
              ? { opacity: 0, transition: { duration: 0.1 } }
              : {
                  opacity: 0,
                  y: -4,
                  scale: 0.98,
                  transition: { duration: arcMotion.duration.exit, ease: arcMotion.ease.standard },
                }
          }
          transition={
            reduced
              ? { duration: 0.1 }
              : { duration: arcMotion.duration.standard, ease: arcMotion.ease.enter }
          }
        >
          <section className="filter-popover__section">
            <h3 className="filter-popover__title">卡片比例</h3>
            <ArcSegmentedControl
              label="卡片比例"
              options={GALLERY_CARD_LAYOUTS}
              value={galleryCardLayout}
              onValueChange={onChangeCardLayout}
            />
          </section>

          <section className="filter-popover__section">
            <h3 className="filter-popover__title">排序方式</h3>
            <ArcChipGroup
              label="排序方式"
              options={SORT_MODES}
              value={sortBy}
              columns={2}
              onValueChange={next => onUpdateFilters({ sortBy: next })}
            />
          </section>

          <section className="filter-popover__section">
            <h3 className="filter-popover__title">规格与特性</h3>
            <ArcChipGroup
              label="规格与特性"
              options={specOptions}
              value={specFilter}
              fallbackValue="all"
              columns={3}
              onValueChange={next => onUpdateFilters({ specFilter: next })}
            />
          </section>

          <section className="filter-popover__section">
            <h3 className="filter-popover__title">内容分级</h3>
            <ArcSegmentedControl
              label="内容分级"
              options={RATING_FILTERS}
              value={ratingFilter}
              onValueChange={next => onUpdateFilters({ ratingFilter: next })}
            />
          </section>

          <section className="filter-popover__section">
            <div className="filter-popover__section-head">
              <h3 className="filter-popover__title">主色调</h3>
              {colorIndexRunning ? (
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
              ) : activeBucket ? (
                <span className="filter-popover__meta">
                  {activeBucket.label} · {colorCounts[activeBucket.value] || 0} 项
                </span>
              ) : null}
            </div>
            <div className="pt-0.5">
              <CrispColorSwatches
                ariaLabel="按主色调筛选"
                items={COLOR_BUCKETS.map(b => ({ value: b.value, color: b.swatch, label: b.label }))}
                value={colorFilter}
                size={25}
                className="gap-3.5"
                onHoverItem={bucketValue => setHoveredColorBucket(bucketValue)}
                onSelect={bucketValue =>
                  onUpdateFilters({
                    colorFilter: colorFilter === bucketValue ? null : bucketValue,
                  })}
              />
            </div>
          </section>

          {hasActiveFilter ? (
            <footer className="filter-popover__footer">
              <span className="filter-popover__summary">
                已启用 {activeFilterCount} 项筛选
              </span>
              <button
                type="button"
                className="filter-popover__reset"
                onClick={onResetFilters}
              >
                <ArrowsClockwise size={12} weight="bold" />
                <span>重置全部</span>
              </button>
            </footer>
          ) : null}
        </motion.div>
      ) : null}
    </AnimatePresence>
  )
}
