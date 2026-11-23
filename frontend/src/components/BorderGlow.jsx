import './BorderGlow.css'

export default function BorderGlow({
  children,
  active = false,
  accentColor = 'var(--color-primary)',
  borderRadius = 16,
  mode = 'snake',
  className = '',
}) {
  return (
    <div
      className={`border-glow-card selection-${mode} ${active ? 'is-selected' : ''} ${className}`}
      style={{
        '--border-radius': `${borderRadius}px`,
        '--selection-accent': accentColor,
      }}
    >
      <div className="border-glow-inner">{children}</div>
    </div>
  )
}
