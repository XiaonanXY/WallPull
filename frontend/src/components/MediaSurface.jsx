import { useCallback, useEffect, useRef, useState } from 'react'
import { Camera, Pause, Play, SpeakerHigh, SpeakerLow, SpeakerSlash } from '@phosphor-icons/react'
import useVideoPlaybackBudget from '../hooks/useVideoPlaybackBudget.js'
import {
  getSavedVideoTime,
  isLegacySquarePreviewUrl,
  isMediaRevealed,
  markMediaRevealed,
  saveVideoTime,
} from '../utils/mediaRevealState.js'
import './MediaSurface.css'

const SPEED_OPTIONS = [1, 1.5, 2, 0.5]

function formatVideoClock(seconds) {
  if (!Number.isFinite(seconds) || seconds <= 0) return '0:00'
  const total = Math.floor(seconds)
  const mins = Math.floor(total / 60)
  const secs = total % 60
  return `${mins}:${String(secs).padStart(2, '0')}`
}

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
  onCaptureFrame = null,
}) {
  const internalVideoRef = useRef(null)
  const videoRef = videoElementRef || internalVideoRef
  const imgRef = useRef(null)
  const scrubberRef = useRef(null)
  const volGroupRef = useRef(null)
  const volTrackRef = useRef(null)
  const lastNonZeroVolRef = useRef(1)
  const hideHudTimerRef = useRef(null)
  const restoredRef = useRef(false)
  const wasPausedRef = useRef(paused)
  const onIntrinsicSizeRef = useRef(onIntrinsicSize)
  onIntrinsicSizeRef.current = onIntrinsicSize

  const validPreviewUrl = item.previewUrl && !isLegacySquarePreviewUrl(item.previewUrl) ? item.previewUrl : ''
  const validPreviewVideoUrl = item.previewVideoUrl && !isLegacySquarePreviewUrl(item.previewVideoUrl) ? item.previewVideoUrl : ''
  const imageSrc = overrideImageSrc || (interactive
    ? (item.mediaUrl || validPreviewUrl)
    : (validPreviewUrl || item.mediaUrl))
  const videoSrc = interactive ? item.mediaUrl : (validPreviewVideoUrl || item.mediaUrl)
  const revealKey = `${item.id}:${item.type === 'video' ? videoSrc : imageSrc}`
  const [ready, setReady] = useState(() => interactive || isMediaRevealed(revealKey))
  const [fullLoaded, setFullLoaded] = useState(false)

  // Custom HUD state (active only when interactive && item.type === 'video')
  const [isPlaying, setIsPlaying] = useState(!paused)
  const [currentTime, setCurrentTime] = useState(0)
  const [duration, setDuration] = useState(0)
  const [isMuted, setIsMuted] = useState(() => !interactive)
  const [volume, setVolume] = useState(1)
  const [playbackRate, setPlaybackRate] = useState(1)
  const [isScrubbing, setIsScrubbing] = useState(false)
  const [volHovered, setVolHovered] = useState(false)
  const [isDraggingVol, setIsDraggingVol] = useState(false)
  const [hudVisible, setHudVisible] = useState(true)
  const [hudPinned, setHudPinned] = useState(false)

  const mayPlay = useVideoPlaybackBudget(
    videoRef,
    interactive ? 100 : priority,
    item.type === 'video' && !paused ? item.id : '',
  )

  const clearHideHudTimer = useCallback(() => {
    if (hideHudTimerRef.current) {
      globalThis.clearTimeout(hideHudTimerRef.current)
      hideHudTimerRef.current = null
    }
  }, [])

  const bumpHudVisibility = useCallback(() => {
    setHudVisible(true)
    clearHideHudTimer()
    if (!interactive || item.type !== 'video') return
    hideHudTimerRef.current = globalThis.setTimeout(() => {
      setHudVisible(false)
    }, 2400)
  }, [clearHideHudTimer, interactive, item.type])

  useEffect(() => () => clearHideHudTimer(), [clearHideHudTimer])

  useEffect(() => {
    if (!interactive || item.type !== 'video') return
    lastNonZeroVolRef.current = 1
    setIsMuted(false)
    setVolume(1)
    setVolHovered(false)
    setIsDraggingVol(false)
    setPlaybackRate(1)
    setCurrentTime(0)
    setDuration(0)
    setHudVisible(true)
    clearHideHudTimer()
    hideHudTimerRef.current = globalThis.setTimeout(() => {
      setHudVisible(false)
    }, 2600)
  }, [clearHideHudTimer, interactive, item.id, item.type, videoSrc])

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
    Boolean(validPreviewUrl) &&
    validPreviewUrl !== imageSrc

  const applySavedTime = useCallback(video => {
    const saved = getSavedVideoTime(item.id)
    if (saved > 0 && Number.isFinite(video.duration) && video.duration > 0) {
      const target = saved % video.duration
      if (Math.abs(video.currentTime - target) > 0.18) {
        try {
          if (!interactive && typeof video.fastSeek === 'function') {
            video.fastSeek(target)
          } else {
            video.currentTime = target
          }
        } catch {
          // ignore seek before ready
        }
      }
    }
    restoredRef.current = true
  }, [interactive, item.id])

  useEffect(() => {
    const video = videoRef.current
    if (!video || item.type !== 'video') return undefined

    restoredRef.current = false
    const reportVideoSize = () => {
      if (video.videoWidth > 0 && video.videoHeight > 0) {
        onIntrinsicSizeRef.current?.({ width: video.videoWidth, height: video.videoHeight })
      }
      if (interactive && Number.isFinite(video.duration) && video.duration > 0) {
        setDuration(video.duration)
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
      video.pause()
    }
  }, [applySavedTime, interactive, item.id, item.type, videoRef, videoSrc])

  useEffect(() => {
    const video = videoRef.current
    if (!video || item.type !== 'video') return
    const targetMuted = interactive ? isMuted : true
    const targetVolume = interactive ? volume : 0
    const targetRate = interactive ? playbackRate : 1
    video.muted = targetMuted
    if (Number.isFinite(targetVolume)) {
      video.volume = Math.max(0, Math.min(1, targetVolume))
    }
    if (Number.isFinite(targetRate) && video.playbackRate !== targetRate) {
      video.playbackRate = targetRate
    }
  }, [interactive, isMuted, item.type, playbackRate, videoRef, volume])

  useEffect(() => {
    const video = videoRef.current
    if (!video || item.type !== 'video') return undefined
    if (paused || (!interactive && !mayPlay)) {
      wasPausedRef.current = true
      if (restoredRef.current && video.currentTime > 0) {
        saveVideoTime(item.id, video.currentTime)
      }
      video.pause()
      if (interactive) setIsPlaying(false)
      return undefined
    }

    let cancelled = false
    const startPlayback = () => {
      if (cancelled) return
      if (wasPausedRef.current || !restoredRef.current) {
        wasPausedRef.current = false
        if (video.readyState >= 1) {
          applySavedTime(video)
        }
      }
      const playPromise = video.play()
      if (playPromise && typeof playPromise.then === 'function') {
        playPromise.then(() => {
          if (interactive && !cancelled) setIsPlaying(true)
        }).catch(() => {
          if (!interactive || cancelled) return
          // Fallback if WebView policy rejects unmuted autoplay without direct gesture
          video.muted = true
          setIsMuted(true)
          video.play()?.then(() => {
            if (!cancelled) setIsPlaying(true)
          }).catch(() => {
            if (!cancelled) setIsPlaying(false)
          })
        })
      }
    }

    // If a remounted video has a saved timestamp and metadata isn't ready yet, wait for
    // loadedmetadata so we seek BEFORE starting playback (prevents flashing 0:00 then jumping).
    if (video.readyState < 1 && getSavedVideoTime(item.id) > 0.18) {
      const onMetaReady = () => startPlayback()
      video.addEventListener('loadedmetadata', onMetaReady, { once: true })
      return () => {
        cancelled = true
        video.removeEventListener('loadedmetadata', onMetaReady)
      }
    }

    startPlayback()
    return () => {
      cancelled = true
    }
  }, [applySavedTime, interactive, item.id, item.type, mayPlay, paused, videoRef, videoSrc])

  const togglePlayPause = useCallback(event => {
    event?.stopPropagation?.()
    const video = videoRef.current
    if (!video || item.type !== 'video') return
    bumpHudVisibility()
    if (video.paused) {
      video.muted = interactive ? isMuted : true
      video.play()?.then(() => setIsPlaying(true)).catch(() => {})
    } else {
      video.pause()
      setIsPlaying(false)
    }
  }, [bumpHudVisibility, interactive, isMuted, item.type, videoRef])

  const seekToClientX = useCallback(clientX => {
    const video = videoRef.current
    const bar = scrubberRef.current
    if (!video || !bar) return
    const total = Number.isFinite(video.duration) && video.duration > 0 ? video.duration : duration
    if (!Number.isFinite(total) || total <= 0) return
    const rect = bar.getBoundingClientRect()
    const ratio = Math.max(0, Math.min(1, (clientX - rect.left) / Math.max(1, rect.width)))
    const nextTime = ratio * total
    setCurrentTime(nextTime)
    try {
      video.currentTime = nextTime
      saveVideoTime(item.id, nextTime)
    } catch {
      // ignore if media not yet seekable
    }
  }, [duration, item.id, videoRef])

  const applyVolumeLevel = useCallback(rawLevel => {
    const nextVol = Math.max(0, Math.min(1, Number.isFinite(rawLevel) ? rawLevel : 0))
    const mutedNow = nextVol <= 0.005
    if (nextVol > 0.02) {
      lastNonZeroVolRef.current = nextVol
    }
    setVolume(mutedNow ? 0 : nextVol)
    setIsMuted(mutedNow)
    if (videoRef.current) {
      videoRef.current.volume = mutedNow ? 0 : nextVol
      videoRef.current.muted = mutedNow
    }
  }, [videoRef])

  const applyVolumeFromClientY = useCallback(clientY => {
    const track = volTrackRef.current
    if (!track) return
    const rect = track.getBoundingClientRect()
    const nextVol = 1 - (clientY - rect.top) / Math.max(1, rect.height)
    applyVolumeLevel(nextVol)
  }, [applyVolumeLevel])

  const seekBySeconds = useCallback(deltaSec => {
    const video = videoRef.current
    if (!video) return
    const total = Number.isFinite(video.duration) && video.duration > 0 ? video.duration : duration
    if (!Number.isFinite(total) || total <= 0) return
    const nextTime = Math.max(0, Math.min(total, video.currentTime + deltaSec))
    setCurrentTime(nextTime)
    try {
      video.currentTime = nextTime
      saveVideoTime(item.id, nextTime)
    } catch {
      // ignore
    }
  }, [duration, item.id, videoRef])

  const cyclePlaybackRate = event => {
    event.stopPropagation()
    event.currentTarget?.blur?.()
    bumpHudVisibility()
    const curIdx = SPEED_OPTIONS.indexOf(playbackRate)
    const nextRate = SPEED_OPTIONS[(curIdx + 1) % SPEED_OPTIONS.length]
    setPlaybackRate(nextRate)
    if (videoRef.current) {
      videoRef.current.playbackRate = nextRate
    }
  }

  const toggleMute = event => {
    event.stopPropagation()
    event.currentTarget?.blur?.()
    bumpHudVisibility()
    const currentlyMuted = isMuted || volume <= 0.005
    if (currentlyMuted) {
      const restoredVol = lastNonZeroVolRef.current > 0.02 ? lastNonZeroVolRef.current : 0.8
      setIsMuted(false)
      setVolume(restoredVol)
      if (videoRef.current) {
        videoRef.current.muted = false
        videoRef.current.volume = restoredVol
      }
    } else {
      lastNonZeroVolRef.current = volume
      setIsMuted(true)
      if (videoRef.current) {
        videoRef.current.muted = true
      }
    }
  }

  const showFloatingHud = interactive && item.type === 'video'
  const effectiveHudVisible = hudVisible || !isPlaying || isScrubbing || isDraggingVol || hudPinned
  const progressRatio = duration > 0 ? Math.max(0, Math.min(1, currentTime / duration)) : 0
  const effectiveVolume = isMuted ? 0 : Math.max(0, Math.min(1, volume))
  const volDrawerOpen = volHovered || isDraggingVol
  const speedLabel = playbackRate === 2 ? '2.0x' : playbackRate === 1 ? '1.0x' : `${playbackRate}x`

  useEffect(() => {
    const el = volGroupRef.current
    if (!el || !showFloatingHud) return undefined
    const onNativeWheel = event => {
      event.stopPropagation()
      event.preventDefault()
      bumpHudVisibility()
      const delta = event.deltaY < 0 ? 0.08 : -0.08
      const base = isMuted ? 0 : volume
      applyVolumeLevel(base + delta)
    }
    el.addEventListener('wheel', onNativeWheel, { passive: false })
    return () => el.removeEventListener('wheel', onNativeWheel)
  }, [applyVolumeLevel, bumpHudVisibility, isMuted, showFloatingHud, volume])

  return (
    <div
      className={`media-surface ${interactive ? 'is-interactive' : ''} ${className}`}
      onMouseMove={showFloatingHud ? bumpHudVisibility : undefined}
      onMouseEnter={showFloatingHud ? bumpHudVisibility : undefined}
      onContextMenu={showFloatingHud ? event => event.preventDefault() : undefined}
    >
      <div className={`media-content-layer ${ready || item.type === 'video' ? 'is-ready' : ''}`}>
        {item.type === 'video' ? (
          <video
            ref={videoRef}
            src={videoSrc}
            crossOrigin="anonymous"
            poster={validPreviewUrl || undefined}
            aria-label={item.title}
            className="fusion-image fusion-video"
            style={{ objectFit: fit, cursor: showFloatingHud ? 'pointer' : undefined }}
            onClick={showFloatingHud ? togglePlayPause : undefined}
            onLoadedData={markReady}
            onPlay={interactive ? () => setIsPlaying(true) : undefined}
            onPause={interactive ? () => setIsPlaying(false) : undefined}
            onLoadedMetadata={interactive ? event => {
              const dur = event.currentTarget.duration
              if (Number.isFinite(dur) && dur > 0) setDuration(dur)
            } : undefined}
            onTimeUpdate={event => {
              const vid = event.currentTarget
              if (interactive) {
                if (!isScrubbing && Number.isFinite(vid.currentTime)) {
                  setCurrentTime(vid.currentTime)
                }
                if (Number.isFinite(vid.duration) && vid.duration > 0 && Math.abs(vid.duration - duration) > 0.2) {
                  setDuration(vid.duration)
                }
              }
              if (restoredRef.current && vid.currentTime > 0) {
                saveVideoTime(item.id, vid.currentTime)
              }
            }}
            onSeeked={event => {
              if (restoredRef.current) {
                saveVideoTime(item.id, event.currentTarget.currentTime)
              }
            }}
            onError={markReady}
            controls={false}
            disablePictureInPicture
            disableRemotePlayback
            controlsList="nodownload noplaybackrate noremoteplayback"
            muted={interactive ? isMuted : true}
            loop
            playsInline
            preload={interactive || mayPlay ? 'auto' : 'metadata'}
          />
        ) : (
          <>
            {showPlaceholder ? (
              <img
                src={validPreviewUrl}
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
              decoding="async"
            />
          </>
        )}
      </div>

      {showFloatingHud ? (
        <div
          className={`wp-video-hud ${effectiveHudVisible ? 'is-visible' : 'is-hidden'}`}
          onClick={event => event.stopPropagation()}
          onMouseEnter={() => {
            setHudPinned(true)
            bumpHudVisibility()
          }}
          onMouseLeave={() => {
            setHudPinned(false)
            setVolHovered(false)
            bumpHudVisibility()
          }}
        >
          <button
            type="button"
            className="wp-video-hud__btn"
            aria-label={isPlaying ? '暂停视频' : '播放视频'}
            onClick={event => {
              event.currentTarget?.blur?.()
              togglePlayPause(event)
            }}
          >
            {isPlaying ? (
              <Pause size={15} weight="fill" aria-hidden="true" />
            ) : (
              <Play size={15} weight="fill" aria-hidden="true" style={{ transform: 'translateX(0.5px)' }} />
            )}
          </button>

          <span className="wp-video-hud__clock wp-video-hud__clock--current">{formatVideoClock(currentTime)}</span>

          <div
            role="slider"
            tabIndex={0}
            aria-label="视频播放进度"
            aria-valuemin={0}
            aria-valuemax={Math.round(duration)}
            aria-valuenow={Math.round(currentTime)}
            className={`wp-video-hud__scrubber ${isScrubbing ? 'is-scrubbing' : ''}`}
            onKeyDown={event => {
              if (event.key === 'ArrowLeft' || event.key === 'ArrowRight') {
                event.preventDefault()
                event.stopPropagation()
                bumpHudVisibility()
                seekBySeconds(event.key === 'ArrowRight' ? 5 : -5)
              }
            }}
            onPointerDown={event => {
              event.stopPropagation()
              event.preventDefault()
              setIsScrubbing(true)
              bumpHudVisibility()
              try {
                event.currentTarget.setPointerCapture(event.pointerId)
              } catch {
                // ignore
              }
              seekToClientX(event.clientX)
            }}
            onPointerMove={event => {
              if (!isScrubbing) return
              bumpHudVisibility()
              seekToClientX(event.clientX)
            }}
            onPointerUp={event => {
              if (!isScrubbing) return
              seekToClientX(event.clientX)
              setIsScrubbing(false)
              bumpHudVisibility()
              try {
                event.currentTarget.releasePointerCapture(event.pointerId)
              } catch {
                // ignore
              }
            }}
            onPointerCancel={() => setIsScrubbing(false)}
            onLostPointerCapture={() => setIsScrubbing(false)}
          >
            <div ref={scrubberRef} className="wp-video-hud__track">
              <div
                className="wp-video-hud__fill"
                style={{ width: `${(progressRatio * 100).toFixed(2)}%` }}
              />
              <div
                className="wp-video-hud__thumb"
                style={{ left: `${(progressRatio * 100).toFixed(2)}%` }}
              />
            </div>
          </div>

          <span className="wp-video-hud__clock wp-video-hud__clock--total">{formatVideoClock(duration)}</span>

          <span className="wp-video-hud__divider" aria-hidden="true" />

          <button
            type="button"
            className={`wp-video-hud__speed-btn ${playbackRate !== 1 ? 'is-active' : ''}`}
            aria-label="切换播放倍速"
            onClick={cyclePlaybackRate}
          >
            {speedLabel}
          </button>

          <div
            ref={volGroupRef}
            className="wp-video-hud__vol-group"
            onPointerEnter={() => setVolHovered(true)}
            onPointerLeave={() => {
              if (!isDraggingVol) setVolHovered(false)
            }}
          >
            <button
              type="button"
              className={`wp-video-hud__btn ${effectiveVolume === 0 ? 'is-muted' : ''}`}
              aria-label={effectiveVolume === 0 ? '取消静音' : '静音'}
              onClick={toggleMute}
            >
              {effectiveVolume === 0 ? (
                <SpeakerSlash size={15} weight="fill" aria-hidden="true" />
              ) : effectiveVolume < 0.5 ? (
                <SpeakerLow size={15} weight="fill" aria-hidden="true" />
              ) : (
                <SpeakerHigh size={15} weight="fill" aria-hidden="true" />
              )}
            </button>

            <div className={`wp-video-hud__vol-drawer ${volDrawerOpen ? 'is-open' : ''}`}>
              <div
                role="slider"
                tabIndex={0}
                aria-label="视频音量"
                aria-orientation="vertical"
                aria-valuemin={0}
                aria-valuemax={100}
                aria-valuenow={Math.round(effectiveVolume * 100)}
                className={`wp-video-hud__vol-scrubber ${isDraggingVol ? 'is-dragging' : ''}`}
                onFocus={() => setVolHovered(true)}
                onBlur={() => {
                  if (!isDraggingVol) setVolHovered(false)
                }}
                onKeyDown={event => {
                  if (event.key === 'ArrowUp' || event.key === 'ArrowDown' || event.key === 'ArrowLeft' || event.key === 'ArrowRight') {
                    event.preventDefault()
                    event.stopPropagation()
                    bumpHudVisibility()
                    const step = event.key === 'ArrowUp' || event.key === 'ArrowRight' ? 0.08 : -0.08
                    applyVolumeLevel(effectiveVolume + step)
                  }
                }}
                onClick={event => event.stopPropagation()}
                onPointerDown={event => {
                  event.stopPropagation()
                  event.preventDefault()
                  setIsDraggingVol(true)
                  bumpHudVisibility()
                  try {
                    event.currentTarget.setPointerCapture(event.pointerId)
                  } catch {
                    // ignore
                  }
                  applyVolumeFromClientY(event.clientY)
                }}
                onPointerMove={event => {
                  if (!isDraggingVol) return
                  bumpHudVisibility()
                  applyVolumeFromClientY(event.clientY)
                }}
                onPointerUp={event => {
                  if (!isDraggingVol) return
                  applyVolumeFromClientY(event.clientY)
                  setIsDraggingVol(false)
                  bumpHudVisibility()
                  try {
                    event.currentTarget.releasePointerCapture(event.pointerId)
                  } catch {
                    // ignore
                  }
                }}
                onPointerCancel={() => setIsDraggingVol(false)}
                onLostPointerCapture={() => setIsDraggingVol(false)}
              >
                <div ref={volTrackRef} className="wp-video-hud__vol-track">
                  <div
                    className="wp-video-hud__vol-fill"
                    style={{ height: `${(effectiveVolume * 100).toFixed(1)}%` }}
                  />
                  <div
                    className="wp-video-hud__vol-thumb"
                    style={{ bottom: `${(effectiveVolume * 100).toFixed(1)}%` }}
                  />
                </div>
              </div>
            </div>
          </div>

          {onCaptureFrame ? (
            <button
              type="button"
              className="wp-video-hud__btn"
              aria-label="截取当前帧"
              onClick={event => {
                event.stopPropagation()
                event.currentTarget?.blur?.()
                bumpHudVisibility()
                onCaptureFrame(videoRef.current)
              }}
            >
              <Camera size={15} weight="fill" aria-hidden="true" />
            </button>
          ) : null}
        </div>
      ) : null}
    </div>
  )
}
