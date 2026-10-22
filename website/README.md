# PlexiChore website

The landing page for PlexiChore: Home, About, Contact, Privacy Policy and Terms & Conditions, with downloads that
always point at the newest release. Next.js 16 (App Router) + Tailwind CSS 4, no database, no cookies, no analytics.

```bash
npm install
npm run dev      # http://localhost:3000
npm run build && npm start
```

## How downloads stay up to date
`lib/releases.ts` reads the GitHub Releases of `pntapps/plexichore` (cached for 10 minutes) and, for each platform,
picks the **highest version** among all published releases — so a release may carry only some of the apps
(v1.1.0 had only Windows; Mac and Android then come from v1.0.0). Publishing a GitHub release is all it takes; the
site needs no change or redeploy.

Asset names must follow the release convention:

| Platform | File name |
|---|---|
| Windows installer | `PlexiChoreSetup-<version>.exe` |
| Windows portable | `PlexiChore-Windows-<version>-portable.exe` |
| Mac | `PlexiChore-Mac-<version>.dmg` |
| Android | `PlexiChore-Android-<version>.apk` |

- Pre-releases count (set `PLEXI_INCLUDE_PRERELEASES=false` to ignore them); drafts never do.
- Stable links that always serve the newest file: `/download/windows`, `/download/windows-portable`, `/download/mac`,
  `/download/android` (anything unknown → the GitHub Releases page). `/api/releases` returns the same data as JSON.
- The visitor's OS is detected in the browser (`lib/platform.ts`): Windows → installer, Mac → DMG, Android → APK;
  other devices see the Windows and Mac buttons.

## Configuration (environment variables, all optional)
| Variable | Purpose |
|---|---|
| `NEXT_PUBLIC_SITE_URL` | Public URL used in metadata, sitemap and robots (default `https://plexichore.pntapps.com`). |
| `GITHUB_TOKEN` | Read-only token to raise GitHub's API limit (60 → 5,000 requests/hour). Not needed with the 10-minute cache. |
| `PLEXI_INCLUDE_PRERELEASES` | `false` to ignore pre-releases. |

## Deploy
Vercel: import the repo, set **Root Directory** to `website`, framework Next.js, then add the domain. Any Node host
works too (`npm run build && npm start`).

## Content to keep current
- `lib/site.ts`: contact emails, links, and `legalUpdated` (date shown on the Privacy and Terms pages).
- The Privacy Policy describes what the apps do (no analytics, local-only streaming, third-party downloads). Update it
  whenever that changes.
- Keep the "Developed by PNT Apps" credit in the footer (GPL-3.0 section 7(b), see `../NOTICE`).
