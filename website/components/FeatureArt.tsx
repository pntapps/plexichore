import { CloudOff, Laptop, Lock, RotateCw, TabletSmartphone } from "lucide-react";

/* Small animated illustrations for the feature cards. Pure CSS/SVG; keyframes live in globals.css. */

function Panel({ children, className = "" }: { children: React.ReactNode; className?: string }) {
  return (
    <div
      aria-hidden="true"
      className={`relative h-32 overflow-hidden rounded-2xl border border-line bg-[radial-gradient(120%_120%_at_0%_0%,rgb(124_92_255/0.16),transparent_60%),radial-gradient(120%_120%_at_100%_100%,rgb(34_211_238/0.12),transparent_60%)] bg-ink-900/80 ${className}`}
    >
      {children}
    </div>
  );
}

function Device({ icon: Icon, className = "" }: { icon: React.ComponentType<{ className?: string }>; className?: string }) {
  return (
    <span className={`grid size-11 place-items-center rounded-xl border border-white/10 bg-white/5 ${className}`}>
      <Icon className="size-5 text-fg" />
    </span>
  );
}

const BARS = [72, 80, 76, 84, 78, 82, 74, 86, 79, 81, 77, 85, 80, 75, 83, 78, 82, 76, 84, 80, 73, 81, 79, 85];

/** A steady frame-time strip scrolling by: every bar about the same height = smooth 60 fps. */
export function FrameMeterArt() {
  return (
    <Panel>
      <div className="absolute left-4 top-3.5 flex items-center gap-2 text-xs font-medium text-fg">
        <span className="relative flex size-2">
          <span className="absolute inline-flex size-full animate-ping rounded-full bg-mint opacity-60" />
          <span className="relative inline-flex size-2 rounded-full bg-mint" />
        </span>
        60 fps · steady
      </div>
      <div className="absolute right-4 top-3.5 text-xs text-subtle">16.7 ms / frame</div>
      <div className="absolute inset-x-4 bottom-3 top-10 overflow-hidden [mask-image:linear-gradient(90deg,transparent,black_12%,black_88%,transparent)]">
        <div className="absolute inset-x-0 top-[22%] border-t border-dashed border-cyan/30" />
        <div className="flex h-full w-max items-end gap-1.5" style={{ animation: "marquee 7s linear infinite" }}>
          {[...BARS, ...BARS, ...BARS, ...BARS].map((h, i) => (
            <span key={i} className="w-2.5 rounded-t-sm bg-gradient-to-t from-violet/70 to-cyan/90" style={{ height: `${h}%` }} />
          ))}
        </div>
      </div>
    </Panel>
  );
}

/** A finger tap ripples while the S-Pen writes a line. */
export function PenArt() {
  return (
    <Panel>
      <svg viewBox="0 0 240 128" className="absolute inset-0 size-full">
        <rect x="36" y="16" width="168" height="96" rx="12" fill="rgb(255 255 255 / 0.03)" stroke="rgb(255 255 255 / 0.14)" />
        <path
          d="M58 82 C 72 46, 88 44, 98 70 S 120 96, 134 64 S 160 38, 178 66"
          fill="none"
          stroke="url(#pen-grad)"
          strokeWidth="3"
          strokeLinecap="round"
          strokeDasharray="200"
          style={{ ["--len" as string]: 200, animation: "draw-stroke 4.5s ease-in-out infinite" }}
        />
        <circle
          cx="160"
          cy="92"
          r="9"
          fill="none"
          stroke="#67e8f9"
          strokeWidth="1.5"
          style={{ transformBox: "fill-box", transformOrigin: "center", animation: "ripple 2.2s ease-out infinite" }}
        />
        <circle cx="160" cy="92" r="3.5" fill="#67e8f9" />
        <defs>
          <linearGradient id="pen-grad" x1="0" x2="1">
            <stop offset="0" stopColor="#a78bfa" />
            <stop offset="1" stopColor="#22d3ee" />
          </linearGradient>
        </defs>
      </svg>
    </Panel>
  );
}

/** Data dashes flowing along a cable from the computer to the tablet. */
export function UsbArt() {
  return (
    <Panel className="flex items-center justify-between px-6">
      <Device icon={Laptop} />
      <svg viewBox="0 0 120 40" className="mx-2 h-10 flex-1" preserveAspectRatio="none">
        <path d="M2 20 C 40 4, 80 36, 118 20" fill="none" stroke="rgb(255 255 255 / 0.12)" strokeWidth="4" strokeLinecap="round" />
        <path
          d="M2 20 C 40 4, 80 36, 118 20"
          fill="none"
          stroke="url(#usb-grad)"
          strokeWidth="2.5"
          strokeLinecap="round"
          strokeDasharray="5 7"
          style={{ animation: "dash-flow 0.7s linear infinite" }}
        />
        <defs>
          <linearGradient id="usb-grad" x1="0" x2="1">
            <stop offset="0" stopColor="#a78bfa" />
            <stop offset="1" stopColor="#22d3ee" />
          </linearGradient>
        </defs>
      </svg>
      <Device icon={TabletSmartphone} />
      <span className="absolute bottom-3 left-1/2 -translate-x-1/2 rounded-full border border-line bg-ink-950/80 px-2.5 py-0.5 text-[11px] text-subtle">
        USB · ~1 s to connect
      </span>
    </Panel>
  );
}

/** Wi-Fi waves pulse between the devices; the 4-digit pairing code pops up. */
export function WifiArt() {
  return (
    <Panel className="flex items-center justify-between px-6">
      <Device icon={Laptop} />
      <svg viewBox="0 0 60 40" className="h-12 w-16">
        {[16, 11, 6].map((r, i) => (
          <path
            key={r}
            d={`M ${30 - r} ${30 - r * 0.25} A ${r} ${r} 0 0 1 ${30 + r} ${30 - r * 0.25}`}
            fill="none"
            stroke="#67e8f9"
            strokeWidth="2.4"
            strokeLinecap="round"
            style={{ animation: `wave 1.8s ease-in-out ${(2 - i) * 0.25}s infinite` }}
          />
        ))}
        <circle cx="30" cy="31" r="2.6" fill="#67e8f9" />
      </svg>
      <Device icon={TabletSmartphone} />
      <span
        className="absolute left-1/2 top-3 -translate-x-1/2 rounded-lg border border-violet/40 bg-violet/15 px-2.5 py-1 font-display text-sm font-semibold tracking-[0.3em] text-fg"
        style={{ animation: "pop 5s ease-in-out infinite" }}
      >
        4827
      </span>
    </Panel>
  );
}

const KEY_ROWS = [
  ["Esc", "", "", "", "", "", "", "", ""],
  ["Tab", "", "", "", "", "", "", ""],
  ["Ctrl", "", "", "", "", "", ""],
];

/** Keys light up one after another, like typing. */
export function KeyboardArt() {
  let n = 0;
  return (
    <Panel className="flex flex-col items-center justify-center gap-1.5 px-4">
      {KEY_ROWS.map((row, r) => (
        <div key={r} className="flex gap-1.5">
          {row.map((label, k) => {
            const i = n++;
            return (
              <span
                key={k}
                className={`grid h-6 place-items-center rounded-md border border-white/10 bg-white/[0.07] text-[9px] font-medium text-muted ${label ? "w-9" : "w-6"}`}
                style={{ animation: `key-press 4.2s ease-out ${((i * 7) % 24) * 0.17}s infinite` }}
              >
                {label}
              </span>
            );
          })}
        </div>
      ))}
    </Panel>
  );
}

/** The tablet turns to portrait and back. */
export function RotateArt() {
  return (
    <Panel className="grid place-items-center">
      <RotateCw className="absolute right-4 top-3.5 size-4 text-subtle" />
      <div
        className="relative h-[4.2rem] w-28 rounded-xl border-[3px] border-[#2a2660] bg-gradient-to-br from-[#4c3fb8] to-[#13305a] p-2"
        style={{ animation: "rotate-device 6s cubic-bezier(0.6, 0, 0.3, 1) infinite" }}
      >
        <div className="h-1.5 w-[70%] rounded bg-white/50" />
        <div className="mt-1.5 h-1.5 w-[90%] rounded bg-white/25" />
        <div className="mt-1.5 h-1.5 w-[55%] rounded bg-white/25" />
      </div>
    </Panel>
  );
}

/** Straight from device to device: the cloud is crossed out, a lock pulses in the middle. */
export function PrivateArt() {
  return (
    <Panel className="flex items-center justify-between px-6">
      <Device icon={Laptop} />
      <div className="relative mx-3 flex h-full flex-1 items-center justify-center">
        <svg viewBox="0 0 100 10" className="absolute inset-x-0 top-1/2 h-2.5 w-full -translate-y-1/2" preserveAspectRatio="none">
          <line
            x1="0"
            y1="5"
            x2="100"
            y2="5"
            stroke="#34d399"
            strokeWidth="2"
            strokeDasharray="4 5"
            style={{ animation: "dash-flow 0.9s linear infinite" }}
            vectorEffect="non-scaling-stroke"
          />
        </svg>
        <span className="relative grid size-10 place-items-center rounded-full border border-mint/40 bg-ink-950">
          <span className="absolute inset-0 rounded-full border border-mint/50" style={{ animation: "ring-out 2.4s ease-out infinite" }} />
          <Lock className="size-4 text-mint" />
        </span>
        <CloudOff className="absolute left-1/2 top-3 size-5 -translate-x-1/2 text-subtle/80" />
      </div>
      <Device icon={TabletSmartphone} />
    </Panel>
  );
}

const CODE_LINES = [
  { w: "62%", c: "bg-violet-soft/70", indent: 0 },
  { w: "48%", c: "bg-cyan/60", indent: 1 },
  { w: "70%", c: "bg-white/30", indent: 1 },
  { w: "40%", c: "bg-mint/60", indent: 2 },
  { w: "30%", c: "bg-violet-soft/70", indent: 0 },
];

/** Code lines type themselves out in an editor window. */
export function CodeArt() {
  return (
    <Panel className="p-3">
      <div className="h-full rounded-xl border border-white/10 bg-ink-950/80 p-3">
        <div className="mb-2.5 flex gap-1.5">
          <span className="size-2 rounded-full bg-[#f87171]/80" />
          <span className="size-2 rounded-full bg-[#fbbf24]/80" />
          <span className="size-2 rounded-full bg-mint/80" />
          <span className="ml-auto rounded bg-white/5 px-1.5 text-[9px] font-medium text-subtle">GPL-3.0</span>
        </div>
        <div className="space-y-1.5">
          {CODE_LINES.map((l, i) => (
            <div key={i} className="flex items-center" style={{ paddingLeft: `${l.indent * 12}px` }}>
              <span
                className={`block h-1.5 rounded ${l.c}`}
                style={{ width: l.w, ["--w" as string]: l.w, animation: `type-line 6s steps(14) ${i * 0.55}s infinite both` }}
              />
              {i === CODE_LINES.length - 1 && (
                <span className="ml-1 h-2.5 w-0.5 bg-cyan" style={{ animation: "blink 1s steps(1) infinite" }} />
              )}
            </div>
          ))}
        </div>
      </div>
    </Panel>
  );
}
