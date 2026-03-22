import { callClaude, parseJsonResponse } from "../_shared/ai-helpers.ts";
import { createEdgeHandler, jsonResponse } from "../_shared/edge-middleware.ts";
import { trackAIUsage } from "../_shared/cost-tracking.ts";

// --- Grade context computation ---

type Urgency = "exploratory" | "building" | "positioning" | "finalizing";

function computeGradeContext(gradYear: number | null): {
  grad_year: number;
  current_grade: string;
  urgency: Urgency;
} {
  if (!gradYear) {
    return { grad_year: 0, current_grade: "Unknown", urgency: "building" };
  }

  const now = new Date();
  const currentYear = now.getFullYear();
  const currentMonth = now.getMonth(); // 0-indexed (0=Jan, 5=Jun, 7=Aug)
  const isSummer = currentMonth >= 5 && currentMonth <= 7; // June–August

  const yearsUntilGrad = gradYear - currentYear;

  if (currentMonth >= 5) {
    // After June — use "Rising" prefix for summer months
    if (yearsUntilGrad <= 0) {
      return { grad_year: gradYear, current_grade: "Graduated", urgency: "finalizing" };
    }
    if (yearsUntilGrad === 1 && isSummer) {
      return { grad_year: gradYear, current_grade: "Rising Senior", urgency: "positioning" };
    }
    if (yearsUntilGrad === 1) {
      return { grad_year: gradYear, current_grade: "Senior", urgency: "finalizing" };
    }
    if (yearsUntilGrad === 2 && isSummer) {
      return { grad_year: gradYear, current_grade: "Rising Junior", urgency: "building" };
    }
    if (yearsUntilGrad === 2) {
      return { grad_year: gradYear, current_grade: "Junior", urgency: "building" };
    }
    if (yearsUntilGrad === 3 && isSummer) {
      return { grad_year: gradYear, current_grade: "Rising Sophomore", urgency: "exploratory" };
    }
    if (yearsUntilGrad === 3) {
      return { grad_year: gradYear, current_grade: "Sophomore", urgency: "exploratory" };
    }
    return { grad_year: gradYear, current_grade: "Freshman", urgency: "exploratory" };
  } else {
    // Before June — in the school year
    if (yearsUntilGrad <= 0) {
      return { grad_year: gradYear, current_grade: "Senior", urgency: "finalizing" };
    }
    if (yearsUntilGrad === 1) {
      return { grad_year: gradYear, current_grade: "Junior", urgency: "building" };
    }
    if (yearsUntilGrad === 2) {
      return { grad_year: gradYear, current_grade: "Sophomore", urgency: "exploratory" };
    }
    return { grad_year: gradYear, current_grade: "Freshman", urgency: "exploratory" };
  }
}

// --- Survey data formatting ---

interface SurveyResponses {
  friendWords?: string[];
  reachFor?: string[];
  energy?: string[];
  proud?: string;
  selfTaught?: string;
  talkAbout?: string;
  unexpected?: string;
  googled?: string;
  ruleBreak?: string;
  selectedMoments?: string[];
  momentResponses?: Record<string, string>;
  songs?: string;
  photo?: string;
  insideJoke?: string;
  room?: string;
  assumption?: string;
  figuringOut?: string;
  oneHour?: string;
  freewrite?: string;
}

function formatSurveyContext(survey: SurveyResponses): string {
  const sections: string[] = [];

  if (survey.friendWords?.length) {
    sections.push(`Friends describe them as: ${survey.friendWords.join(", ")}`);
  }
  if (survey.reachFor?.length) {
    sections.push(`First instinct / reaches for: ${survey.reachFor.join(", ")}`);
  }
  if (survey.energy?.length) {
    sections.push(`Energy / comfort: ${survey.energy.join(", ")}`);
  }

  const finishLines: string[] = [];
  if (survey.proud) finishLines.push(`"The last time I felt really proud was when..." → ${survey.proud}`);
  if (survey.selfTaught) finishLines.push(`"Something I do that nobody taught me is..." → ${survey.selfTaught}`);
  if (survey.talkAbout) finishLines.push(`"I could talk for an hour about..." → ${survey.talkAbout}`);
  if (survey.unexpected) finishLines.push(`"People don't expect me to be..." → ${survey.unexpected}`);
  if (survey.googled) finishLines.push(`"The last thing I Googled that wasn't for school was..." → ${survey.googled}`);
  if (survey.ruleBreak) finishLines.push(`"A rule I always break is..." → ${survey.ruleBreak}`);
  if (finishLines.length) {
    sections.push(`Finish the Line:\n${finishLines.join("\n")}`);
  }

  if (survey.selectedMoments?.length && survey.momentResponses) {
    const moments = survey.selectedMoments
      .map((m) => survey.momentResponses?.[m] ? `${m}: ${survey.momentResponses[m]}` : null)
      .filter(Boolean);
    if (moments.length) {
      sections.push(`Defining Moments:\n${moments.join("\n")}`);
    }
  }

  const world: string[] = [];
  if (survey.songs) world.push(`Last 3 songs listened to: ${survey.songs}`);
  if (survey.photo) world.push(`Last camera roll photo: ${survey.photo}`);
  if (survey.insideJoke) world.push(`Inside joke: ${survey.insideJoke}`);
  if (survey.room) world.push(`Room/workspace: ${survey.room}`);
  if (world.length) {
    sections.push(`Their World:\n${world.join("\n")}`);
  }

  const real: string[] = [];
  if (survey.assumption) real.push(`Wrong assumption about them: ${survey.assumption}`);
  if (survey.figuringOut) real.push(`Still figuring out: ${survey.figuringOut}`);
  if (survey.oneHour) real.push(`"Most them" hour: ${survey.oneHour}`);
  if (real.length) {
    sections.push(`The Real Stuff:\n${real.join("\n")}`);
  }

  if (survey.freewrite) {
    sections.push(`Freewrite:\n${survey.freewrite}`);
  }

  return sections.join("\n\n");
}

// --- Main handler ---

Deno.serve(
  createEdgeHandler({
    requireRole: ["counselor", "admin"],
    handler: async (ctx) => {
      const { student_id } = ctx.body;
      if (!student_id) {
        return jsonResponse({ error: "student_id is required" }, 400);
      }

      // Fetch all student data
      const [studentRes, coursesRes, activitiesRes, awardsRes, collegeListRes] = await Promise.all([
        ctx.supabase.from("students").select("*").eq("id", student_id).single(),
        ctx.supabase
          .from("courses")
          .select("*")
          .eq("student_id", student_id)
          .order("year"),
        ctx.supabase
          .from("activities")
          .select("*")
          .eq("student_id", student_id)
          .order("name"),
        ctx.supabase
          .from("awards")
          .select("*")
          .eq("student_id", student_id)
          .order("sort_order"),
        ctx.supabase
          .from("college_lists")
          .select("school_name")
          .eq("student_id", student_id),
      ]);

      if (studentRes.error || !studentRes.data) {
        return jsonResponse({ error: "Student not found" }, 404);
      }

      const student = studentRes.data;
      const courses = coursesRes.data || [];
      const activities = activitiesRes.data || [];
      const awards = awardsRes.data || [];
      const collegeList = (collegeListRes.data || []).map((c: { school_name: string }) => c.school_name);

      // Compute grade context
      const gradeContext = computeGradeContext(student.grad_year);

      // Check for survey data
      const hasSurvey = !!student.survey_responses && !!student.survey_completed_at;
      const surveyContext = hasSurvey
        ? formatSurveyContext(student.survey_responses as SurveyResponses)
        : null;

      // Build context for Claude
      const studentContext = `
Student: ${student.full_name}
High School: ${student.high_school || "Unknown"}
Graduation Year: ${student.grad_year || "Unknown"}
Current Grade Level: ${gradeContext.current_grade}
Urgency Level: ${gradeContext.urgency}
GPA (Unweighted): ${student.gpa_unweighted ?? "N/A"}
GPA (Weighted): ${student.gpa_weighted ?? "N/A"}
Class Rank: ${student.class_rank || "N/A"}
Test Scores: ${JSON.stringify(student.test_scores || {})}

Courses (${courses.length} total):
${courses.map((c: { name: string; level?: string; subject_area?: string; grade?: string; year?: string }) => `- ${c.name} (${c.level || "regular"}, ${c.subject_area || "other"}) — Grade: ${c.grade || "N/A"}, Year: ${c.year || "N/A"}`).join("\n")}

Activities (${activities.length} total):
${activities.map((a: { name: string; category?: string; role?: string; hours_per_week?: number; years_active?: number[]; depth_tier?: string; impact_description?: string }) => `- ${a.name} (${a.category || "other"}) — Role: ${a.role || "N/A"}, Hours/week: ${a.hours_per_week || "N/A"}, Years: ${a.years_active?.join(",") || "N/A"}, Depth: ${a.depth_tier || "N/A"}\n  Impact: ${a.impact_description || "N/A"}`).join("\n")}

Awards (${awards.length} total):
${awards.map((w: { title: string; level?: string; category?: string; grade_year?: number; description?: string }) => `- ${w.title} (${w.level || "N/A"}, ${w.category || "N/A"}) — Grade: ${w.grade_year || "N/A"}${w.description ? `\n  ${w.description}` : ""}`).join("\n")}
${surveyContext ? `\n--- PERSONALITY & SURVEY DATA ---\n${surveyContext}` : "\n(No survey data available)"}
${collegeList.length > 0 ? `\nCollege List: ${collegeList.join(", ")}` : ""}`;

      const surveyInstruction = hasSurvey
        ? `The student has completed a personality survey. Use this survey data to:
- Weave personality insights into your strategic overview and strength/gap assessments
- Populate the "beyond_resume" section with 2-4 hidden interests, personality signals, or untapped hobbies you find in the survey data
- Each beyond_resume item should explain WHY the signal matters for applications and HOW to channel it
- The "signal_source" should name the survey question (e.g., "Camera roll photo", "Could talk for an hour about", "Most them hour", "Freewrite")`
        : `No survey data is available. Set "beyond_resume" to null. Do not invent personality details — only assess what is in the academic and activity data.`;

      const urgencyInstructions: Record<string, string> = {
        exploratory: `This student is a ${gradeContext.current_grade} — they have time. Your tone should be EXPLORATORY and ENCOURAGING. Focus on:
- Discovering what genuinely interests them
- Trying new activities and subjects to find their thread
- Building breadth before depth
- Suggesting activities that sound fun and identity-forming, not resume-optimizing
- "Try this because it sounds like you" not "Do this because colleges want it"`,
        building: `This student is a ${gradeContext.current_grade} — they're in the critical building phase. Your tone should be STRATEGIC BUT AUTHENTIC. Focus on:
- Consolidating interests into 1-2 clear narrative threads
- Deepening existing commitments (leadership roles, creating something new)
- Connecting seemingly separate activities into a coherent story
- Specific, named programs, competitions, and summer opportunities
- Building the evidence base for their strongest thread`,
        positioning: `This student is a ${gradeContext.current_grade} — applications are imminent. Your tone should be URGENT and POSITIONING-FOCUSED. Focus on:
- Maximizing what already exists rather than starting new things
- How to position their story for specific schools on their list
- Final leadership opportunities and external validation (awards, competitions)
- Essay angles that leverage their strongest threads
- Anything they can still realistically accomplish before applications open`,
        finalizing: `This student is a ${gradeContext.current_grade} — they're in the final stretch. Your tone should be FOCUSED and ESSAY-ORIENTED. Focus on:
- Maximizing the narrative from what exists — no new activities
- How to frame their story in the most compelling way
- Identifying their strongest essay material
- Addressing any remaining gaps through positioning, not new activities
- Making the most of what they have`,
      };

      const systemPrompt = `You are a senior admissions counselor with 20+ years of experience at top-30 programs. You've helped hundreds of students get into Harvard, Stanford, MIT, and every Ivy. You think strategically, speak plainly, and give advice that is bold, specific, and actionable.

You are generating a Strategic Briefing for a counselor reviewing this student's profile. This is NOT a rubric evaluation. This is your professional assessment — the kind of analysis you'd give a colleague before a strategy meeting.

${urgencyInstructions[gradeContext.urgency]}

${surveyInstruction}

IMPORTANT GUIDELINES:
- Synthesize, don't summarize. The counselor can already read the raw data. Connect dots they haven't seen.
- Speak plainly: "she hasn't started anything yet" not "leadership opportunities remain to be explored"
- Suggestions must name SPECIFIC programs, competitions, activities, or actions — never generic advice like "consider taking on a leadership role"
- Use **bold** markdown sparingly — only 1-2 key terms per narrative paragraph
- Each strength/gap should feel like a distinct insight, not a dimension to fill

Return ONLY valid JSON with this exact structure:
{
  "strategic_overview": "A 3-5 sentence paragraph capturing WHO this student is and what matters most right now. Reference their grade level. Weave in personality if survey data is available. This should read like the opening paragraph of a counselor's written assessment.",
  "grade_context": {
    "grad_year": ${gradeContext.grad_year || "null"},
    "current_grade": "${gradeContext.current_grade}",
    "urgency": "${gradeContext.urgency}"
  },
  "strengths": [
    {
      "title": "Short label (e.g., 'Environmental Science Thread')",
      "narrative": "1-3 sentences with evidence from academics, activities, AND personality/survey if available. Use **bold** sparingly.",
      "evidence": ["specific course name", "specific activity name", "specific survey signal"],
      "tier": "Compelling|Strong|Developing|Emerging"
    }
  ],
  "gaps": [
    {
      "title": "Short label (e.g., 'No Leadership or Initiative')",
      "narrative": "1-3 sentences explaining why this matters. Include a **bold** specific suggestion inline.",
      "suggestion": "One clear, actionable sentence naming a specific program, activity, or action",
      "tier": "Compelling|Strong|Developing|Emerging"
    }
  ],
  "beyond_resume": ${hasSurvey ? `[
    {
      "title": "Discovery label (e.g., 'Hidden Depth: Mycology Enthusiast')",
      "narrative": "What the signal is, why it matters for applications, and how to channel it into something visible",
      "signal_source": "Which survey question this came from"
    }
  ]` : "null"},
  "majors": [
    {
      "name": "Major/field name",
      "reasoning": "Why this fits. 1-2 sentences connecting their profile to this field."${collegeList.length > 0 ? `,
      "school_connections": ["School names from their college list strong in this area"]` : ""}
    }
  ],
  "next_steps": [
    {
      "action": "Concrete, specific instruction",
      "rationale": "Why this matters + which gap/strength it addresses",
      "priority": 1
    }
  ]
}

REQUIREMENTS:
- 2-4 strengths, ordered most compelling first
- 2-4 gaps, ordered most urgent first
- ${hasSurvey ? "2-4 beyond_resume items surfacing personality signals from the survey" : "beyond_resume must be null"}
- 2-4 major suggestions. The last one should be a "wildcard" — a less obvious connection. Note this in the reasoning (e.g., "Wildcard — connects...")
- 3-5 next_steps, numbered by priority
- Tier definitions: Compelling (exceptional, would stand out anywhere), Strong (competitive for top 30), Developing (good foundation, needs refinement), Emerging (early stage, significant development needed)`;

      const result = await callClaude(systemPrompt, studentContext, 6000);
      const rawInsights = parseJsonResponse<Record<string, unknown>>(result.text);

      // Validate against schema
      // Note: We import the schema shape inline to avoid Deno/Node module mismatch with Zod
      // The frontend Zod schema in profile-insights.ts is the source of truth
      const requiredKeys = ["strategic_overview", "grade_context", "strengths", "gaps", "majors", "next_steps"];
      const missingKeys = requiredKeys.filter((k) => !(k in rawInsights));
      if (missingKeys.length > 0) {
        return jsonResponse(
          { error: `Invalid response from AI: missing keys: ${missingKeys.join(", ")}` },
          500,
        );
      }

      // Track AI usage
      await trackAIUsage(ctx.supabase, {
        function_name: "generate-profile",
        result,
        student_id: student_id as string,
        caller_id: ctx.callerId,
      });

      // Save to student record and clear staleness flag
      await ctx.supabase
        .from("students")
        .update({
          profile_insights: rawInsights,
          profile_stale: false,
          profile_insights_generated_at: new Date().toISOString(),
        })
        .eq("id", student_id);

      // Fire-and-forget: generate scenario suggestions from new insights
      const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
      fetch(`${Deno.env.get("SUPABASE_URL")}/functions/v1/suggest-scenarios`, {
        method: "POST",
        headers: {
          Authorization: `Bearer ${serviceKey}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ student_id }),
      }).catch(() => {}); // Silent failure — suggestions are non-critical

      return { message: "Profile generated successfully" };
    },
  }),
);
