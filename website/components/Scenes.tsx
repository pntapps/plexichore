import Image from "next/image";
import { ArrowDown, Laptop, MousePointer2, Star, TabletSmartphone } from "lucide-react";

/* Animated scenes for the modes, the no-monitor section and the how-it-works steps. Keyframes: globals.css. */

const SCREEN_A = "bg-gradient-to-br from-[#5b47d6] to-[#1d1960]";
const SCREEN_B = "bg-gradient-to-br from-[#1d6f8f] to-[#1a1f5c]";

/**
 * A computer (128×80 screen) and a tablet (96×56) on a fixed 236×96 stage, so the moving parts can use pixel offsets.
 * Extend: a window travels to the tablet. Primary: the taskbar (and the star) move to the tablet. Mirror: the same
 * cursor moves on both screens.
 */
export function ModeArt({ mode }: { mode: "extend" | "primary" | "mirror" }) {
  const mirror = mode === "mirror";
  return (
    <div aria-hidden="true" className="relative grid h-40 place-items-center overflow-hidden rounded-2xl border border-line bg-ink-900/80">
      <div className="pointer-events-none absolute -bottom-16 left-1/2 size-48 -translate-x-1/2 rounded-full bg-violet/20 blur-3xl" />
      <div className="relative h-[96px] w-[236px]">
        {/* computer */}
        <div className="absolute left-0 top-0 flex w-32 flex-col items-center">
          <div className={`relative h-20 w-32 overflow-hidden rounded-md ${SCREEN_A}`}>
            <div className="absolute left-[12%] top-[16%] h-[34%] w-[40%] rounded-sm bg-white/25" />
            {mirror && <div className="absolute left-[50%] top-[40%] h-[34%] w-[38%] rounded-sm bg-white/75" />}
            <div
              className="absolute inset-x-0 bottom-0 h-[16%] bg-black/45"
              style={mode === "primary" ? { animation: "taskbar-out 5s ease-in-out infinite" } : undefined}
            />
            {mirror && (
              <MousePointer2
                className="absolute left-[36px] top-[26px] size-3.5 fill-white text-ink-950"
                style={{ ["--cx" as string]: "40px", ["--cy" as string]: "18px", animation: "sync-cursor 4s ease-in-out infinite" }}
              />
            )}
          </div>
          <div className="h-3 w-1.5 bg-white/20" />
          <div className="h-1 w-12 rounded-full bg-white/20" />
        </div>

        {/* tablet */}
        <div className="absolute bottom-1 right-0 h-14 w-24 overflow-hidden rounded-[10px] border-[3px] border-[#2b2763]">
          <div className={`relative size-full ${mirror ? SCREEN_A : SCREEN_B}`}>
            {mirror ? (
              <>
                <div className="absolute left-[12%] top-[16%] h-[34%] w-[40%] rounded-sm bg-white/25" />
                <div className="absolute left-[50%] top-[40%] h-[34%] w-[38%] rounded-sm bg-white/75" />
                <MousePointer2
                  className="absolute left-[25px] top-[18px] size-2.5 fill-white text-ink-950"
                  style={{ ["--cx" as string]: "28px", ["--cy" as string]: "12px", animation: "sync-cursor 4s ease-in-out infinite" }}
                />
              </>
            ) : (
              <div className="absolute right-[14%] top-[18%] h-[34%] w-[44%] rounded-sm bg-white/20" />
            )}
            {mode === "primary" && (
              <div className="absolute inset-x-0 bottom-0 h-[18%] bg-black/50" style={{ animation: "taskbar-in 5s ease-in-out infinite" }} />
            )}
          </div>
        </div>

        {mode === "extend" && (
          <div
            className="absolute left-[16px] top-[14px] z-10 h-[26px] w-[44px] overflow-hidden rounded-[3px] bg-[#f4f2ff] shadow-lg shadow-black/50"
            style={{ ["--mx" as string]: "150px", ["--my" as string]: "37px", animation: "mode-extend 5s ease-in-out infinite" }}
          >
            <div className="h-[5px] bg-gradient-to-r from-[#7c5cff] to-[#22d3ee]" />
            <div className="mx-1 mt-1 h-[3px] w-[70%] rounded bg-[#c9c3f5]" />
            <div className="mx-1 mt-1 h-[3px] w-[50%] rounded bg-[#e2def9]" />
          </div>
        )}
        {mode === "primary" && (
          <Star
            className="absolute -top-1 right-1 size-5 fill-amber-300 text-amber-300 drop-shadow-[0_0_8px_rgb(252_211_77/0.7)]"
            style={{ animation: "taskbar-in 5s ease-in-out infinite" }}
          />
        )}
      </div>
    </div>
  );
}

/** The monitor's cable is pulled, its screen goes dark and the tablet takes over as the main display — then back. */
export function NoMonitorScene() {
  const cycle = "9s ease-in-out infinite";
  return (
    <div aria-hidden="true" className="relative mx-auto h-64 w-full max-w-[440px]">
      {/* mini PC */}
      <div className="absolute bottom-3 left-[6%] flex h-8 w-[150px] items-center justify-between rounded-lg border border-white/10 bg-gradient-to-b from-[#2a2660] to-[#17153d] px-3">
        <span className="size-1.5 rounded-full bg-mint shadow-[0_0_8px_#34d399]" />
        <span className="text-[9px] font-medium tracking-wider text-subtle">PC</span>
      </div>
      {/* port on the PC */}
      <div className="absolute bottom-11 left-[calc(6%+115px)] z-0 h-1.5 w-3.5 rounded-sm bg-black/70" />

      {/* cable + plug (moves up = unplugged) */}
      <div
        className="absolute left-[calc(6%+116px)] top-[92px] z-0 flex flex-col items-center"
        style={{ ["--plug-y" as string]: "-22px", animation: `plug ${cycle}` }}
      >
        <div className="h-[102px] w-1 rounded-full bg-gradient-to-b from-white/10 to-white/35" />
        <div className="h-3.5 w-3 rounded-sm bg-[#8b87b8]" />
      </div>

      {/* monitor */}
      <div className="absolute left-[6%] top-2 z-10 flex w-[150px] flex-col items-center">
        <div className="relative h-24 w-[150px] overflow-hidden rounded-lg border-[3px] border-[#2b2763] bg-black">
          <div className={`absolute inset-0 ${SCREEN_A}`} style={{ animation: `screen-off ${cycle}` }}>
            <div className="absolute left-[10%] top-[14%] h-[36%] w-[42%] rounded-sm bg-white/25" />
            <div className="absolute inset-x-0 bottom-0 h-[15%] bg-black/45" />
          </div>
          <span
            className="absolute inset-0 grid place-items-center text-[10px] font-medium tracking-wider text-subtle"
            style={{ animation: `main-on ${cycle}` }}
          >
            NO SIGNAL
          </span>
        </div>
        <div className="h-4 w-2 bg-white/15" />
        <div className="h-1.5 w-14 rounded-full bg-white/15" />
      </div>

      {/* tablet */}
      <div
        className="absolute right-[4%] top-16 z-10 h-[110px] w-[176px] overflow-hidden rounded-2xl border-[4px] border-[#2b2763]"
        style={{ animation: `tablet-glow ${cycle}` }}
      >
        <div className={`relative size-full ${SCREEN_B}`}>
          <div className="absolute right-[12%] top-[16%] h-[34%] w-[44%] rounded-sm bg-white/20" />
          <div className="absolute inset-x-0 bottom-0 h-[15%] bg-black/50" style={{ animation: `main-on ${cycle}` }} />
          <span
            className="absolute left-2 top-2 flex items-center gap-1 rounded-full bg-black/40 px-2 py-0.5 text-[10px] font-semibold text-white backdrop-blur"
            style={{ animation: `main-on ${cycle}` }}
          >
            <Star className="size-3 fill-amber-300 text-amber-300" /> Main display
          </span>
        </div>
      </div>
    </div>
  );
}

function Box({ children }: { children: React.ReactNode }) {
  return (
    <div aria-hidden="true" className="relative grid h-28 place-items-center overflow-hidden rounded-2xl border border-line bg-ink-900/80">
      <div className="pointer-events-none absolute -bottom-12 left-1/2 size-36 -translate-x-1/2 rounded-full bg-violet/20 blur-3xl" />
      {children}
    </div>
  );
}

/** Illustrations for the three setup steps. */
export function StepArt({ step }: { step: 1 | 2 | 3 }) {
  if (step === 1)
    return (
      <Box>
        <div className="relative">
          <ArrowDown className="absolute -top-7 left-1/2 size-5 -translate-x-1/2 text-cyan" style={{ animation: "bounce-soft 1.6s ease-in-out infinite" }} />
          <Laptop className="size-12 text-fg" strokeWidth={1.4} />
        </div>
      </Box>
    );
  if (step === 2)
    return (
      <Box>
        <div className="relative">
          <TabletSmartphone className="size-12 text-fg" strokeWidth={1.4} />
          <Image
            src="/logo.png"
            alt=""
            width={22}
            height={22}
            className="absolute -right-3 -top-3 rounded-md shadow-lg shadow-violet/40"
            style={{ animation: "pop 4s ease-in-out infinite both" }}
          />
        </div>
      </Box>
    );
  return (
    <Box>
      <div className="flex items-center gap-2">
        <Laptop className="size-9 text-fg" strokeWidth={1.4} />
        <svg viewBox="0 0 60 10" className="h-3 w-16">
          <line x1="2" y1="5" x2="58" y2="5" stroke="#67e8f9" strokeWidth="2" strokeLinecap="round" strokeDasharray="4 5" style={{ animation: "dash-flow 0.7s linear infinite" }} />
        </svg>
        <TabletSmartphone className="size-9 text-fg" strokeWidth={1.4} />
      </div>
    </Box>
  );
}
