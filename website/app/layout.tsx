import type { Metadata, Viewport } from "next";
import { Inter, Space_Grotesk } from "next/font/google";
import { SiteFooter } from "@/components/SiteFooter";
import { SiteHeader } from "@/components/SiteHeader";
import { site } from "@/lib/site";
import "./globals.css";

const inter = Inter({ variable: "--font-inter", subsets: ["latin"], display: "swap" });
const spaceGrotesk = Space_Grotesk({ variable: "--font-space-grotesk", subsets: ["latin"], display: "swap" });

export const metadata: Metadata = {
  metadataBase: new URL(site.url),
  title: {
    default: "PlexiChore — Turn your Android tablet into a monitor for Windows & Mac",
    template: "%s · PlexiChore",
  },
  description: site.description,
  applicationName: site.name,
  authors: [{ name: site.company.name, url: site.company.url }],
  creator: site.company.name,
  publisher: site.company.name,
  alternates: { canonical: "/" },
  openGraph: {
    type: "website",
    siteName: site.name,
    url: site.url,
    title: "PlexiChore — Your tablet, your next screen",
    description: site.description,
    images: [{ url: "/logo.png", width: 256, height: 256, alt: "PlexiChore" }],
  },
  twitter: { card: "summary", title: "PlexiChore — Your tablet, your next screen", description: site.description },
  keywords: [
    "android tablet as second monitor",
    "use tablet as monitor windows",
    "use android tablet as mac display",
    "extend display to tablet",
    "portable monitor app",
    "PlexiChore",
  ],
};

export const viewport: Viewport = {
  themeColor: "#06051a",
  colorScheme: "dark",
};

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return (
    // suppressHydrationWarning: the inline script adds the "js" class before React hydrates.
    <html lang="en" className={`${inter.variable} ${spaceGrotesk.variable}`} suppressHydrationWarning>
      <head>
        {/* Scroll-reveal content starts hidden only when JavaScript can reveal it again. */}
        <script dangerouslySetInnerHTML={{ __html: "document.documentElement.classList.add('js')" }} />
      </head>
      <body className="min-h-dvh overflow-x-clip">
        <a
          href="#main"
          className="sr-only focus:not-sr-only focus:fixed focus:left-4 focus:top-4 focus:z-[60] focus:rounded-full focus:bg-white focus:px-4 focus:py-2 focus:text-ink-950"
        >
          Skip to content
        </a>
        <SiteHeader />
        <main id="main">{children}</main>
        <SiteFooter />
      </body>
    </html>
  );
}
