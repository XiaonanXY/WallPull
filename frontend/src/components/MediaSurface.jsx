import { useCallback, useEffect, useRef, useState } from 'react'
import useVideoPlaybackBudget from '../hooks/useVideoPlaybackBudget.js'
import {
  getSavedVideoTime,
  isMediaRevealed,
  markMediaRevealed,
  saveVideoTime,
} from '../utils/mediaRevealState.js'
import './MediaSurface.css'

export default function MediaSurface({
  item,
  priority = 0,
  className = '',
  fit = 'cover',
  interactive = false,
  paused = false,
  overrideImageSrc = '',
  videoElementRef = null,
  onIntrinsicSize = null,
}) {
  const internalVideoRef = useRef(null)
  const videoRef = videoElementRef || internalVideoRef
  const imgRef = useRef(null)
  const restoredRef = useRef(false)
  const wasPausedRef = useRef(paused)
  const onIntrinsicSizeRef = useRef(onIntrinsicSize)
  onIntrinsicSizeRef.current = onIntrinsicSize
  const imageSrc = overrideImageSrc || (interactive
    ? (item.mediaUrl || item.previewUrl)
    : (item.previewUrl || item.mediaUrl))
  const videoSrc = interactive ? item.mediaUrl : (item.previewVideoUrl || item.mediaUrl)
  const revealKey = `${item.id}:${item.type === 'video' ? videoSrc : imageSrc}`
  const [ready, setReady] = useState(() => interactive || isMediaRevealed(revealKey))
  const [fullLoaded, setFullLoaded] = useState(false)

  const mayPlay = useVideoPlaybackBudget(
    videoRef,
    interactive ? 100 : priority,
    item.type === 'video' && !paused ? item.id : '',
  )

  useEffect(() => {
    setFullLoaded(false)
  }, [imageSrc])

  useEffect(() => {
    const img = imgRef.current
    if (img && img.complete && img.naturalWidth > 0) {
      if (img.naturalHeight > 0) {
        onIntrinsicSizeRef.current?.({ width: img.naturalWidth, height: img.naturalHeight })
      }
      setFullLoaded(true)
      if (!ready) {
        markMediaRevealed(revealKey)
        setReady(true)
      }
    }
  }, [imageSrc, ready, revealKey])

  const markReady = () => {
    markMediaRevealed(revealKey)
    if (!ready) setReady(true)
  }

  const showPlaceholder = interactive &&
    item.type !== 'video' &&
    !fullLoaded &&
    Boolean(item.previewUrl) &&
    item.previewUrl !== imageSrc

  const applySavedTime = useCallback(video => {
    const saved = getSavedVideoTime(item.id)
    if (saved > 0 && Number.isFinite(video.duration) && video.duration > 0) {
      const target = saved % video.duration
      if (Math.abs(video.currentTime - target) > 0.18) {
        try {
          video.currentTime = target
        } catch {
          // ignore seek before ready
        }
      }
    }
    restoredRef.current = true
  }, [item.id])

  useEffect(() => {
    const video = videoRef.current
    if (!video || item.type !== 'video') return undefined

    restoredRef.current = false
    const reportVideoSize = () => {
      if (video.videoWidth > 0 && video.videoHeight > 0) {
        onIntrinsicSizeRef.current?.({ width: video.videoWidth, height: video.videoHeight })
      }
    }
    const onLoadedMetadata = () => {
      reportVideoSize()
      applySavedTime(video)
    }

    if (video.readyState >= 1) {
      reportVideoSize()
      applySavedTime(video)
    } else {
      video.addEventListener('loadedmetadata', onLoadedMetadata, { once: true })
    }

    return () => {
      video.removeEventListener('loadedmetadata', onLoadedMetadata)
      if (restoredRef.current && video.currentTime > 0) {
        saveVideoTime(item.id, video.currentTime)
      }
    }
  }, [applySavedTime, item.id, item.type, videoRef, videoSrc])

  useEffect(() => {
    const video = videoRef.current
    if (!video || item.type !== 'video') return
    if (paused || (!interactive && !mayPlay)) {
      wasPausedRef.current = true
      if (restoredRef.current && video.currentTime > 0) {
        saveVideoTime(item.id, video.currentTime)
      }
      video.pause()
      return
    }

    if (wasPausedRef.current || !restoredRef.current) {
      wasPausedRef.current = false
      if (video.readyState >= 1) {
        applySavedTime(video)
      }
    }

    const play = video.play()
    play?.catch?.(() => {})
  }, [applySavedTime, interactive, item.id, item.type, mayPlay, paused, videoRef, videoSrc])

  return (
    <div className={`media-surface ${interactive ? 'is-interactive' : ''} ${className}`}>
      <div className={`media-content-layer ${ready || item.type === 'video' ? 'is-ready' : ''}`}>
        {item.type === 'video' ? (
          <video
            ref={videoRef}
            src={videoSrc}
            poster={item.previewUrl || undefined}
            aria-label={item.title}
            className="fusion-image fusion-video"
            style={{ objectFit: fit }}
            onLoadedData={markReady}
            onTimeUpdate={event => {
              if (restoredRef.current && event.currentTarget.currentTime > 0) {
                saveVideoTime(item.id, event.currentTarget.currentTime)
              }
            }}
            onSeeked={event => {
              if (restoredRef.current) {
                saveVideoTime(item.id, event.currentTarget.currentTime)
              }
            }}
            onError={markReady}
            controls={interactive}
            muted
            loop
            playsInline
            preload="auto"
          />
        ) : (
          <>
            {showPlaceholder ? (
              <img
                src={item.previewUrl}
                alt=""
                aria-hidden="true"
                className="fusion-image fusion-still absolute inset-0"
                style={{ objectFit: fit }}
                draggable="false"
                decoding="async"
              />
            ) : null}
            <img
              ref={imgRef}
              src={imageSrc}
              alt={item.title}
              className="fusion-image fusion-still relative z-[1]"
              style={{ objectFit: fit }}
              onLoad={event => {
                const { naturalWidth, naturalHeight } = event.currentTarget
                if (naturalWidth > 0 && naturalHeight > 0) {
                  onIntrinsicSizeRef.current?.({ width: naturalWidth, height: naturalHeight })
                }
                setFullLoaded(true)
                markReady()
              }}
              onError={markReady}
              draggable="false"
              loading="eager"
              decoding={interactive ? 'async' : 'sync'}
            />
          </>
        )}
      </div>
    </div>
  )
}
