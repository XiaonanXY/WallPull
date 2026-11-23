import { useRef } from 'react'

export default function Magnet({
  children,
  disabled = false,
  magnetStrength = 7,
  activeTransition = 'transform 180ms cubic-bezier(0.22, 1, 0.36, 1)',
  inactiveTransition = 'transform 420ms cubic-bezier(0.22, 1, 0.36, 1)',
  wrapperClassName = '',
  innerClassName = '',
  ...props
}) {
  const wrapperRef = useRef(null)
  const innerRef = useRef(null)

  const reset = () => {
    if (!innerRef.current) return
    innerRef.current.style.transition = inactiveTransition
    innerRef.current.style.transform = 'translate(0px, 0px)'
  }

  const move = event => {
    if (disabled || !wrapperRef.current || !innerRef.current) return
    if (globalThis.matchMedia?.('(prefers-reduced-motion: reduce)').matches) return
    const rect = wrapperRef.current.getBoundingClientRect()
    const offsetX = (event.clientX - (rect.left + rect.width / 2)) / magnetStrength
    const offsetY = (event.clientY - (rect.top + rect.height / 2)) / magnetStrength
    innerRef.current.style.transition = activeTransition
    innerRef.current.style.transform = `translate(${offsetX}px, ${offsetY}px)`
  }

  return (
    <div
      ref={wrapperRef}
      className={wrapperClassName}
      onPointerMove={move}
      onPointerLeave={reset}
      style={{ position: 'relative', display: 'inline-block' }}
      {...props}
    >
      <div ref={innerRef} className={innerClassName}>{children}</div>
    </div>
  )
}
