"use client";

import Image from "next/image";
import Link from "next/link";
import { useEffect, useState } from "react";
import { Download, Menu, X } from "lucide-react";
import { nav } from "@/lib/site";

export function SiteHeader() {
  const [open, setOpen] = useState(false);
  const [scrolled, setScrolled] = useState(false);

  useEffect(() => {
    const onScroll = () => setScrolled(window.scrollY > 12);
    onScroll();
    window.addEventListener("scroll", onScroll, { passive: true });
    return () => window.removeEventListener("scroll", onScroll);
  }, []);

  return (
    <header
      className={`fixed inset-x-0 top-0 z-50 transition-all duration-300 ${
        scrolled || open ? "border-b border-line bg-ink-950/80 backdrop-blur-xl" : "border-b border-transparent"
      }`}
    >
      <div className="mx-auto flex h-16 max-w-6xl items-center justify-between px-4 sm:px-6">
        <Link href="/" className="flex items-center gap-2.5" onClick={() => setOpen(false)}>
          <Image src="/logo.png" alt="" width={34} height={34} className="rounded-[10px]" priority />
          <span className="font-display text-lg font-semibold tracking-tight">PlexiChore</span>
        </Link>

        <nav className="hidden items-center gap-1 md:flex" aria-label="Main">
          {nav.map((item) => (
            <Link
              key={item.href}
              href={item.href}
              className="rounded-full px-3.5 py-2 text-sm text-muted transition-colors hover:bg-white/5 hover:text-fg"
            >
              {item.label}
            </Link>
          ))}
        </nav>

        <div className="flex items-center gap-2">
          <Link href="/#download" className="btn-primary hidden !gap-2 !px-4 !py-2 text-sm sm:inline-flex">
            <Download className="size-4" aria-hidden="true" />
            Download
          </Link>
          <button
            type="button"
            className="grid size-10 place-items-center rounded-full text-muted hover:bg-white/5 hover:text-fg md:hidden"
            aria-label={open ? "Close menu" : "Open menu"}
            aria-expanded={open}
            onClick={() => setOpen((v) => !v)}
          >
            {open ? <X className="size-5" /> : <Menu className="size-5" />}
          </button>
        </div>
      </div>

      {open && (
        <nav className="border-t border-line px-4 pb-5 pt-2 md:hidden" aria-label="Mobile">
          {nav.map((item) => (
            <Link
              key={item.href}
              href={item.href}
              onClick={() => setOpen(false)}
              className="block rounded-xl px-3 py-3 text-base text-muted hover:bg-white/5 hover:text-fg"
            >
              {item.label}
            </Link>
          ))}
          <Link href="/#download" onClick={() => setOpen(false)} className="btn-primary mt-3 w-full justify-center">
            <Download className="size-4" aria-hidden="true" />
            Download PlexiChore
          </Link>
        </nav>
      )}
    </header>
  );
}
