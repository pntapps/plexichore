import Link from "next/link";
import { ArrowLeft } from "lucide-react";

export default function NotFound() {
  return (
    <section className="relative grid min-h-[70vh] place-items-center overflow-hidden px-4 pt-24 text-center">
      <div className="grid-dots pointer-events-none absolute inset-0" />
      <div className="relative">
        <p className="font-display text-7xl font-semibold text-gradient">404</p>
        <h1 className="mt-4 font-display text-2xl font-semibold">This screen isn&apos;t connected</h1>
        <p className="mt-2 text-muted">The page you&apos;re looking for doesn&apos;t exist.</p>
        <Link href="/" className="btn-ghost mt-8">
          <ArrowLeft className="size-4" aria-hidden="true" /> Back to home
        </Link>
      </div>
    </section>
  );
}
