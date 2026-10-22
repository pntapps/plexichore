/** Header band + readable column used by About, Contact, Privacy and Terms. */
export function PageShell({
  eyebrow,
  title,
  intro,
  children,
  wide = false,
}: {
  eyebrow: string;
  title: string;
  intro?: React.ReactNode;
  children: React.ReactNode;
  wide?: boolean;
}) {
  return (
    <>
      <section className="relative overflow-hidden border-b border-line pb-14 pt-32 sm:pt-36">
        <div className="grid-dots pointer-events-none absolute inset-0" />
        <div className="pointer-events-none absolute -top-32 left-1/2 h-[380px] w-[760px] -translate-x-1/2 rounded-full bg-violet/20 blur-[120px]" />
        <div className={`relative mx-auto px-4 sm:px-6 ${wide ? "max-w-6xl" : "max-w-3xl"}`}>
          <span className="eyebrow">{eyebrow}</span>
          <h1 className="mt-3 text-balance font-display text-4xl font-semibold tracking-tight sm:text-5xl">{title}</h1>
          {intro && <div className="mt-5 max-w-2xl text-lg leading-relaxed text-muted">{intro}</div>}
        </div>
      </section>
      <div className={`mx-auto px-4 py-14 sm:px-6 ${wide ? "max-w-6xl" : "max-w-3xl"}`}>{children}</div>
    </>
  );
}
