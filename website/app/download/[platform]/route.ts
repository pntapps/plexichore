import { NextResponse } from "next/server";
import { DOWNLOAD_SLUGS, getDownloads } from "@/lib/releases";
import { site } from "@/lib/site";

/**
 * Stable links that always serve the newest file: /download/windows, /download/windows-portable, /download/mac,
 * /download/android. Safe to put in the apps, READMEs and social posts. Unknown or missing → the GitHub Releases page.
 */
export async function GET(_req: Request, ctx: { params: Promise<{ platform: string }> }) {
  const { platform } = await ctx.params;
  const kind = DOWNLOAD_SLUGS[platform.toLowerCase()];
  const download = kind ? (await getDownloads())[kind] : null;
  return NextResponse.redirect(download?.url ?? site.releases, 302);
}
