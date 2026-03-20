import { createEdgeHandler, jsonResponse, type EdgeContext } from "../_shared/edge-middleware.ts";
import { callClaudeMultiTurn, parseJsonResponse, type ClaudeMessage } from "../_shared/ai-helpers.ts";
import { trackAIUsage } from "../_shared/cost-tracking.ts";

const SYSTEM_PROMPT = `You are Campus Oracle, an expert college research assistant for IvyPi. You help students and families research universities with accurate, specific information.

You have access to:
1. Structured school data (acceptance rates, majors, rankings, etc.)
2. A curated URL index with verified links to school pages
3. Web search results with real URLs from the school's website

CRITICAL RULES:
- ALWAYS cite sources with URLs when making factual claims
- Only use URLs from the provided URL index or web search results — NEVER generate or guess URLs
- If you don't have a verified link, say "I don't have a verified link for this, but you can check [most relevant indexed page]"
- Personalize answers using the student's profile when relevant (interests, activities, narrative arc)
- Be specific and actionable, not generic brochure language
- When web search results are provided, prefer those URLs as they are current and verified

Output ONLY valid JSON:
{
  "answer": "Your response in markdown format",
  "sources": [
    { "url": "https://...", "title": "Page title" }
  ]
}`;

// Keywords that suggest we need live search beyond structured data
const SEARCH_TRIGGERS = [
  "program", "department", "professor", "faculty", "lab", "center",
  "policy", "requirement", "deadline", "event", "current", "this year",
  "how to", "apply", "process", "specific", "particular",
];

function shouldSearch(message: string): boolean {
  const lower = message.toLowerCase();
  return SEARCH_TRIGGERS.some((t) => lower.includes(t));
}

function extractDomain(url: string | null): string | null {
  if (!url) return null;
  try {
    const parsed = new URL(url.startsWith("http") ? url : `https://${url}`);
    return parsed.hostname.replace(/^www\./, "");
  } catch {
    return null;
  }
}

async function googleSearch(
  query: string,
  domain: string,
): Promise<{ title: string; link: string; snippet: string }[]> {
  const apiKey = Deno.env.get("GOOGLE_CSE_API_KEY");
  const cx = Deno.env.get("GOOGLE_CSE_CX") ?? "857d9580db6bc4329";

  if (!apiKey) {
    console.warn("GOOGLE_CSE_API_KEY not set — skipping web search");
    return [];
  }

  try {
    const params = new URLSearchParams({
      key: apiKey,
      cx,
      q: `site:${domain} ${query}`,
      num: "5",
    });

    const res = await fetch(
      `https://www.googleapis.com/customsearch/v1?${params}`,
    );

    if (!res.ok) {
      console.error(`Google CSE error (${res.status}):`, await res.text());
      return [];
    }

    const data = await res.json();
    return (data.items ?? []).map(
      (item: { title: string; link: string; snippet: string }) => ({
        title: item.title,
        link: item.link,
        snippet: item.snippet,
      }),
    );
  } catch (err) {
    console.error("Google search failed:", err);
    return [];
  }
}

Deno.serve(
  createEdgeHandler({
    requireAuth: true,
    handler: async (ctx: EdgeContext) => {
      const { student_id, school_name, message } = ctx.body as {
        student_id: string;
        school_name: string;
        message: string;
      };

      if (!student_id || !school_name || !message) {
        return jsonResponse({ error: "student_id, school_name, and message are required" }, 400);
      }

      // Access check
      const { data: student } = await ctx.supabase
        .from("students")
        .select("full_name, counselor_id, user_id")
        .eq("id", student_id)
        .single();

      if (!student) return jsonResponse({ error: "Student not found" }, 404);

      const { data: callerProfile } = await ctx.supabase
        .from("profiles")
        .select("role")
        .eq("id", ctx.callerId)
        .single();

      if (callerProfile?.role !== "admin") {
        const isParent = student.user_id === ctx.callerId;
        const isCounselor = student.counselor_id === ctx.callerId;
        if (!isParent && !isCounselor) {
          return jsonResponse({ error: "Not authorized for this student" }, 403);
        }
      }

      // Fetch or create conversation
      let { data: conversation } = await ctx.supabase
        .from("campus_oracle_conversations")
        .select("id, messages")
        .eq("student_id", student_id)
        .eq("school_name", school_name)
        .maybeSingle();

      if (!conversation) {
        const { data: newConv } = await ctx.supabase
          .from("campus_oracle_conversations")
          .insert({ student_id, school_name, messages: [] })
          .select("id, messages")
          .single();
        conversation = newConv;
      }

      if (!conversation) {
        return jsonResponse({ error: "Failed to create conversation" }, 500);
      }

      // Build context
      const [universityRes, urlIndexRes, narrativeRes] = await Promise.all([
        ctx.supabase.from("universities").select("*").eq("name", school_name).maybeSingle(),
        ctx.supabase.from("school_url_index").select("*").eq("school_name", school_name),
        ctx.supabase.from("narrative_arcs").select("arc").eq("student_id", student_id).eq("status", "idle").maybeSingle(),
      ]);

      const university = universityRes.data;
      const urlIndex = urlIndexRes.data ?? [];
      const narrativeArc = narrativeRes.data?.arc;

      // Fetch activities for student profile context
      const { data: activities } = await ctx.supabase
        .from("activities")
        .select("name, category, depth_tier")
        .eq("student_id", student_id)
        .order("sort_order")
        .limit(10);

      // Google search (if needed)
      let searchResults: { title: string; link: string; snippet: string }[] = [];
      if (shouldSearch(message)) {
        const domain = extractDomain(university?.url ?? null);
        if (domain) {
          searchResults = await googleSearch(message, domain);
        }
      }

      // Build conversation messages for Claude
      const existingMessages = (conversation.messages as { role: string; content: string }[]) ?? [];
      const recentMessages = existingMessages.slice(-14); // last 14 + new = 15

      const contextBlock = JSON.stringify({
        school: university ? {
          name: university.name,
          type: university.institution_type,
          city: university.city,
          state: university.state,
          acceptance_rates: university.acceptance_rates,
          undergraduate_size: university.undergraduate_size,
          us_news_ranking: university.us_news_ranking,
          majors: university.majors?.slice(0, 30),
          clubs: university.clubs?.slice(0, 20),
          research: university.research?.slice(0, 10),
          essay_hooks: university.essay_hooks,
        } : null,
        url_index: urlIndex.map((u: { page_type: string; url: string; label: string }) => ({
          type: u.page_type, url: u.url, label: u.label,
        })),
        student: {
          name: student.full_name,
          narrative: narrativeArc ? {
            throughlines: narrativeArc.throughlines,
            identity_frames: narrativeArc.identity_frames,
          } : null,
          top_activities: (activities ?? []).map((a: { name: string; category: string }) => `${a.name} (${a.category})`),
        },
        web_search_results: searchResults.length > 0 ? searchResults : undefined,
      });

      // Build Claude messages array
      const claudeMessages: ClaudeMessage[] = [];

      // Add context as first user message if this is a new conversation
      if (recentMessages.length === 0) {
        claudeMessages.push({
          role: "user",
          content: `Context about this school and student:\n${contextBlock}\n\nQuestion: ${message}`,
        });
      } else {
        // Replay history
        for (const msg of recentMessages) {
          claudeMessages.push({
            role: msg.role as "user" | "assistant",
            content: msg.content,
          });
        }
        // Always include context so Claude has school data even on follow-ups
        claudeMessages.push({
          role: "user",
          content: `Context:\n${contextBlock}\n\nQuestion: ${message}`,
        });
      }

      const result = await callClaudeMultiTurn(SYSTEM_PROMPT, claudeMessages, 4096);

      await trackAIUsage(ctx.supabase, {
        function_name: "campus-oracle",
        result,
        student_id,
        caller_id: ctx.callerId,
        metadata: { school_name },
      });

      // Parse response
      let answer: string;
      let sources: { url: string; title: string }[] = [];
      try {
        const parsed = parseJsonResponse<{
          answer: string;
          sources?: { url: string; title: string }[];
        }>(result.text);
        answer = parsed.answer;
        sources = parsed.sources ?? [];
      } catch {
        // If Claude didn't return valid JSON, use raw text
        answer = result.text;
      }

      const now = new Date().toISOString();
      const userMsg = { role: "user", content: message, timestamp: now };
      const assistantMsg = {
        role: "assistant",
        content: answer,
        sources: sources.length > 0 ? sources : undefined,
        timestamp: now,
      };

      // Append messages atomically via RPC (avoids read-modify-write race)
      await ctx.supabase.rpc("append_oracle_messages", {
        conv_id: conversation.id,
        new_messages: [userMsg, assistantMsg],
      });

      return { answer, sources };
    },
  }),
);
