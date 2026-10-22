import Image from "next/image";
import Link from "next/link";
import { GitHubIcon } from "@/components/BrandIcons";
import { site } from "@/lib/site";

const columns = [
  {
    title: "Product",
    links: [
      { href: "/#features", label: "Features" },
      { href: "/#modes", label: "Display modes" },
      { href: "/#download", label: "Download" },
      { href: "/#faq", label: "FAQ" },
    ],
  },
  {
    title: "Company",
    links: [
      { href: "/about", label: "About us" },
      { href: "/contact", label: "Contact us" },
      { href: site.company.url, label: "PNT Apps", external: true },
    ],
  },
  {
    title: "Legal",
    links: [
      { href: "/privacy", label: "Privacy Policy" },
      { href: "/terms", label: "Terms & Conditions" },
      { href: `${site.github}/blob/main/LICENSE`, label: "GPL-3.0 License", external: true },
    ],
  },
] as const;

export function SiteFooter() {
  return (
    <footer className="relative border-t border-line bg-ink-950">
      <div className="mx-auto grid max-w-6xl gap-10 px-4 py-14 sm:px-6 md:grid-cols-[1.4fr_1fr_1fr_1fr]">
        <div>
          <Link href="/" className="flex items-center gap-2.5">
            <Image src="/logo.png" alt="" width={32} height={32} className="rounded-[9px]" />
            <span className="font-display text-lg font-semibold">PlexiChore</span>
          </Link>
          <p className="mt-4 max-w-xs text-sm leading-relaxed text-muted">
            Turn your Android tablet into a portable monitor for Windows and Mac. Free and open source.
          </p>
          <a
            href={site.github}
            className="mt-5 inline-flex items-center gap-2 text-sm text-muted transition-colors hover:text-fg"
          >
            <GitHubIcon className="size-4" />
            Source code on GitHub
          </a>
        </div>

        {columns.map((col) => (
          <div key={col.title}>
            <h2 className="font-display text-sm font-semibold text-fg">{col.title}</h2>
            <ul className="mt-4 space-y-2.5">
              {col.links.map((l) => (
                <li key={l.label}>
                  {"external" in l ? (
                    <a href={l.href} className="text-sm text-muted transition-colors hover:text-fg">
                      {l.label}
                    </a>
                  ) : (
                    <Link href={l.href} className="text-sm text-muted transition-colors hover:text-fg">
                      {l.label}
                    </Link>
                  )}
                </li>
              ))}
            </ul>
          </div>
        ))}
      </div>

      <div className="border-t border-line">
        <div className="mx-auto flex max-w-6xl flex-col gap-2 px-4 py-6 text-xs text-subtle sm:flex-row sm:items-center sm:justify-between sm:px-6">
          <p>© 2026 PNT Apps. PlexiChore is free software under the GNU GPL v3.0.</p>
          {/* Required attribution (GPL-3.0 section 7(b), see NOTICE in the repository). */}
          <p>
            Developed by{" "}
            <a href={site.company.url} className="font-medium text-muted underline-offset-4 hover:text-fg hover:underline">
              PNT Apps
            </a>
          </p>
        </div>
      </div>
    </footer>
  );
}
