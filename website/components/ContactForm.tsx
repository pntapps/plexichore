"use client";

import { useState } from "react";
import { Send } from "lucide-react";
import { site } from "@/lib/site";

const topics = [
  { value: "support", label: "Help with PlexiChore", to: site.company.supportEmail },
  { value: "bug", label: "Report a bug", to: site.company.supportEmail },
  { value: "feedback", label: "Feedback or idea", to: site.company.supportEmail },
  { value: "business", label: "Business or press", to: site.company.email },
] as const;

/**
 * No backend: the form composes an email in the visitor's own mail app (mailto:), so nothing is stored or sent by
 * this website.
 */
export function ContactForm() {
  const [topic, setTopic] = useState<(typeof topics)[number]["value"]>("support");
  const [name, setName] = useState("");
  const [device, setDevice] = useState("");
  const [message, setMessage] = useState("");

  const onSubmit = (e: React.FormEvent) => {
    e.preventDefault();
    const t = topics.find((x) => x.value === topic)!;
    const subject = `PlexiChore: ${t.label}${name ? ` — ${name}` : ""}`;
    const body = `${message.trim()}\n\n${device ? `Devices: ${device}\n` : ""}${name ? `— ${name}` : ""}`.trim();
    window.location.href = `mailto:${t.to}?subject=${encodeURIComponent(subject)}&body=${encodeURIComponent(body)}`;
  };

  const field =
    "mt-2 w-full rounded-xl border border-white/10 bg-ink-900/80 px-4 py-3 text-fg placeholder:text-subtle outline-none transition focus:border-violet/60 focus:ring-2 focus:ring-violet/30";

  return (
    <form onSubmit={onSubmit} className="glass rounded-3xl p-6 sm:p-8">
      <div className="grid gap-5 sm:grid-cols-2">
        <label className="block text-sm font-medium text-fg">
          Your name
          <input className={field} value={name} onChange={(e) => setName(e.target.value)} placeholder="Optional" autoComplete="name" />
        </label>
        <label className="block text-sm font-medium text-fg">
          Topic
          <select className={field} value={topic} onChange={(e) => setTopic(e.target.value as typeof topic)}>
            {topics.map((t) => (
              <option key={t.value} value={t.value}>
                {t.label}
              </option>
            ))}
          </select>
        </label>
      </div>
      <label className="mt-5 block text-sm font-medium text-fg">
        Your devices
        <input
          className={field}
          value={device}
          onChange={(e) => setDevice(e.target.value)}
          placeholder="e.g. Windows 11 PC + Galaxy Tab S8 (helps us help you)"
        />
      </label>
      <label className="mt-5 block text-sm font-medium text-fg">
        Message
        <textarea
          className={`${field} min-h-36 resize-y`}
          value={message}
          onChange={(e) => setMessage(e.target.value)}
          placeholder="How can we help?"
          required
        />
      </label>
      <div className="mt-6 flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between">
        <p className="text-xs leading-relaxed text-subtle">
          Opens your email app with the message ready to send. Nothing is stored by this website.
        </p>
        <button type="submit" className="btn-primary shrink-0 justify-center">
          <Send className="size-4" aria-hidden="true" /> Write email
        </button>
      </div>
    </form>
  );
}
