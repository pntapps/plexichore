export const site = {
  name: "PlexiChore",
  url: (process.env.NEXT_PUBLIC_SITE_URL ?? "https://plexichore.pntapps.com").replace(/\/$/, ""),
  tagline: "Your tablet, your next screen.",
  description:
    "PlexiChore turns your Android tablet into a portable monitor for your Windows PC or Mac. Extend your desktop, make the tablet your main display, or mirror your screen — over USB or Wi-Fi, with touch and pen.",
  repo: "pntapps/plexichore",
  github: "https://github.com/pntapps/plexichore",
  releases: "https://github.com/pntapps/plexichore/releases",
  issues: "https://github.com/pntapps/plexichore/issues",
  company: {
    name: "PNT Apps",
    url: "https://www.pntapps.com",
    email: "contact@pntapps.com",
    supportEmail: "support@pntapps.com",
    country: "India",
  },
  /** Date shown on the Privacy Policy and Terms pages. Update it whenever you change either page. */
  legalUpdated: "22 October 2026",
} as const;

export const nav = [
  { href: "/#features", label: "Features" },
  { href: "/#how-it-works", label: "How it works" },
  { href: "/#download", label: "Download" },
  { href: "/about", label: "About" },
  { href: "/contact", label: "Contact" },
] as const;
