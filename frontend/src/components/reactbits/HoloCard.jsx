import { useEffect, useRef } from 'react';
import './HoloCard.css';

const PERSPECTIVE = 1100;
const clamp = (value, min, max) => Math.min(max, Math.max(min, value));

const spring = (value, velocity, target, stiffness, damping, dt) => {
  const nextVelocity = velocity + ((target - value) * stiffness - velocity * damping) * dt;
  return [value + nextVelocity * dt, nextVelocity];
};

export default function HoloCard({
  width = 230,
  aspectRatio = 1,
  radius = 16,
  tiltMax = 15,
  hoverScale = 1.03,
  children = null,
  className = '',
  style,
}) {
  const rootRef = useRef(null);
  const rotorRef = useRef(null);
  const pointerRef = useRef({ x: 0.5, y: 0.5, inside: false });
  const wakeRef = useRef(null);
  const configRef = useRef({ tiltMax, hoverScale });
  configRef.current = { tiltMax, hoverScale };

  useEffect(() => {
    const root = rootRef.current;
    const rotor = rotorRef.current;
    if (!root || !rotor) return undefined;

    const state = {
      tiltX: 0,
      tiltVX: 0,
      tiltY: 0,
      tiltVY: 0,
      lift: 1,
      liftV: 0,
      lx: 0.5,
      lxV: 0,
      ly: 0.5,
      lyV: 0,
    };

    let raf = 0;
    let last = 0;
    let calm = 0;
    let alive = true;

    const tick = now => {
      raf = 0;
      if (!alive) return;
      const dt = Math.min(0.05, Math.max(0.001, (now - last) / 1000));
      last = now;

      const { tiltMax: maxTilt, hoverScale: scaleTarget } = configRef.current;
      const pointer = pointerRef.current;
      const targetX = pointer.inside ? (0.5 - pointer.y) * maxTilt * 2 : 0;
      const targetY = pointer.inside ? (pointer.x - 0.5) * maxTilt * 2 : 0;
      const liftTarget = pointer.inside ? scaleTarget : 1;
      const lxTarget = pointer.inside ? pointer.x : 0.5;
      const lyTarget = pointer.inside ? pointer.y : 0.5;

      const steps = Math.ceil(dt / (1 / 240));
      const h = dt / steps;
      for (let i = 0; i < steps; i++) {
        [state.tiltX, state.tiltVX] = spring(state.tiltX, state.tiltVX, targetX, 160, 18, h);
        [state.tiltY, state.tiltVY] = spring(state.tiltY, state.tiltVY, targetY, 160, 18, h);
        [state.lift, state.liftV] = spring(state.lift, state.liftV, liftTarget, 320, 30, h);
        [state.lx, state.lxV] = spring(state.lx, state.lxV, lxTarget, 220, 30, h);
        [state.ly, state.lyV] = spring(state.ly, state.lyV, lyTarget, 220, 30, h);
      }

      rotor.style.transform =
        `perspective(${PERSPECTIVE}px) scale(${state.lift}) rotateX(${state.tiltX}deg) rotateY(${state.tiltY}deg)`;
      root.style.setProperty('--hc-gx', `${(state.lx * 100).toFixed(1)}%`);
      root.style.setProperty('--hc-gy', `${(state.ly * 100).toFixed(1)}%`);
      root.style.setProperty('--hc-angle', `${(110 + (state.lx - 0.5) * 80).toFixed(1)}deg`);

      const motion =
        Math.abs(state.tiltVX) +
        Math.abs(state.tiltVY) +
        Math.abs(state.liftV) * 40 +
        Math.abs(state.tiltX - targetX) +
        Math.abs(state.tiltY - targetY);
      calm = motion > 0.02 ? 0 : calm + dt;
      if (!pointer.inside && calm > 0.25) {
        rotor.style.transform = '';
        rotor.style.willChange = 'auto';
        return;
      }
      raf = requestAnimationFrame(tick);
    };

    const wake = () => {
      if (raf || !alive) return;
      calm = 0;
      rotor.style.willChange = 'transform';
      last = performance.now();
      raf = requestAnimationFrame(tick);
    };
    wakeRef.current = wake;

    return () => {
      alive = false;
      cancelAnimationFrame(raf);
      wakeRef.current = null;
    };
  }, []);

  const track = e => {
    if (globalThis.matchMedia?.('(prefers-reduced-motion: reduce)').matches) return;
    const rect = e.currentTarget.getBoundingClientRect();
    pointerRef.current = {
      x: clamp((e.clientX - rect.left) / rect.width, 0, 1),
      y: clamp((e.clientY - rect.top) / rect.height, 0, 1),
      inside: true,
    };
    wakeRef.current?.();
  };

  const leave = () => {
    pointerRef.current = { ...pointerRef.current, inside: false };
    wakeRef.current?.();
  };

  return (
    <div
      ref={rootRef}
      className={`holo-card${className ? ` ${className}` : ''}`}
      onPointerEnter={track}
      onPointerMove={track}
      onPointerLeave={leave}
      onPointerCancel={leave}
      style={{
        '--hc-w': `${width}px`,
        '--hc-ratio': aspectRatio,
        '--hc-radius': `${radius}px`,
        ...style,
      }}
    >
      <div ref={rotorRef} className="holo-card__rotor">
        <div className="holo-card__face">
          {children}
          <div className="holo-card__glare" aria-hidden="true" />
        </div>
      </div>
    </div>
  );
}
