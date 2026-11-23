import { useCallback, useEffect, useRef } from 'react'

export const SPARK_EVENT = 'wallpapervault:spark'

export default function ClickSpark({
  sparkColor = '#7c3aed',
  sizePercent = 100,
  sparkCount = 8,
  duration = 520,
  children,
}) {
  const canvasRef = useRef(null)
  const sparksRef = useRef([])
  const animationRef = useRef(0)
  const scale = Math.max(0, Number(sizePercent) || 0) / 100
  const effectiveDuration = duration * Math.max(1, Math.min(5, Math.sqrt(scale)))

  const resizeCanvas = useCallback(() => {
    const canvas = canvasRef.current
    if (!canvas) return
    const ratio = Math.min(globalThis.devicePixelRatio || 1, 2)
    canvas.width = Math.max(1, Math.round(globalThis.innerWidth * ratio))
    canvas.height = Math.max(1, Math.round(globalThis.innerHeight * ratio))
    canvas.style.width = `${globalThis.innerWidth}px`
    canvas.style.height = `${globalThis.innerHeight}px`
    const context = canvas.getContext('2d')
    context.setTransform(ratio, 0, 0, ratio, 0, 0)
  }, [])

  const draw = useCallback(timestamp => {
    const canvas = canvasRef.current
    const context = canvas?.getContext('2d')
    if (!canvas || !context) {
      animationRef.current = 0
      return
    }

    context.clearRect(0, 0, globalThis.innerWidth, globalThis.innerHeight)
    sparksRef.current = sparksRef.current.filter(spark => {
      const elapsed = timestamp - spark.startTime
      if (elapsed >= effectiveDuration) return false

      const progress = elapsed / effectiveDuration
      const eased = progress * (2 - progress)
      const distance = eased * 46 * scale
      const lineLength = Math.max(1, 12 * scale * (1 - eased))
      const x1 = spark.x + distance * Math.cos(spark.angle)
      const y1 = spark.y + distance * Math.sin(spark.angle)
      const x2 = spark.x + (distance + lineLength) * Math.cos(spark.angle)
      const y2 = spark.y + (distance + lineLength) * Math.sin(spark.angle)

      context.globalAlpha = 1 - progress
      context.strokeStyle = sparkColor
      context.lineWidth = Math.max(1.5, Math.min(120, 2 * Math.pow(scale, 0.75)))
      context.lineCap = 'round'
      context.beginPath()
      context.moveTo(x1, y1)
      context.lineTo(x2, y2)
      context.stroke()
      return true
    })
    context.globalAlpha = 1

    if (sparksRef.current.length > 0) {
      animationRef.current = requestAnimationFrame(draw)
    } else {
      animationRef.current = 0
    }
  }, [effectiveDuration, scale, sparkColor])

  const emit = useCallback((x, y) => {
    if (scale <= 0) return
    if (globalThis.matchMedia?.('(prefers-reduced-motion: reduce)').matches) return
    const now = performance.now()
    const burst = Array.from({ length: sparkCount }, (_, index) => ({
      x,
      y,
      angle: (Math.PI * 2 * index) / sparkCount,
      startTime: now,
    }))
    sparksRef.current.push(...burst)
    if (!animationRef.current) {
      animationRef.current = requestAnimationFrame(draw)
    }
  }, [draw, scale, sparkCount])

  useEffect(() => {
    resizeCanvas()
    globalThis.addEventListener('resize', resizeCanvas)
    return () => globalThis.removeEventListener('resize', resizeCanvas)
  }, [resizeCanvas])

  useEffect(() => {
    const handleExternalSpark = event => {
      emit(event.detail?.x ?? 0, event.detail?.y ?? 0)
    }
    globalThis.addEventListener(SPARK_EVENT, handleExternalSpark)
    return () => globalThis.removeEventListener(SPARK_EVENT, handleExternalSpark)
  }, [emit])

  useEffect(() => () => {
    if (animationRef.current) {
      cancelAnimationFrame(animationRef.current)
      animationRef.current = 0
    }
  }, [])

  const handleClick = event => {
    if (event.target.closest('[data-spark="off"]')) return
    emit(event.clientX, event.clientY)
  }

  return (
    <div className="spark-root" onClickCapture={handleClick}>
      <canvas ref={canvasRef} className="spark-canvas" aria-hidden="true" />
      {children}
    </div>
  )
}
