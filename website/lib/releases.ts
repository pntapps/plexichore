import { site } from "@/lib/site";

/**
 * Download links come straight from the GitHub Releases of the repo, so publishing a new release is all it takes to
 * update the site: for each kind, the newest version among all releases wins (a release may carry only some apps —
 * v1.1.0 shipped Windows only). Results are cached for REVALIDATE_SECONDS.
 *
 * Asset names must follow the release convention in RELEASING.md:
 *   PlexiChoreSetup-<ver>.exe · PlexiChore-Windows-<ver>-portable.exe · PlexiChore-Mac-<ver>.dmg · PlexiChore-Android-<ver>.apk
 */
export const REVALIDATE_SECONDS = 600;

export type DownloadKind = "windows" | "windowsPortable" | "mac" | "android";

export type Download = {
  kind: DownloadKind;
  version: string;
  url: string;
  fileName: string;
  sizeBytes: number;
  publishedAt: string;
  releaseUrl: string;
  prerelease: boolean;
};

export type Downloads = Record<DownloadKind, Download | null>;

const VERSION = String.raw`(\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?)`;
const PATTERNS: Record<DownloadKind, RegExp> = {
  windows: new RegExp(`^PlexiChoreSetup-${VERSION}\\.exe$`, "i"),
  windowsPortable: new RegExp(`^PlexiChore-Windows-${VERSION}-portable\\.exe$`, "i"),
  mac: new RegExp(`^PlexiChore-Mac-${VERSION}\\.dmg$`, "i"),
  android: new RegExp(`^PlexiChore-Android-${VERSION}\\.apk$`, "i"),
};

/** Paths of the stable redirect links (/download/<slug>), always pointing at the newest file. */
export const DOWNLOAD_SLUGS: Record<string, DownloadKind> = {
  windows: "windows",
  "windows-portable": "windowsPortable",
  mac: "mac",
  android: "android",
};

type GitHubAsset = { name: string; browser_download_url: string; size: number; state?: string };
type GitHubRelease = {
  tag_name: string;
  html_url: string;
  draft: boolean;
  prerelease: boolean;
  published_at: string | null;
  assets: GitHubAsset[];
};

/** Semver-ish comparison: numeric core first; a pre-release suffix (1.2.0-beta) sorts before the plain version. */
export function compareVersions(a: string, b: string): number {
  const [coreA, preA] = a.split("-", 2);
  const [coreB, preB] = b.split("-", 2);
  const pa = coreA.split(".").map(Number);
  const pb = coreB.split(".").map(Number);
  for (let i = 0; i < 3; i++) {
    const d = (pa[i] ?? 0) - (pb[i] ?? 0);
    if (d !== 0) return d;
  }
  if (preA && !preB) return -1;
  if (!preA && preB) return 1;
  return (preA ?? "").localeCompare(preB ?? "");
}

/** Pre-releases count by default (the first Windows build was one). Set PLEXI_INCLUDE_PRERELEASES=false to skip them. */
const includePrereleases = process.env.PLEXI_INCLUDE_PRERELEASES !== "false";

async function fetchReleases(): Promise<GitHubRelease[]> {
  const headers: Record<string, string> = {
    Accept: "application/vnd.github+json",
    "X-GitHub-Api-Version": "2022-11-28",
    "User-Agent": "plexichore-website",
  };
  // Optional: a token raises GitHub's limit from 60 to 5,000 requests per hour (only needed for heavy traffic).
  if (process.env.GITHUB_TOKEN) headers.Authorization = `Bearer ${process.env.GITHUB_TOKEN}`;
  try {
    const res = await fetch(`https://api.github.com/repos/${site.repo}/releases?per_page=50`, {
      headers,
      next: { revalidate: REVALIDATE_SECONDS, tags: ["releases"] },
    });
    if (!res.ok) {
      console.error(`GitHub releases request failed: ${res.status}`);
      return [];
    }
    return (await res.json()) as GitHubRelease[];
  } catch (err) {
    console.error("GitHub releases request failed", err);
    return [];
  }
}

export function pickDownloads(releases: GitHubRelease[]): Downloads {
  const out: Downloads = { windows: null, windowsPortable: null, mac: null, android: null };
  for (const rel of releases) {
    if (rel.draft || (rel.prerelease && !includePrereleases)) continue;
    for (const asset of rel.assets) {
      if (asset.state && asset.state !== "uploaded") continue;
      for (const kind of Object.keys(PATTERNS) as DownloadKind[]) {
        const m = PATTERNS[kind].exec(asset.name);
        if (!m) continue;
        const current = out[kind];
        if (current && compareVersions(m[1], current.version) <= 0) continue;
        out[kind] = {
          kind,
          version: m[1],
          url: asset.browser_download_url,
          fileName: asset.name,
          sizeBytes: asset.size,
          publishedAt: rel.published_at ?? "",
          releaseUrl: rel.html_url,
          prerelease: rel.prerelease,
        };
      }
    }
  }
  return out;
}

export async function getDownloads(): Promise<Downloads> {
  return pickDownloads(await fetchReleases());
}

export function formatSize(bytes: number): string {
  if (!bytes) return "";
  const mb = bytes / (1024 * 1024);
  return mb >= 10 ? `${Math.round(mb)} MB` : `${mb.toFixed(1)} MB`;
}
