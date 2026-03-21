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

    // Send to Claude for unified extraction
    const systemPrompt = `You are a document parser for a college consulting platform. Extract ALL structured data from the student document — it may be a transcript, resume, activity list, or a combination.

Return ONLY valid JSON with this exact structure:
{
  "detected_types": ["transcript", "resume", "activity_list"],
  "profile": {
    "student_name": "string or null",
    "school_name": "string or null",
    "gpa_unweighted": number or null,
    "gpa_weighted": number or null,
    "class_rank": "string or null",
    "test_scores": {
      "sat_math": number or null,
      "sat_verbal": number or null,
      "act": number or null
    }
  },
  "courses": [
    {
      "name": "string",
      "course_type": "high_school|college|online",
      "subject_area": "math|science|english|history|foreign_language|arts|computer_science|social_science|other",
      "level": "regular|honors|ap|ib|dual_enrollment|other",
      "grade": "string (letter grade like A+, B, etc.) or null",
      "year": "string (e.g. 2023-24) or null",
      "semester": "string or null (e.g. Fall, Spring, S1, S2)"
    }
  ],
  "activities": [
    {
      "name": "string",
      "category": "academic|arts|athletics|community_service|leadership|work|research|other",
      "role": "string or null (e.g. President, Captain, Volunteer)",
      "years_active": [9, 10, 11] or null,
      "hours_per_week": number or null,
      "impact_description": "string or null",
      "resume_bullets": "string or null (preserve the EXACT bullet point text from the document, one bullet per line)",
      "depth_tier": "exceptional|strong|moderate|introductory"
    }
  ],
  "awards": [
    {
      "title": "string",
      "level": "international|national|state|regional|school" or null,
      "category": "stem|service|academic|arts|athletics|other" or null,
      "grade_year": number or null,
      "description": "string or null"
    }
  ]
}

Guidelines:
- detected_types: classify the document based on its PRIMARY purpose, not just what data happens to appear:
  - "transcript" = an official or unofficial school transcript — a document whose primary purpose is listing courses, grades, GPA, and academic records. It typically comes from a school or registrar.
  - "resume" = a student resume or CV — a document formatted as a resume whose primary purpose is summarizing activities, work experience, skills, and/or achievements. Even if it mentions GPA or coursework, classify it as "resume" if the format and purpose is a resume.
  - "activity_list" = a standalone list of extracurricular activities (not formatted as a resume).
  - A document should almost never be both "transcript" and "resume" — these are fundamentally different document types. Only include multiple types if the document truly contains separate sections that serve different purposes (e.g. a transcript stapled with an activity list).
  - If the document doesn't clearly fit any category, use an empty array [].
- Extract ALL courses, activities, and awards visible in the document regardless of detected_types
- Infer subject_area/level from course names (e.g. "AP Calculus BC" → math, ap)
- course_type: "college" for university/dual enrollment courses, "online" for online courses, "high_school" for everything else
- Infer activity category from context
- Use standard letter grades for course grades when possible
- For resume_bullets: copy the EXACT bullet point text from the document verbatim, one bullet per line (no leading dashes/dots). If the document has no bullet points for an activity, use null
- For depth_tier: exceptional = multi-year with state/national recognition, strong = sustained with leadership, moderate = regular participation, introductory = casual/short-term
- Return empty arrays for data types not present in the document
- Use null when uncertain rather than guessing`;

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
        text: "Parse this student document. Extract all available data: profile info, courses, activities, and awards. Return JSON only.",
      },
    ];

    const result = await callClaude(systemPrompt, userContent, 16384);
    const parsed = parseJsonResponse<{
      detected_types: string[];
      profile: {
        student_name: string | null;
        school_name: string | null;
        gpa_unweighted: number | null;
        gpa_weighted: number | null;
        class_rank: string | null;
        test_scores: {
          sat_math: number | null;
          sat_verbal: number | null;
          act: number | null;
        };
      };
      courses: Array<{
        name: string;
        course_type: string;
        subject_area: string;
        level: string;
        grade: string | null;
        year: string | null;
        semester: string | null;
      }>;
      activities: Array<{
        name: string;
        category: string;
        role: string | null;
        years_active: number[] | null;
        hours_per_week: number | null;
        impact_description: string | null;
        resume_bullets: string | null;
        depth_tier: string;
      }>;
      awards: Array<{
        title: string;
        level: string | null;
        category: string | null;
        grade_year: number | null;
        description: string | null;
      }>;
    }>(result.text);

    // Derive document type from detected_types
    const detectedTypes = parsed.detected_types ?? [];
    let docType = "document";
    if (detectedTypes.includes("transcript")) docType = "transcript";
    else if (detectedTypes.includes("resume")) docType = "resume";
    else if (detectedTypes.includes("activity_list")) docType = "activity_list";

    // Save parsed data to document — do NOT insert courses/activities/awards
    await supabase
      .from("documents")
      .update({ parsed_data: parsed, parse_status: "complete", type: docType })
      .eq("id", document_id);

    return new Response(
      JSON.stringify({
        message: "Document parsed successfully",
        data: parsed,
      }),
      { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );
  } catch (err) {
    console.error("parse-document error:", err);

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
