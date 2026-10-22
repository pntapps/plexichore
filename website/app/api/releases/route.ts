import { NextResponse } from "next/server";
import { getDownloads, REVALIDATE_SECONDS } from "@/lib/releases";

/** Latest version + file per platform as JSON (e.g. for an "update available" check in the apps). */
export async function GET() {
  const downloads = await getDownloads();
  return NextResponse.json(downloads, {
    headers: { "Cache-Control": `public, s-maxage=${REVALIDATE_SECONDS}, stale-while-revalidate=86400` },
  });
}
