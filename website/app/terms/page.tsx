import type { Metadata } from "next";
import Link from "next/link";
import { PageShell } from "@/components/PageShell";
import { site } from "@/lib/site";

export const metadata: Metadata = {
  title: "Terms & Conditions",
  description: "The terms for using PlexiChore and this website, including the GPL-3.0 license and attribution terms.",
  alternates: { canonical: "/terms" },
};

export default function TermsPage() {
  return (
    <PageShell eyebrow="Legal" title="Terms & Conditions" intro={<p>Last updated: {site.legalUpdated}</p>}>
      <div className="prose-plexi">
        <p className="!mt-0">
          These terms apply to the PlexiChore apps for Android, Windows and macOS (&ldquo;PlexiChore&rdquo; or &ldquo;the
          software&rdquo;) and to this website, provided by PNT Apps (&ldquo;we&rdquo;, &ldquo;us&rdquo;). By downloading
          or using PlexiChore you agree to them.
        </p>

        <h2>1. License</h2>
        <p>
          PlexiChore is free software, licensed under the{" "}
          <a href={`${site.github}/blob/main/LICENSE`}>GNU General Public License v3.0</a> together with the additional
          attribution terms in the <a href={`${site.github}/blob/main/NOTICE`}>NOTICE</a> file. In short:
        </p>
        <ul>
          <li>You may use, study, change and share PlexiChore, including commercially.</li>
          <li>
            If you distribute PlexiChore or a modified version, you must make its source code available under the same
            license, including the attribution terms.
          </li>
          <li>
            You must keep the credit <strong>&ldquo;Developed by PNT Apps&rdquo;</strong> with a link to{" "}
            <a href={site.company.url}>{site.company.url.replace("https://", "")}</a> in your README and in a place in the
            app where users can see it.
          </li>
          <li>
            A modified version must not be presented as the original PlexiChore, and may not use the names
            &ldquo;PNT Apps&rdquo; or &ldquo;PlexiChore&rdquo; or their logos and icons as its own name or icon.
          </li>
        </ul>
        <p>
          Nothing in these terms limits the rights the GPL-3.0 gives you. If these terms and the license ever conflict
          about the software, the license wins.
        </p>

        <h2>2. Price</h2>
        <p>PlexiChore is free. There are no accounts, subscriptions or in-app purchases.</p>

        <h2>3. Using PlexiChore responsibly</h2>
        <ul>
          <li>Only use PlexiChore with computers and tablets you own or are allowed to use.</li>
          <li>Only approve connection requests from tablets you recognise.</li>
          <li>
            The Wi-Fi stream is not encrypted. Use a USB cable or a network you trust when your screen shows sensitive
            information.
          </li>
          <li>Follow the laws that apply to you and respect the rights in the content you display.</li>
        </ul>

        <h2>4. System changes and third-party components</h2>
        <p>
          To create extended and primary displays, PlexiChore changes your computer&apos;s display configuration and, on
          Windows, installs the open-source Virtual Display Driver (MIT license) with your administrator approval. The
          apps put your original display layout back when you disconnect. PlexiChore can also download Android
          platform-tools from Google. Third-party components are provided by their authors under their own licenses and
          terms.
        </p>

        <h2>5. No warranty</h2>
        <p>
          PlexiChore is provided <strong>&ldquo;as is&rdquo;</strong>, without warranty of any kind, express or implied,
          including the implied warranties of merchantability and fitness for a particular purpose, as set out in
          sections 15 and 16 of the GPL-3.0. We do not promise that it will work with every computer, tablet or
          network, or that it will be free of errors.
        </p>

        <h2>6. Limitation of liability</h2>
        <p>
          To the maximum extent permitted by law, PNT Apps is not liable for any damages arising from the use of, or
          inability to use, PlexiChore or this website — including lost data, lost work, or problems with your display
          configuration — even if we were told such damages were possible.
        </p>

        <h2>7. Trademarks</h2>
        <p>
          &ldquo;PNT Apps&rdquo;, &ldquo;PlexiChore&rdquo; and their logos and icons belong to PNT Apps. Windows, macOS,
          Android, Galaxy and S-Pen are trademarks of their respective owners; PlexiChore is not affiliated with or
          endorsed by them.
        </p>

        <h2>8. This website</h2>
        <p>
          The website is provided for information and to download PlexiChore. Links to third-party sites (such as
          GitHub) are subject to those sites&apos; own terms. See our <Link href="/privacy">Privacy Policy</Link> for how the
          website handles data.
        </p>

        <h2>9. Changes</h2>
        <p>
          We may update these terms. The date above shows the latest version. Continuing to use PlexiChore after a change
          means you accept the updated terms.
        </p>

        <h2>10. Governing law</h2>
        <p>These terms are governed by the laws of {site.company.country}.</p>

        <h2>11. Contact</h2>
        <p>
          Questions about these terms: <a href={`mailto:${site.company.email}`}>{site.company.email}</a>.
        </p>
      </div>
    </PageShell>
  );
}
