import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { callClaude, parseJsonResponse } from "../_shared/ai-helpers.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
  const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const supabase = createClient(supabaseUrl, supabaseServiceKey);

  try {
    const { document_id } = await req.json();
    if (!document_id) {
      return new Response(
        JSON.stringify({ error: "document_id is required" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    // Authenticate caller
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) {
      return new Response(
        JSON.stringify({ error: "Missing authorization header" }),
        { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    const token = authHeader.replace("Bearer ", "");
    const { data: { user: caller }, error: authError } = await supabase.auth.getUser(token);
    if (authError || !caller) {
      return new Response(
        JSON.stringify({ error: "Invalid token" }),
        { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    // Fetch the document record
    const { data: doc, error: docError } = await supabase
      .from("documents")
      .select("id, student_id, storage_path, type")
      .eq("id", document_id)
      .single();

    if (docError || !doc) {
      return new Response(
        JSON.stringify({ error: "Document not found" }),
        { status: 404, headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    // Set parse status to processing
    await supabase
      .from("documents")
      .update({ parse_status: "processing", parse_error: null })
      .eq("id", document_id);

    // Download PDF from storage
    const { data: fileData, error: downloadError } = await supabase.storage
      .from("student-documents")
      .download(doc.storage_path);

    if (downloadError || !fileData) {
      await supabase
        .from("documents")
        .update({ parse_status: "failed", parse_error: "Failed to download file" })
        .eq("id", document_id);
      return new Response(
        JSON.stringify({ error: "Failed to download file" }),
        { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    // Convert to base64 for Claude vision
    const arrayBuffer = await fileData.arrayBuffer();
    const base64 = btoa(
      new Uint8Array(arrayBuffer).reduce((data, byte) => data + String.fromCharCode(byte), ""),
    );

    // Send to Claude for extraction
    const systemPrompt = `You are an activities/resume parser for a college consulting platform. Extract structured extracurricular activity data from the document.

Return ONLY valid JSON with this exact structure:
{
  "activities": [
    {
      "name": "string",
      "category": "academic|arts|athletics|community_service|leadership|work|research|other",
      "role": "string or null (e.g. President, Captain, Volunteer)",
      "years_active": [9, 10, 11] (array of grade years as integers, or null),
      "hours_per_week": number or null,
      "impact_description": "string or null (brief description of impact/achievements)",
      "depth_tier": "exceptional|strong|moderate|introductory"
    }
  ]
}

Guidelines for depth_tier:
- exceptional: Multi-year commitment with significant achievements, leadership, or recognition at state/national level
- strong: Sustained involvement with clear growth, leadership roles, or notable impact
- moderate: Regular participation with some advancement or contribution
- introductory: Casual or short-term participation

Extract ALL activities visible in the document. Be thorough but accurate.`;

    const userContent = [
      {
        type: "image" as const,
        source: {
          type: "base64" as const,
          media_type: "application/pdf",
          data: base64,
        },
      },
      {
        type: "text" as const,
        text: "Parse this resume/activity list. Extract all extracurricular activities with details. Return JSON only.",
      },
    ];

    const response = await callClaude(systemPrompt, userContent, 8192);
    const parsed = parseJsonResponse<{
      activities: Array<{
        name: string;
        category: string;
        role: string | null;
        years_active: number[] | null;
        hours_per_week: number | null;
        impact_description: string | null;
        depth_tier: string;
      }>;
    }>(response);

    // Save parsed data to document
    await supabase
      .from("documents")
      .update({ parsed_data: parsed, parse_status: "complete" })
      .eq("id", document_id);

    // Insert activities (delete existing from this document first)
    await supabase.from("activities").delete().eq("document_id", document_id);

    if (parsed.activities?.length) {
      const activityRows = parsed.activities.map((a) => ({
        student_id: doc.student_id,
        document_id: document_id,
        name: a.name,
        category: a.category || "other",
        role: a.role || null,
        years_active: a.years_active || null,
        hours_per_week: a.hours_per_week || null,
        impact_description: a.impact_description || null,
        depth_tier: a.depth_tier || null,
      }));

      await supabase.from("activities").insert(activityRows);
    }

    return new Response(
      JSON.stringify({
        message: "Resume parsed successfully",
        activities_extracted: parsed.activities?.length || 0,
      }),
      { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );
  } catch (err) {
    console.error("parse-resume error:", err);

    try {
      const { document_id } = await req.clone().json();
      if (document_id) {
        await supabase
          .from("documents")
          .update({ parse_status: "failed", parse_error: (err as Error).message })
          .eq("id", document_id);
      }
    } catch { /* ignore */ }

    return new Response(
      JSON.stringify({ error: "Internal server error", details: (err as Error).message }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );
  }
});
