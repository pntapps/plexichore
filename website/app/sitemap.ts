import type { MetadataRoute } from "next";
import { site } from "@/lib/site";

export default function sitemap(): MetadataRoute.Sitemap {
  return ["", "/about", "/contact", "/privacy", "/terms"].map((path) => ({
    url: `${site.url}${path}`,
    changeFrequency: path === "" ? "weekly" : "yearly",
    priority: path === "" ? 1 : 0.5,
  }));
}
