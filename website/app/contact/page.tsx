import type { Metadata } from "next";
import { Building2, LifeBuoy } from "lucide-react";
import { GitHubIcon } from "@/components/BrandIcons";
import { ContactForm } from "@/components/ContactForm";
import { PageShell } from "@/components/PageShell";
import { site } from "@/lib/site";

export const metadata: Metadata = {
  title: "Contact us",
  description: "Get help with PlexiChore, report a bug or get in touch with PNT Apps.",
  alternates: { canonical: "/contact" },
};

const channels = [
  {
    icon: LifeBuoy,
    title: "Support",
    text: "Setup help, connection problems, questions about the apps.",
    href: `mailto:${site.company.supportEmail}`,
    label: site.company.supportEmail,
  },
  {
    icon: GitHubIcon,
    title: "Bugs & feature ideas",
    text: "Public issue tracker — see if someone already reported it.",
    href: site.issues,
    label: "GitHub issues",
  },
  {
    icon: Building2,
    title: "Business & press",
    text: "Partnerships, press and everything else.",
    href: `mailto:${site.company.email}`,
    label: site.company.email,
  },
] as const;

export default function ContactPage() {
  return (
    <PageShell
      wide
      eyebrow="Contact us"
      title="We'd love to hear from you"
      intro={<p>Questions, problems or ideas — write to us and we&apos;ll get back to you as soon as we can.</p>}
    >
      <div className="grid gap-8 lg:grid-cols-[1fr_1.4fr]">
        <div className="space-y-4">
          {channels.map(({ icon: Icon, title, text, href, label }) => (
            <a key={title} href={href} className="glass card-hover flex gap-4 rounded-3xl p-6">
              <span className="grid size-11 shrink-0 place-items-center rounded-xl border border-white/10 bg-gradient-to-br from-violet/25 to-cyan/15">
                <Icon className="size-5 text-fg" />
              </span>
              <span>
                <span className="block font-display text-lg font-semibold">{title}</span>
                <span className="mt-1 block text-sm leading-relaxed text-muted">{text}</span>
                <span className="mt-2 block text-sm font-medium text-cyan-soft">{label}</span>
              </span>
            </a>
          ))}
          <p className="px-2 text-sm leading-relaxed text-subtle">
            When reporting a problem, tell us your computer (Windows or Mac version), your tablet model, and whether you
            connect by USB or Wi-Fi.
          </p>
        </div>
        <ContactForm />
      </div>
    </PageShell>
  );
}
