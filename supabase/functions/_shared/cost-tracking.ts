/**
 * AI usage cost tracking for IvyPi edge functions.
 * Logs token usage and estimated cost to the ai_usage_log table.
 */
import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";
import type { ClaudeResult } from "./ai-helpers.ts";

// Approximate pricing per million tokens
const MODEL_PRICING: Record<string, { input: number; output: number }> = {
  "claude-sonnet-4-20250514": { input: 3, output: 15 },
  "claude-haiku-4-5-20251001": { input: 0.8, output: 4 },
  "claude-opus-4-6-20250619": { input: 15, output: 75 },
};

/**
 * Log AI usage to the ai_usage_log table. Failures are logged but never thrown.
 */
export async function trackAIUsage(
  supabase: SupabaseClient,
  opts: {
    function_name: string;
    result: ClaudeResult;
    student_id?: string;
    school_id?: string;
    caller_id?: string;
    metadata?: Record<string, unknown>;
  },
): Promise<void> {
  const pricing = MODEL_PRICING[opts.result.model] || { input: 3, output: 15 };
  const costUsd =
    (opts.result.usage.input_tokens * pricing.input +
      opts.result.usage.output_tokens * pricing.output) /
    1_000_000;

  const { error } = await supabase.from("ai_usage_log").insert({
    function_name: opts.function_name,
    student_id: opts.student_id || null,
    school_id: opts.school_id || null,
    model: opts.result.model,
    input_tokens: opts.result.usage.input_tokens,
    output_tokens: opts.result.usage.output_tokens,
    cost_usd: costUsd,
    caller_id: opts.caller_id || null,
    metadata: opts.metadata || {},
  });

  if (error) {
    console.error("Failed to track AI usage:", error);
  }
}
