export function formatCaptureTimestamp(seconds) {
  if (!Number.isFinite(seconds) || seconds < 0) return '0:00'
  const whole = Math.floor(seconds)
  const mins = Math.floor(whole / 60)
  const secs = whole % 60
  const tenths = Math.floor((seconds - whole) * 10)
  return `${mins}:${String(secs).padStart(2, '0')}.${tenths}`
}

export function captureVideoFrameToPng(videoEl) {
  if (!videoEl) {
    throw new Error('未找到正在播放的视频画面。')
  }
  const width = Number(videoEl.videoWidth) || 0
  const height = Number(videoEl.videoHeight) || 0
  if (width <= 0 || height <= 0 || videoEl.readyState < 2) {
    throw new Error('视频画面尚未加载完成，请稍候再试。')
  }

  const canvas = document.createElement('canvas')
  canvas.width = width
  canvas.height = height
  const ctx = canvas.getContext('2d')
  if (!ctx) {
    throw new Error('当前环境无法创建画布进行抽帧。')
  }
  ctx.drawImage(videoEl, 0, 0, width, height)

  let dataUrl = ''
  try {
    dataUrl = canvas.toDataURL('image/png')
  } catch {
    throw new Error('浏览器安全限制阻止读取当前视频帧，请重启或尝试导出视频。')
  }
  if (!dataUrl || !dataUrl.startsWith('data:image/png;base64,')) {
    throw new Error('导出当前视频帧失败。')
  }

  return {
    dataUrl,
    width,
    height,
    timestampSec: Number(videoEl.currentTime) || 0,
  }
}
