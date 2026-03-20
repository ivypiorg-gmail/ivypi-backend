import { createEdgeHandler, jsonResponse, type EdgeContext } from "../_shared/edge-middleware.ts";

const PAGE_TYPES = [
  { type: "admissions", query: "admissions", label: "Admissions" },
  { type: "apply", query: "how to apply undergraduate", label: "How to Apply" },
  { type: "financial_aid", query: "financial aid scholarships", label: "Financial Aid & Scholarships" },
  { type: "tuition", query: "tuition cost of attendance", label: "Tuition & Cost" },
  { type: "majors", query: "majors programs undergraduate", label: "Majors & Programs" },
  { type: "housing", query: "housing residential life", label: "Housing & Residential Life" },
  { type: "clubs", query: "student organizations clubs", label: "Student Organizations" },
  { type: "athletics", query: "athletics recreation", label: "Athletics & Recreation" },
  { type: "research", query: "undergraduate research opportunities", label: "Research Opportunities" },
  { type: "study_abroad", query: "study abroad programs", label: "Study Abroad" },
  { type: "career_services", query: "career services center", label: "Career Services" },
  { type: "campus_visit", query: "campus visit tour", label: "Campus Visits" },
];

function extractDomain(url: string | null): string | null {
  if (!url) return null;
  try {
    const parsed = new URL(url.startsWith("http") ? url : `https://${url}`);
    return parsed.hostname.replace(/^www\./, "");
  } catch {
    return null;
  }
}

async function searchForUrl(
  apiKey: string,
  cx: string,
  domain: string,
  query: string,
): Promise<{ url: string; title: string } | null> {
  try {
    const params = new URLSearchParams({
      key: apiKey,
      cx,
      q: `site:${domain} ${query}`,
      num: "1",
    });

    const res = await fetch(
      `https://www.googleapis.com/customsearch/v1?${params}`,
    );

    if (!res.ok) return null;

    const data = await res.json();
    const item = data.items?.[0];
    return item ? { url: item.link, title: item.title } : null;
  } catch {
    return null;
  }
}

Deno.serve(
  createEdgeHandler({
    requireRole: ["counselor", "admin"],
    handler: async (ctx: EdgeContext) => {
      const { school_names } = ctx.body as {
        school_names?: string[];
      };

      const apiKey = Deno.env.get("GOOGLE_CSE_API_KEY");
      const cx = Deno.env.get("GOOGLE_CSE_CX") ?? "857d9580db6bc4329";

      if (!apiKey) {
        return jsonResponse({ error: "GOOGLE_CSE_API_KEY not configured" }, 500);
      }

      // Get school list
      let schools: { name: string; url: string | null }[];
      if (school_names && school_names.length > 0) {
        const { data } = await ctx.supabase
          .from("universities")
          .select("name, url")
          .in("name", school_names);
        schools = data ?? [];
      } else {
        const { data } = await ctx.supabase
          .from("universities")
          .select("name, url")
          .limit(50);
        schools = data ?? [];
      }

      let seeded = 0;
      let skipped = 0;

      for (const school of schools) {
        const domain = extractDomain(school.url);
        if (!domain) {
          skipped++;
          continue;
        }

        // Check if already has URLs
        const { data: existing } = await ctx.supabase
          .from("school_url_index")
          .select("id")
          .eq("school_name", school.name)
          .limit(1);

        if (existing && existing.length > 0) {
          skipped++;
          continue;
        }

        // Search for each page type (sequential to respect rate limits)
        const rows: {
          school_name: string;
          page_type: string;
          url: string;
          label: string;
        }[] = [];

        for (const pt of PAGE_TYPES) {
          const result = await searchForUrl(apiKey, cx, domain, pt.query);
          if (result) {
            rows.push({
              school_name: school.name,
              page_type: pt.type,
              url: result.url,
              label: pt.label,
            });
          }
        }

        if (rows.length > 0) {
          await ctx.supabase
            .from("school_url_index")
            .upsert(rows, { onConflict: "school_name,page_type" });
          seeded++;
        }
      }

      return { seeded, skipped, total: schools.length };
    },
  }),
);
