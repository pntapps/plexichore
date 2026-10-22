"use client";

import { useEffect, useState, type ComponentType } from "react";
import { ArrowDownToLine, ExternalLink, Info } from "lucide-react";
import { AndroidIcon, AppleIcon, WindowsIcon } from "@/components/BrandIcons";
import { detectOS, type DetectedOS } from "@/lib/platform";
import type { Download, Downloads } from "@/lib/releases";
import { site } from "@/lib/site";

type Platform = "windows" | "mac" | "android";

const PLATFORMS: Record<
  Platform,
  { name: string; icon: ComponentType<{ className?: string }>; requirement: string; kindLabel: string }
> = {
  windows: { name: "Windows", icon: WindowsIcon, requirement: "Windows 10 or 11, 64-bit", kindLabel: "Installer" },
  mac: { name: "Mac", icon: AppleIcon, requirement: "macOS 13+ · Apple Silicon & Intel", kindLabel: "Disk image" },
  android: { name: "Android", icon: AndroidIcon, requirement: "Android 8+ tablet", kindLabel: "APK" },
};

function fileFor(downloads: Downloads, p: Platform): Download | null {
  return p === "windows" ? (downloads.windows ?? downloads.windowsPortable) : downloads[p];
}

function meta(d: Download | null, p: Platform, size: (n: number) => string) {
  if (!d) return "See all releases on GitHub";
  return [`v${d.version}`, PLATFORMS[p].kindLabel, size(d.sizeBytes)].filter(Boolean).join(" · ");
}

function formatSize(bytes: number) {
  if (!bytes) return "";
  const mb = bytes / (1024 * 1024);
  return mb >= 10 ? `${Math.round(mb)} MB` : `${mb.toFixed(1)} MB`;
}

function useDetectedOS() {
  const [os, setOs] = useState<DetectedOS | null>(null);
  useEffect(() => setOs(detectOS()), []);
  return os;
}

/** The hero's main button: the right file for the visitor's computer, plus quick links to the other platforms. */
export function SmartDownload({ downloads }: { downloads: Downloads }) {
  const os = useDetectedOS();
  const primary: Platform | null = os === "windows" || os === "mac" || os === "android" ? os : null;

  return (
    <div className={`transition-opacity duration-300 ${os === null ? "opacity-0" : "opacity-100"}`}>
      {primary ? (
        <PrimaryButton platform={primary} download={fileFor(downloads, primary)} />
      ) : (
        <div className="flex flex-wrap gap-3">
          {(["windows", "mac"] as const).map((p) => (
            <PrimaryButton key={p} platform={p} download={fileFor(downloads, p)} compact />
          ))}
        </div>
      )}

      {primary === "android" && (
        <p className="mt-4 flex max-w-md items-start gap-2 text-sm text-muted">
          <Info className="mt-0.5 size-4 shrink-0 text-cyan-soft" aria-hidden="true" />
          Not on Google Play yet, so this downloads the APK directly. You&apos;ll also need PlexiChore on your Windows PC
          or Mac.
        </p>
      )}
      {os === "ios" && (
        <p className="mt-4 flex max-w-md items-start gap-2 text-sm text-muted">
          <Info className="mt-0.5 size-4 shrink-0 text-cyan-soft" aria-hidden="true" />
          PlexiChore works with an Android tablet and a Windows PC or Mac. Open this page on your computer to download.
        </p>
      )}

      <div className="mt-5 flex flex-wrap items-center gap-x-4 gap-y-2 text-sm text-subtle">
        <span>{primary ? "Also for" : "Tablet app"}</span>
        {(["windows", "mac", "android"] as const)
          .filter((p) => p !== primary && (primary !== null || p === "android"))
          .map((p) => {
            const d = fileFor(downloads, p);
            const Icon = PLATFORMS[p].icon;
            return (
              <a
                key={p}
                href={d?.url ?? site.releases}
                className="inline-flex items-center gap-1.5 text-muted transition-colors hover:text-fg"
              >
                <Icon className="size-4" />
                {p === "android" ? "Android (APK)" : PLATFORMS[p].name}
              </a>
            );
          })}
      </div>
    </div>
  );
}

function PrimaryButton({ platform, download, compact }: { platform: Platform; download: Download | null; compact?: boolean }) {
  const { name, icon: Icon } = PLATFORMS[platform];
  return (
    <a href={download?.url ?? site.releases} className={`btn-primary ${compact ? "!px-5" : "!px-6 !py-4"}`}>
      <Icon className={compact ? "size-5" : "size-6"} />
      <span className="flex flex-col items-start leading-tight">
        <span className={compact ? "text-[15px]" : "text-base sm:text-lg"}>
          {platform === "android" ? "Download for Android" : `Download for ${name}`}
        </span>
        <span className="text-xs font-normal text-white/75">{meta(download, platform, formatSize)}</span>
      </span>
    </a>
  );
}

/** The three platform cards of the download section; the visitor's own platform is highlighted. */
export function DownloadCards({ downloads }: { downloads: Downloads }) {
  const os = useDetectedOS();
  return (
    <div className="grid gap-5 md:grid-cols-3">
      {(["windows", "mac", "android"] as const).map((p) => {
        const d = fileFor(downloads, p);
        const { name, icon: Icon, requirement } = PLATFORMS[p];
        const mine = os === p;
        return (
          <div
            key={p}
            className={`glass card-hover relative flex flex-col rounded-3xl p-6 ${
              mine ? "!border-violet/50 shadow-[0_0_60px_-20px_rgb(139_92_246/0.7)]" : ""
            }`}
          >
            {mine && (
              <span className="bg-brand absolute -top-3 left-6 rounded-full px-3 py-1 text-xs font-semibold text-white">
                Your device
              </span>
            )}
            <div className="flex items-center gap-3">
              <span className="grid size-12 place-items-center rounded-2xl border border-line bg-white/5">
                <Icon className="size-6 text-fg" />
              </span>
              <div>
                <h3 className="font-display text-xl font-semibold">{p === "android" ? "Android tablet" : name}</h3>
                <p className="text-sm text-subtle">{requirement}</p>
              </div>
            </div>

            <dl className="mt-6 space-y-2 text-sm">
              <div className="flex justify-between gap-4">
                <dt className="text-subtle">Version</dt>
                <dd className="font-medium text-fg">{d ? d.version : "—"}</dd>
              </div>
              <div className="flex justify-between gap-4">
                <dt className="text-subtle">File</dt>
                <dd className="truncate text-muted">{d ? `${d.fileName.split(".").pop()?.toUpperCase()} · ${formatSize(d.sizeBytes)}` : "—"}</dd>
              </div>
              <div className="flex justify-between gap-4">
                <dt className="text-subtle">Released</dt>
                <dd className="text-muted">
                  {d?.publishedAt
                    ? new Date(d.publishedAt).toLocaleDateString("en-GB", { day: "numeric", month: "short", year: "numeric" })
                    : "—"}
                </dd>
              </div>
            </dl>

            <p className="mt-5 flex-1 text-sm leading-relaxed text-muted">
              {p === "windows" &&
                "Installs in a minute. Extend and Primary use a signed, open-source virtual display driver the app installs for you."}
              {p === "mac" && "Signed with Developer ID and notarized by Apple. Lives in your menu bar."}
              {p === "android" &&
                "Not on Google Play yet. Download the APK on your tablet and allow installing it when Android asks."}
            </p>

            <a
              href={d?.url ?? site.releases}
              className={`mt-6 justify-center ${mine ? "btn-primary" : "btn-ghost"}`}
            >
              <ArrowDownToLine className="size-4" aria-hidden="true" />
              {d ? `Download ${p === "android" ? "APK" : `for ${name}`}` : "View releases"}
            </a>
            {p === "windows" && downloads.windowsPortable ? (
              <a
                href={downloads.windowsPortable.url}
                className="mt-3 text-center text-xs leading-4 text-subtle underline-offset-4 hover:text-fg hover:underline"
              >
                Portable .exe (no install) · {formatSize(downloads.windowsPortable.sizeBytes)}
              </a>
            ) : (
              // keeps the buttons of all three cards on one line
              <span className="mt-3 hidden h-4 md:block" aria-hidden="true" />
            )}
          </div>
        );
      })}
      <p className="text-sm text-subtle md:col-span-3">
        Every file is published on{" "}
        <a href={site.releases} className="inline-flex items-center gap-1 text-muted underline-offset-4 hover:text-fg hover:underline">
          GitHub Releases <ExternalLink className="size-3" aria-hidden="true" />
        </a>{" "}
        with SHA-256 checksums. The Windows app isn&apos;t code-signed yet: if SmartScreen warns you, choose{" "}
        <span className="text-muted">More info → Run anyway</span>.
      </p>
    </div>
  );
}
