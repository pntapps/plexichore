import { ArrowRight, ChevronDown, Code2, Gauge, MonitorSmartphone, MonitorX, ScanLine, ShieldCheck } from "lucide-react";
import { GitHubIcon } from "@/components/BrandIcons";
import {
  CodeArt,
  FrameMeterArt,
  KeyboardArt,
  PenArt,
  PrivateArt,
  RotateArt,
  UsbArt,
  WifiArt,
} from "@/components/FeatureArt";
import { HeroVisual } from "@/components/HeroVisual";
import { CountUp, Reveal } from "@/components/Reveal";
import { ModeArt, NoMonitorScene, StepArt } from "@/components/Scenes";
import { DownloadCards, SmartDownload } from "@/components/SmartDownload";
import { getDownloads } from "@/lib/releases";
import { site } from "@/lib/site";

// Re-read the GitHub releases at most every 10 minutes (keep in sync with REVALIDATE_SECONDS).
export const revalidate = 600;

export default async function HomePage() {
  const downloads = await getDownloads();
  const softwareJsonLd = {
    "@context": "https://schema.org",
    "@type": "SoftwareApplication",
    name: "PlexiChore",
    applicationCategory: "UtilitiesApplication",
    operatingSystem: "Windows 10, Windows 11, macOS 13+, Android 8+",
    description: site.description,
    offers: { "@type": "Offer", price: "0", priceCurrency: "USD" },
    softwareVersion: downloads.windows?.version ?? downloads.mac?.version,
    license: "https://www.gnu.org/licenses/gpl-3.0.html",
    publisher: { "@type": "Organization", name: site.company.name, url: site.company.url },
  };

  return (
    <>
      <script type="application/ld+json" dangerouslySetInnerHTML={{ __html: JSON.stringify(softwareJsonLd) }} />

      {/* ------------------------------------------------------------------ Hero */}
      <section className="relative overflow-hidden pt-28 sm:pt-32">
        <div className="grid-dots pointer-events-none absolute inset-0" />
        <div className="pointer-events-none absolute -top-40 left-1/2 h-[520px] w-[900px] -translate-x-1/2 rounded-full bg-violet/20 blur-[140px]" />

        <div className="relative mx-auto grid max-w-6xl items-center gap-14 px-4 pb-20 sm:px-6 lg:grid-cols-[1.05fr_1fr] lg:pb-28">
          <div>
            <Reveal>
              <a
                href="#no-monitor"
                className="glass inline-flex items-center gap-2 rounded-full py-1 pl-1 pr-3 text-xs text-muted transition-colors hover:text-fg"
              >
                <span className="bg-brand rounded-full px-2 py-0.5 font-semibold text-white">New</span>
                Windows app · works even with no monitor
                <ArrowRight className="size-3.5" aria-hidden="true" />
              </a>
            </Reveal>

            <Reveal delay={80}>
              <h1 className="mt-6 font-display text-[2.6rem] font-semibold leading-[1.05] tracking-tight sm:text-6xl lg:text-[4.1rem]">
                Your tablet,
                <br />
                <span className="text-gradient">your next screen.</span>
              </h1>
            </Reveal>
            <Reveal delay={160}>
              <p className="mt-6 max-w-xl text-lg leading-relaxed text-muted">
                PlexiChore turns your Android tablet into a portable, touch-enabled monitor for your Windows PC or Mac.
                Extend your desktop, make the tablet your main display, or mirror your screen — over USB or Wi-Fi.
              </p>
            </Reveal>

            <Reveal delay={240} className="mt-9">
              <SmartDownload downloads={downloads} />
            </Reveal>

            <Reveal delay={320}>
              <ul className="mt-9 flex flex-wrap gap-x-6 gap-y-2 text-sm text-subtle">
                <li className="flex items-center gap-2">
                  <Code2 className="size-4 text-violet-soft" aria-hidden="true" /> Free &amp; open source
                </li>
                <li className="flex items-center gap-2">
                  <ShieldCheck className="size-4 text-mint" aria-hidden="true" /> No account, no cloud
                </li>
                <li className="flex items-center gap-2">
                  <Gauge className="size-4 text-cyan" aria-hidden="true" /> Up to 60 fps
                </li>
              </ul>
            </Reveal>
          </div>

          <Reveal delay={200}>
            <HeroVisual />
          </Reveal>
        </div>
      </section>

      {/* ------------------------------------------------------------------ Stats strip */}
      <section className="border-y border-line bg-ink-900/60">
        <dl className="mx-auto grid max-w-6xl grid-cols-2 gap-y-6 px-4 py-8 sm:px-6 md:grid-cols-4">
          {[
            { k: <CountUp to={60} suffix=" fps" />, v: "Hardware H.264 video" },
            { k: "2560×1600", v: "Full tablet resolution" },
            { k: "USB or Wi-Fi", v: "Cable for lowest delay" },
            { k: <CountUp to={3} suffix=" modes" duration={900} />, v: "Extend · Primary · Mirror" },
          ].map((s, i) => (
            <Reveal key={s.v} delay={i * 90} className="text-center">
              <dt className="font-display text-2xl font-semibold text-fg sm:text-3xl">{s.k}</dt>
              <dd className="mt-1 text-sm text-subtle">{s.v}</dd>
            </Reveal>
          ))}
        </dl>
      </section>

      {/* ------------------------------------------------------------------ Modes */}
      <section id="modes" className="mx-auto max-w-6xl px-4 py-24 sm:px-6">
        <SectionTitle
          eyebrow="Three ways to use it"
          title="One tablet. Whatever screen you need."
          text="Pick a mode on the tablet and tap Connect. Switch any time."
        />
        <div className="mt-14 grid gap-5 md:grid-cols-3">
          {(
            [
              {
                mode: "extend",
                title: "Extend",
                text: "The tablet becomes an extra monitor beside your screen. Drag windows across, keep notes or chat on the side.",
              },
              {
                mode: "primary",
                title: "Primary",
                text: "The tablet becomes your main display, with the taskbar or menu bar. Your original layout comes back when you disconnect.",
              },
              {
                mode: "mirror",
                title: "Mirror",
                text: "The tablet shows the same picture as your screen. Great for presenting or sketching over what you see.",
              },
            ] as const
          ).map((m, i) => (
            <Reveal key={m.mode} delay={i * 120} className="glass card-hover rounded-3xl p-6">
              <ModeArt mode={m.mode} />
              <h3 className="mt-6 font-display text-xl font-semibold">{m.title}</h3>
              <p className="mt-2 leading-relaxed text-muted">{m.text}</p>
            </Reveal>
          ))}
        </div>
      </section>

      {/* ------------------------------------------------------------------ Features */}
      <section id="features" className="relative border-t border-line bg-ink-900/40 py-24">
        <div className="mx-auto max-w-6xl px-4 sm:px-6">
          <SectionTitle
            eyebrow="Features"
            title="Feels like a real monitor"
            text="Built for low delay and sharp text, with touch and pen sent straight back to your computer."
          />
          <div className="mt-14 grid gap-5 sm:grid-cols-2 lg:grid-cols-3">
            {features.map((f, i) => (
              <Reveal key={f.title} delay={(i % 3) * 110} className={`glass card-hover rounded-3xl p-5 ${f.wide ? "lg:col-span-2" : ""}`}>
                <f.Art />
                <h3 className="mt-5 px-1 font-display text-lg font-semibold">{f.title}</h3>
                <p className="mt-2 px-1 leading-relaxed text-muted">{f.text}</p>
              </Reveal>
            ))}
          </div>
        </div>
      </section>

      {/* ------------------------------------------------------------------ No-monitor spotlight */}
      <section id="no-monitor" className="mx-auto max-w-6xl px-4 py-24 sm:px-6">
        <Reveal className="glass relative overflow-hidden rounded-[2rem] p-8 sm:p-12">
          <div className="pointer-events-none absolute -right-24 -top-24 size-80 rounded-full bg-cyan/20 blur-[100px]" />
          <div className="relative grid items-center gap-10 lg:grid-cols-[1.1fr_1fr]">
            <div>
              <span className="eyebrow">New on Windows</span>
              <h2 className="mt-3 text-balance font-display text-3xl font-semibold tracking-tight sm:text-4xl">
                No monitor? Your tablet <span className="text-gradient">is</span> the monitor.
              </h2>
              <p className="mt-4 text-lg leading-relaxed text-muted">
                Running a PC without a screen — a home server, a mini PC, a desktop with a broken monitor? Connect your
                tablet and PlexiChore makes it the main display automatically. Plug a monitor back in and everything
                returns to normal on its own.
              </p>
              <div className="mt-8 grid gap-3 sm:grid-cols-2">
                {[
                  { icon: MonitorX, t: "No monitor attached", d: "Tablet connects as the main screen" },
                  { icon: MonitorSmartphone, t: "Monitor plugged in", d: "It becomes the main screen again" },
                ].map(({ icon: Icon, t, d }) => (
                  <div key={t} className="flex items-start gap-3 rounded-2xl border border-line bg-ink-900/70 p-4">
                    <Icon className="mt-0.5 size-5 shrink-0 text-cyan" aria-hidden="true" />
                    <div>
                      <p className="font-medium text-fg">{t}</p>
                      <p className="mt-0.5 text-sm text-subtle">{d}</p>
                    </div>
                  </div>
                ))}
              </div>
            </div>
            <NoMonitorScene />
          </div>
        </Reveal>
      </section>

      {/* ------------------------------------------------------------------ How it works */}
      <section id="how-it-works" className="border-t border-line bg-ink-900/40 py-24">
        <div className="mx-auto max-w-6xl px-4 sm:px-6">
          <SectionTitle eyebrow="How it works" title="Up and running in three steps" />
          <ol className="mt-14 grid gap-5 md:grid-cols-3">
            {(
              [
                {
                  t: "Install on your computer",
                  d: "Download PlexiChore for Windows or Mac. On Windows, one click installs the virtual display for Extend and Primary.",
                },
                {
                  t: "Install on your tablet",
                  d: "Download the Android app (APK) on your tablet and open it. A short intro walks you through setup.",
                },
                {
                  t: "Connect",
                  d: "Plug in a USB cable or use the same Wi-Fi. Pick Extend, Primary or Mirror and tap Connect.",
                },
              ] as const
            ).map((s, i) => (
              <Reveal as="li" key={s.t} delay={i * 140} className="glass card-hover relative rounded-3xl p-5">
                <StepArt step={(i + 1) as 1 | 2 | 3} />
                <div className="mt-5 flex items-center gap-3 px-1">
                  <span className="bg-brand grid size-8 shrink-0 place-items-center rounded-lg font-display font-semibold text-white">
                    {i + 1}
                  </span>
                  <h3 className="font-display text-xl font-semibold">{s.t}</h3>
                </div>
                <p className="mt-3 px-1 leading-relaxed text-muted">{s.d}</p>
                {i < 2 && (
                  <span
                    aria-hidden="true"
                    className="absolute -right-[22px] top-[4.5rem] z-10 hidden size-9 place-items-center rounded-full border border-line bg-ink-950 md:grid"
                  >
                    <ArrowRight className="size-4 text-cyan" />
                  </span>
                )}
              </Reveal>
            ))}
          </ol>
        </div>
      </section>

      {/* ------------------------------------------------------------------ Download */}
      <section id="download" className="relative mx-auto max-w-6xl px-4 py-24 sm:px-6">
        <SectionTitle
          eyebrow="Download"
          title="Get PlexiChore — free"
          text="Install it on your computer and on your tablet. Always the latest version."
        />
        <Reveal className="mt-14">
          <DownloadCards downloads={downloads} />
        </Reveal>
      </section>

      {/* ------------------------------------------------------------------ FAQ */}
      <section id="faq" className="border-t border-line bg-ink-900/40 py-24">
        <div className="mx-auto max-w-3xl px-4 sm:px-6">
          <SectionTitle eyebrow="FAQ" title="Questions, answered" />
          <div className="mt-12 space-y-3">
            {faqs.map((f, i) => (
              <Reveal key={f.q} delay={i * 50}>
                <details className="glass group rounded-2xl px-6 py-5 open:bg-white/[0.05]">
                  <summary className="flex cursor-pointer list-none items-center justify-between gap-4 font-medium text-fg [&::-webkit-details-marker]:hidden">
                    {f.q}
                    <ChevronDown className="size-5 shrink-0 text-subtle transition-transform group-open:rotate-180" aria-hidden="true" />
                  </summary>
                  <p className="mt-3 leading-relaxed text-muted">{f.a}</p>
                </details>
              </Reveal>
            ))}
          </div>
        </div>
      </section>

      {/* ------------------------------------------------------------------ Final CTA */}
      <section className="mx-auto max-w-6xl px-4 py-24 sm:px-6">
        <Reveal className="relative overflow-hidden rounded-[2rem] border border-white/10 bg-[radial-gradient(120%_120%_at_0%_0%,#3b2aa8_0%,#1a1660_45%,#0b2a4a_100%)] px-6 py-16 text-center sm:px-12">
          <div className="grid-dots pointer-events-none absolute inset-0 opacity-60" />
          {/* slowly turning rings behind the icon */}
          <div aria-hidden="true" className="pointer-events-none absolute left-1/2 top-[4.5rem] -translate-x-1/2 -translate-y-1/2">
            <div className="size-28 animate-spin rounded-full border border-dashed border-cyan/30 [animation-duration:22s]" />
            <div className="absolute inset-[-28px] animate-spin rounded-full border border-dashed border-violet-soft/25 [animation-direction:reverse] [animation-duration:34s]" />
          </div>
          <ScanLine className="relative mx-auto size-10 text-cyan-soft" aria-hidden="true" />
          <h2 className="relative mt-8 text-balance font-display text-3xl font-semibold tracking-tight sm:text-5xl">
            Give your tablet a second job.
          </h2>
          <p className="relative mx-auto mt-4 max-w-xl text-lg text-white/75">
            Free, private and open source. Download PlexiChore and turn the tablet you already own into a monitor.
          </p>
          <div className="relative mt-9 flex flex-wrap items-center justify-center gap-3">
            <a href="#download" className="btn-primary">
              Download PlexiChore <ArrowRight className="size-4" aria-hidden="true" />
            </a>
            <a href={site.github} className="btn-ghost">
              <GitHubIcon className="size-4" /> View on GitHub
            </a>
          </div>
        </Reveal>
      </section>
    </>
  );
}

const features = [
  {
    Art: FrameMeterArt,
    title: "Smooth and sharp",
    wide: true,
    text: "Hardware H.264 at up to 60 fps and the tablet's full resolution. Text is scaled automatically so it looks the same size as on the tablet itself, with − / + to adjust it live.",
  },
  { Art: PenArt, title: "Touch & S-Pen", text: "Tap, drag and scroll on the tablet to control your computer. Draw with the S-Pen." },
  { Art: UsbArt, title: "USB for the lowest delay", text: "Plug in a cable and connect in about a second. The computer app sets everything up for you." },
  { Art: WifiArt, title: "Or go wireless", text: "Same Wi-Fi network, approve a 4-digit code the first time, and you're connected." },
  { Art: KeyboardArt, title: "On-screen keyboard", text: "Type on the tablet with Esc, Tab, Ctrl, arrows and shortcuts — or use a keyboard connected to it." },
  { Art: RotateArt, title: "Portrait or landscape", text: "Rotate the tablet and your computer gets a real portrait monitor — perfect for code and documents." },
  { Art: PrivateArt, title: "Private by design", text: "No account, no ads, no analytics. The picture goes directly between your devices, never through a server." },
  { Art: CodeArt, title: "Free & open source", text: "Every line is on GitHub under the GPL-3.0 license. Read it, build it, improve it." },
];

const faqs = [
  {
    q: "Is PlexiChore really free?",
    a: "Yes. PlexiChore is free and open source under the GNU GPL v3.0. There are no ads, subscriptions or accounts.",
  },
  {
    q: "What do I need?",
    a: "An Android tablet with Android 8 or newer, and a Windows 10/11 (64-bit) PC or a Mac with macOS 13 or newer. A USB cable gives the best result; Wi-Fi works too.",
  },
  {
    q: "USB or Wi-Fi — which should I use?",
    a: "USB has the lowest delay and the smoothest picture. Turn on USB debugging on the tablet (Settings › Developer options) and plug it in. For Wi-Fi, put both devices on the same network and approve the 4-digit code on your computer the first time. The Wi-Fi stream isn't encrypted, so use Wi-Fi on networks you trust.",
  },
  {
    q: "Can the tablet be my only screen?",
    a: "Yes. Choose Primary and the tablet becomes your main display. On Windows, if no monitor is plugged in at all, PlexiChore makes the tablet the main display automatically.",
  },
  {
    q: "Can I play games on it?",
    a: "Many games work, at up to 60 fps. Because the picture is encoded and sent to the tablet, there is a little more delay than with a monitor on a cable, so it suits slower-paced games best. Run games in borderless window mode.",
  },
  {
    q: "Does my screen go through the internet?",
    a: "No. The picture travels directly between your computer and your tablet over USB or your local network. PlexiChore has no account, no cloud service and no analytics.",
  },
  {
    q: "Why does Windows show a SmartScreen warning?",
    a: "The Windows app isn't code-signed yet, so Windows doesn't recognise it. Choose More info → Run anyway. Every download is published on GitHub with SHA-256 checksums so you can verify it.",
  },
  {
    q: "Does it work with an iPad or an Android phone?",
    a: "PlexiChore is made for Android tablets. iPads aren't supported. An Android phone may work, but the app is designed for tablet screens.",
  },
];

function SectionTitle({ eyebrow, title, text }: { eyebrow: string; title: string; text?: string }) {
  return (
    <Reveal className="mx-auto max-w-2xl text-center">
      <span className="eyebrow">{eyebrow}</span>
      <h2 className="mt-3 text-balance font-display text-3xl font-semibold tracking-tight sm:text-[2.6rem] sm:leading-tight">{title}</h2>
      {text && <p className="mt-4 text-balance text-lg text-muted">{text}</p>}
    </Reveal>
  );
}
