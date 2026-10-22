import type { Metadata } from "next";
import { PageShell } from "@/components/PageShell";
import { site } from "@/lib/site";

export const metadata: Metadata = {
  title: "Privacy Policy",
  description: "How PlexiChore and this website handle your data: no account, no analytics, and your screen never leaves your devices.",
  alternates: { canonical: "/privacy" },
};

export default function PrivacyPage() {
  return (
    <PageShell
      eyebrow="Legal"
      title="Privacy Policy"
      intro={<p>Last updated: {site.legalUpdated}</p>}
    >
      <div className="prose-plexi">
        <div className="glass rounded-2xl p-6 !text-fg">
          <p className="!mt-0 font-display text-lg font-semibold">The short version</p>
          <ul className="!mb-0">
            <li>PlexiChore has no account, no ads and no analytics. The apps don&apos;t send us any data.</li>
            <li>Your screen, touches and keystrokes travel directly between your own computer and tablet — never through our servers.</li>
            <li>This website uses no cookies and no tracking.</li>
          </ul>
        </div>

        <h2>Who we are</h2>
        <p>
          PlexiChore is developed by PNT Apps (&ldquo;we&rdquo;, &ldquo;us&rdquo;), an app studio based in{" "}
          {site.company.country}. This policy covers the PlexiChore apps for Android, Windows and macOS, and this website.
          Questions: <a href={`mailto:${site.company.supportEmail}`}>{site.company.supportEmail}</a>.
        </p>

        <h2>The PlexiChore apps</h2>
        <h3>What we collect</h3>
        <p>
          Nothing. The apps contain no analytics, crash reporting, advertising or tracking code, and they never send
          information to PNT Apps.
        </p>

        <h3>Your screen and input</h3>
        <p>
          While you are connected, the computer app captures the screen it is streaming (the virtual display, or the
          monitor you mirror) and sends it as video to your tablet. The tablet sends touch, pen and keyboard input back.
          This happens <strong>directly between your two devices</strong>, over a USB cable or your local network. It is
          not recorded or stored, and it does not pass through any server of ours or anyone else&apos;s.
        </p>
        <p>
          Over Wi-Fi, the stream is <strong>not encrypted</strong>. Someone else on the same network who captures the
          traffic could see the picture. Use a USB cable, or Wi-Fi only on networks you trust. A new tablet can only
          connect after you approve it on the computer.
        </p>

        <h3>Information on your local network</h3>
        <p>
          So that your tablet can find your computer, the computer app announces itself on your local network about once
          a second. The announcement contains the computer&apos;s name, its operating system (Windows or macOS), a random
          ID created by the app, and the network port. When you connect, the tablet tells the computer its name, model
          and screen details so the picture fits. All of this stays on your local network.
        </p>

        <h3>Stored on your devices</h3>
        <ul>
          <li>Your settings and the list of tablets you have approved (device names and IDs).</li>
          <li>
            On Windows, diagnostic log files in your user folder (<code>%LOCALAPPDATA%\PlexiChore\logs</code>); on Mac,
            entries in the system log. They stay on your computer unless you choose to send them to us.
          </li>
          <li>
            On Android, if you have turned on device backup to your Google account, Android may include the app&apos;s
            settings in that backup. This is handled by Google under its own privacy policy.
          </li>
        </ul>

        <h3>Downloads from third parties</h3>
        <p>Only when you ask for them, the computer apps download:</p>
        <ul>
          <li>
            the open-source <strong>Virtual Display Driver</strong> and the <strong>nefcon</strong> installer from GitHub
            (Windows, when you click Install on the Extended display page), and
          </li>
          <li>
            Android <strong>platform-tools (adb)</strong> from Google (when you choose to set up USB).
          </li>
        </ul>
        <p>
          Like any download, these requests show your IP address to GitHub or Google, under their own privacy
          policies.
        </p>

        <h3>Permissions</h3>
        <ul>
          <li>
            <strong>Android:</strong> network and local network access (to find and connect to your computer),
            notifications and a foreground service (to keep the connection running while you stream).
          </li>
          <li>
            <strong>macOS:</strong> Screen Recording (to capture the display), Accessibility (to apply touch and
            keyboard input) and Local Network (for Wi-Fi).
          </li>
          <li>
            <strong>Windows:</strong> administrator approval once, to install the virtual display driver.
          </li>
        </ul>

        <h2>This website</h2>
        <ul>
          <li>No cookies, analytics or advertising trackers. Fonts are served from this website itself.</li>
          <li>
            Like every website, our hosting provider processes technical data such as your IP address and browser type
            to deliver pages and keep the service secure.
          </li>
          <li>
            Your browser&apos;s operating system is checked <strong>in your browser only</strong> to suggest the right
            download. It is not sent to us.
          </li>
          <li>
            Downloads are served by <a href="https://docs.github.com/en/site-policy/privacy-policies/github-general-privacy-statement">GitHub</a>.
          </li>
          <li>
            The contact form doesn&apos;t send anything itself: it opens your own email app. If you email us, we use your
            address and message only to reply, and delete them when they are no longer needed.
          </li>
        </ul>

        <h2>Children</h2>
        <p>
          PlexiChore is a general-purpose tool and is not directed at children under 13. We do not knowingly collect
          personal information from anyone — including children.
        </p>

        <h2>Your rights</h2>
        <p>
          We hold no personal data from the apps. If you have emailed us, you can ask us to access or delete that
          correspondence by writing to <a href={`mailto:${site.company.supportEmail}`}>{site.company.supportEmail}</a>.
        </p>

        <h2>Changes</h2>
        <p>
          If we change how PlexiChore handles data, we will update this page and the date above. Because the apps are
          open source, every change is also visible in the <a href={site.github}>public code</a>.
        </p>
      </div>
    </PageShell>
  );
}
