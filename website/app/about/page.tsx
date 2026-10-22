import type { Metadata } from "next";
import Link from "next/link";
import { ArrowRight, Code2, Heart, Lock, Sparkles } from "lucide-react";
import { GitHubIcon } from "@/components/BrandIcons";
import { PageShell } from "@/components/PageShell";
import { site } from "@/lib/site";

export const metadata: Metadata = {
  title: "About us",
  description: "PlexiChore is a free, open-source app by PNT Apps that turns an Android tablet into a monitor for Windows and Mac.",
  alternates: { canonical: "/about" },
};

const values = [
  {
    icon: Sparkles,
    title: "Give old hardware a new job",
    text: "Most of us have a tablet that spends its days in a drawer. PlexiChore turns it into the second screen you were about to buy.",
  },
  {
    icon: Lock,
    title: "Private by default",
    text: "No account, no cloud and no analytics. Your screen travels straight from your computer to your tablet and nowhere else.",
  },
  {
    icon: Code2,
    title: "Open for everyone",
    text: "The Android app and both computer apps are open source under the GPL-3.0 license, so anyone can read, verify and improve them.",
  },
];

export default function AboutPage() {
  return (
    <PageShell
      wide
      eyebrow="About us"
      title="Built by PNT Apps"
      intro={
        <p>
          PlexiChore is made by{" "}
          <a href={site.company.url} className="text-fg underline decoration-white/30 underline-offset-4 hover:decoration-white">
            PNT Apps
          </a>
          , an independent app studio from {site.company.country} that builds iOS, Android, web and desktop apps.
        </p>
      }
    >
      <div className="grid gap-12 lg:grid-cols-[1.3fr_1fr]">
        <div className="prose-plexi">
          <h2 className="!mt-0">Why we built PlexiChore</h2>
          <p>
            A second screen makes almost everything easier — writing next to your research, coding next to the docs,
            keeping a chat open while you work. But a portable monitor is one more thing to buy and carry, while a
            perfectly good tablet is often sitting unused.
          </p>
          <p>
            PlexiChore connects the two. The computer app creates a real virtual display, captures it with the
            graphics card, and streams it to the tablet as hardware-encoded video. Touch and pen input travel the other
            way, so the tablet behaves like a touchscreen monitor. Over a USB cable it&apos;s quick enough that you
            forget it isn&apos;t one.
          </p>
          <h2>What&apos;s in the box</h2>
          <ul>
            <li>
              <strong>PlexiChore for Android</strong> — the tablet app that shows the picture and sends your touches.
            </li>
            <li>
              <strong>PlexiChore Desktop for Windows</strong> — uses a signed, open-source virtual display driver for
              Extend and Primary modes.
            </li>
            <li>
              <strong>PlexiChore for Mac</strong> — a menu bar app, signed and notarized by Apple.
            </li>
          </ul>
          <h2>Open source</h2>
          <p>
            All of PlexiChore is published on{" "}
            <a href={site.github}>GitHub</a> under the GNU General Public License v3.0. You may use, study, change and
            share it. If you distribute a modified version, you must share its source under the same license and keep
            the credit &ldquo;Developed by PNT Apps&rdquo;.
          </p>
        </div>

        <div className="space-y-4">
          {values.map(({ icon: Icon, title, text }) => (
            <div key={title} className="glass rounded-3xl p-6">
              <Icon className="size-6 text-cyan" aria-hidden="true" />
              <h3 className="mt-4 font-display text-lg font-semibold">{title}</h3>
              <p className="mt-1.5 leading-relaxed text-muted">{text}</p>
            </div>
          ))}
          <div className="glass rounded-3xl p-6">
            <Heart className="size-6 text-violet-soft" aria-hidden="true" />
            <h3 className="mt-4 font-display text-lg font-semibold">Get involved</h3>
            <p className="mt-1.5 leading-relaxed text-muted">
              Found a bug or have an idea? Open an issue on GitHub or write to us.
            </p>
            <div className="mt-5 flex flex-wrap gap-3">
              <a href={site.issues} className="btn-ghost !px-4 !py-2 text-sm">
                <GitHubIcon className="size-4" /> Open an issue
              </a>
              <Link href="/contact" className="btn-ghost !px-4 !py-2 text-sm">
                Contact us <ArrowRight className="size-4" aria-hidden="true" />
              </Link>
            </div>
          </div>
        </div>
      </div>
    </PageShell>
  );
}
