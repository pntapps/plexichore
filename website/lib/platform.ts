export type DetectedOS = "windows" | "mac" | "android" | "ios" | "linux" | "unknown";

type NavigatorWithUAData = Navigator & { userAgentData?: { platform?: string; mobile?: boolean } };

/** Browser-side guess of the visitor's OS. Only call it in the browser (after mount). */
export function detectOS(): DetectedOS {
  const nav = navigator as NavigatorWithUAData;
  const platform = (nav.userAgentData?.platform ?? "").toLowerCase();
  const ua = nav.userAgent.toLowerCase();

  // The UA string still names the OS reliably (UA reduction keeps it); the UA-CH platform is only a fallback.
  if (ua.includes("android")) return "android";
  // iPadOS Safari reports itself as "Macintosh"; touch support gives it away.
  if (/iphone|ipad|ipod/.test(ua) || (ua.includes("macintosh") && nav.maxTouchPoints > 1)) return "ios";
  if (ua.includes("windows")) return "windows";
  if (ua.includes("mac os x") || ua.includes("macintosh")) return "mac";
  if (ua.includes("cros") || ua.includes("linux")) return "linux";
  if (platform === "android") return "android";
  if (platform === "windows") return "windows";
  if (platform === "macos") return "mac";
  if (platform === "linux" || platform === "chrome os") return "linux";
  return "unknown";
}
