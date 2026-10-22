import { MousePointer2, PenLine, Zap } from "lucide-react";

/** Decorative hero art: a laptop whose desktop continues onto a tablet; a window glides across. Pure CSS. */
export function HeroVisual() {
  return (
    <div className="relative mx-auto aspect-[14/10] w-full max-w-[600px] select-none" aria-hidden="true">
      {/* glows */}
      <div className="animate-glow absolute left-[8%] top-[10%] size-[55%] rounded-full bg-violet/30 blur-[90px]" />
      <div className="animate-glow absolute bottom-[0%] right-[0%] size-[45%] rounded-full bg-cyan/25 blur-[90px] [animation-delay:-4s]" />

      {/* link between the devices */}
      <svg className="absolute inset-0 size-full" viewBox="0 0 140 100" preserveAspectRatio="none">
        <path
          d="M 62 70 C 70 84, 74 86, 82 84"
          fill="none"
          stroke="url(#plexi-link)"
          strokeWidth="0.6"
          strokeDasharray="2 2"
          className="animate-pulse-line"
          vectorEffect="non-scaling-stroke"
        />
        <defs>
          <linearGradient id="plexi-link" x1="0" x2="1">
            <stop offset="0" stopColor="#a78bfa" />
            <stop offset="1" stopColor="#22d3ee" />
          </linearGradient>
        </defs>
      </svg>

      {/* laptop */}
      <div className="absolute left-0 top-[6%] w-[70%]">
        <div className="aspect-[16/10] rounded-t-[14px] border border-white/15 bg-[#14123a] p-[2.2%] shadow-2xl shadow-black/50">
          <Desktop variant="laptop" />
        </div>
        <div className="relative -mx-[6%] h-3 rounded-b-[14px] bg-gradient-to-b from-[#34307a] to-[#17153d] shadow-xl shadow-black/40">
          <div className="absolute left-1/2 top-0 h-1 w-[16%] -translate-x-1/2 rounded-b-md bg-black/30" />
        </div>
      </div>

      {/* tablet */}
      <div className="animate-float-soft absolute bottom-[4%] right-0 w-[46%]">
        <div className="aspect-[16/10] rounded-[18px] border border-white/20 bg-[#0d0c26] p-[3.2%] shadow-[0_30px_80px_-20px_rgb(34_211_238/0.45)]">
          <div className="relative h-full">
            <Desktop variant="tablet" />
            {/* the S-Pen writes, a finger taps */}
            <svg viewBox="0 0 160 100" className="absolute inset-0 size-full">
              <path
                d="M86 70 C 94 52, 102 50, 108 62 S 120 76, 128 60 S 142 46, 148 58"
                fill="none"
                stroke="#67e8f9"
                strokeWidth="2.2"
                strokeLinecap="round"
                strokeDasharray="110"
                style={{ ["--len" as string]: 110, animation: "draw-stroke 5s ease-in-out 1s infinite both" }}
              />
              <circle
                cx="40"
                cy="62"
                r="7"
                fill="none"
                stroke="#c4b5fd"
                strokeWidth="1.4"
                style={{ transformBox: "fill-box", transformOrigin: "center", animation: "ripple 2.6s ease-out infinite" }}
              />
              <circle cx="40" cy="62" r="2.6" fill="#c4b5fd" />
            </svg>
          </div>
        </div>
      </div>

      {/* the window being dragged across, with the cursor holding its title bar */}
      <div className="animate-window-glide absolute left-[12%] top-[18%] z-10 w-[24%] [--glide-x:220%] [--glide-y:200%]">
        <div className="aspect-[16/11] overflow-hidden rounded-lg border border-white/25 bg-[#f4f2ff] shadow-2xl shadow-black/60">
          <div className="flex h-[16%] items-center gap-[4%] bg-gradient-to-r from-[#7c5cff] to-[#22d3ee] px-[5%]">
            <span className="size-[5%] min-h-1 min-w-1 rounded-full bg-white/80" />
            <span className="size-[5%] min-h-1 min-w-1 rounded-full bg-white/60" />
            <span className="size-[5%] min-h-1 min-w-1 rounded-full bg-white/40" />
          </div>
          <div className="space-y-[6%] p-[7%]">
            <div className="h-1.5 w-[70%] rounded bg-[#c9c3f5]" />
            <div className="h-1.5 w-[90%] rounded bg-[#e2def9]" />
            <div className="flex h-[38%] items-end gap-[6%] pt-[4%]">
              {[45, 70, 55, 90, 65].map((h, i) => (
                <div key={i} className="flex-1 rounded-sm bg-gradient-to-t from-[#7c5cff] to-[#22d3ee]" style={{ height: `${h}%` }} />
              ))}
            </div>
          </div>
        </div>
        <MousePointer2 className="absolute left-[38%] top-[2%] size-5 fill-white text-ink-950 drop-shadow-lg" />
      </div>

      {/* drifting particles */}
      {[
        { l: "18%", b: "8%", d: "0s", c: "bg-violet-soft" },
        { l: "48%", b: "2%", d: "1.6s", c: "bg-cyan" },
        { l: "66%", b: "40%", d: "3.1s", c: "bg-violet-soft" },
        { l: "88%", b: "50%", d: "0.8s", c: "bg-cyan-soft" },
        { l: "34%", b: "30%", d: "2.4s", c: "bg-cyan" },
        { l: "8%", b: "46%", d: "4s", c: "bg-violet-soft" },
      ].map((p, i) => (
        <span
          key={i}
          className={`absolute size-1.5 rounded-full ${p.c}`}
          style={{ left: p.l, bottom: p.b, animation: `particle 5.5s ease-out ${p.d} infinite both` }}
        />
      ))}

      {/* floating chips */}
      <div className="glass animate-float-soft absolute right-[4%] top-[2%] flex items-center gap-2 rounded-full px-3 py-1.5 text-xs font-medium [animation-delay:-2s]">
        <Zap className="size-3.5 text-cyan" /> 60 fps · hardware H.264
      </div>
      <div className="glass animate-float-soft absolute bottom-[10%] left-[3%] flex items-center gap-2 rounded-full px-3 py-1.5 text-xs font-medium [animation-delay:-3.5s]">
        <PenLine className="size-3.5 text-violet-soft" /> Touch &amp; S-Pen
      </div>
    </div>
  );
}

function Desktop({ variant }: { variant: "laptop" | "tablet" }) {
  const laptop = variant === "laptop";
  return (
    <div
      className={`relative h-full overflow-hidden rounded-[8px] ${
        laptop
          ? "bg-[radial-gradient(120%_90%_at_10%_0%,#4c3fb8_0%,#211c63_45%,#120f36_100%)]"
          : "bg-[radial-gradient(120%_90%_at_90%_10%,#1d6f8f_0%,#1a2a6b_45%,#100e33_100%)]"
      }`}
    >
      {laptop ? (
        <>
          <div className="absolute right-[8%] top-[12%] h-[44%] w-[34%] rounded-md border border-white/15 bg-white/10 backdrop-blur" />
          <div className="absolute right-[14%] top-[22%] h-[44%] w-[30%] rounded-md border border-white/20 bg-white/[0.14]" />
          <div className="absolute left-[5%] top-[8%] space-y-[22%]">
            {["#8b5cf6", "#22d3ee", "#fbbf24"].map((c) => (
              <span key={c} className="block size-2 rounded-[3px]" style={{ background: c }} />
            ))}
          </div>
        </>
      ) : (
        <>
          <div className="absolute left-[8%] top-[12%] h-[34%] w-[40%] rounded-md border border-white/15 bg-white/10" />
          <div className="absolute bottom-[22%] right-[8%] h-[30%] w-[36%] rounded-md border border-white/15 bg-white/[0.07]" />
        </>
      )}
      {/* taskbar */}
      <div className="absolute inset-x-0 bottom-0 flex h-[11%] items-center justify-center gap-[2%] bg-black/35 backdrop-blur">
        {(laptop ? [0, 1, 2, 3, 4] : [0, 1, 2]).map((i) => (
          <span key={i} className={`h-[45%] rounded-[3px] ${i === 0 ? "aspect-square bg-cyan/80" : "aspect-square bg-white/35"}`} />
        ))}
      </div>
    </div>
  );
}
