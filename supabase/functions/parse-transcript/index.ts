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
    const systemPrompt = `You are a transcript parser for a college consulting platform. Extract structured data from the student transcript image.

Return ONLY valid JSON with this exact structure:
{
  "student_name": "string or null",
  "school_name": "string or null",
  "gpa_unweighted": number or null,
  "gpa_weighted": number or null,
  "courses": [
    {
      "name": "string",
      "subject_area": "math|science|english|history|foreign_language|arts|computer_science|social_science|other",
      "level": "regular|honors|ap|ib|dual_enrollment|other",
      "grade": "string (letter grade like A+, B, etc.)",
      "year": "string (e.g. 2023-24)",
      "semester": "string or null (e.g. Fall, Spring, S1, S2)"
    }
  ]
}

Guidelines:
- Extract ALL courses visible on the transcript
- Infer subject_area from course name (e.g. "AP Calculus BC" → math, ap)
- Use standard letter grades when possible
- If GPA is shown, extract both weighted and unweighted if available
- If something is unclear, use null rather than guessing`;

    const userContent = [
      {
        type: "document" as const,
        source: {
          type: "base64" as const,
          media_type: "application/pdf",
          data: base64,
        },
      },
      {
        type: "text" as const,
        text: "Parse this student transcript. Extract the student name, school, GPAs, and all courses with their details. Return JSON only.",
      },
    ];

    const result = await callClaude(systemPrompt, userContent, 8192);
    const parsed = parseJsonResponse<{
      student_name: string | null;
      school_name: string | null;
      gpa_unweighted: number | null;
      gpa_weighted: number | null;
      courses: Array<{
        name: string;
        subject_area: string;
        level: string;
        grade: string;
        year: string;
        semester: string | null;
      }>;
    }>(result.text);

    // Save parsed data to document
    await supabase
      .from("documents")
      .update({ parsed_data: parsed, parse_status: "complete" })
      .eq("id", document_id);

    // Upsert student GPAs if extracted
    const studentUpdates: Record<string, unknown> = {};
    if (parsed.gpa_unweighted != null) studentUpdates.gpa_unweighted = parsed.gpa_unweighted;
    if (parsed.gpa_weighted != null) studentUpdates.gpa_weighted = parsed.gpa_weighted;
    if (parsed.student_name) studentUpdates.full_name = parsed.student_name;
    if (parsed.school_name) studentUpdates.high_school = parsed.school_name;

    if (Object.keys(studentUpdates).length > 0) {
      await supabase
        .from("students")
        .update(studentUpdates)
        .eq("id", doc.student_id);
    }

    // Insert courses (delete existing from this document first)
    await supabase.from("courses").delete().eq("document_id", document_id);

    if (parsed.courses?.length) {
      const courseRows = parsed.courses.map((c) => ({
        student_id: doc.student_id,
        document_id: document_id,
        name: c.name,
        subject_area: c.subject_area || null,
        level: c.level || "regular",
        grade: c.grade || null,
        year: c.year || null,
        semester: c.semester || null,
      }));

      await supabase.from("courses").insert(courseRows);
    }

    return new Response(
      JSON.stringify({
        message: "Transcript parsed successfully",
        courses_extracted: parsed.courses?.length || 0,
      }),
      { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );
  } catch (err) {
    console.error("parse-transcript error:", err);

    // Try to mark document as failed
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
