/**
 * Shared Claude API utilities for IvyPi edge functions.
 */

const ANTHROPIC_API_URL = "https://api.anthropic.com/v1/messages";
const DEFAULT_MODEL = "claude-sonnet-4-20250514";

export interface ClaudeMessage {
  role: "user" | "assistant";
  content: string | ClaudeContentBlock[];
}

export interface ClaudeContentBlock {
  type: "text" | "image" | "document";
  text?: string;
  source?: {
    type: "base64";
    media_type: string;
    data: string;
  };
}

export interface ClaudeResponse {
  content: { type: string; text: string }[];
  usage: { input_tokens: number; output_tokens: number };
}

export interface ClaudeResult {
  text: string;
  usage: { input_tokens: number; output_tokens: number };
  model: string;
}

/**
 * Call Claude API and return the text response with usage data.
 */
export async function callClaude(
  system: string,
  userContent: string | ClaudeContentBlock[],
  maxTokens = 4096,
  model = DEFAULT_MODEL,
): Promise<ClaudeResult> {
  const apiKey = Deno.env.get("ANTHROPIC_API_KEY");
  if (!apiKey) {
    throw new Error("ANTHROPIC_API_KEY not configured");
  }

  const messages: ClaudeMessage[] = [
    { role: "user", content: userContent },
  ];

  const response = await fetch(ANTHROPIC_API_URL, {
    method: "POST",
    headers: {
      "x-api-key": apiKey,
      "anthropic-version": "2023-06-01",
      "content-type": "application/json",
    },
    body: JSON.stringify({
      model,
      max_tokens: maxTokens,
      system,
      messages,
    }),
  });

  if (!response.ok) {
    const errorText = await response.text();
    throw new Error(`Claude API error (${response.status}): ${errorText}`);
  }

  const data: ClaudeResponse = await response.json();
  const textBlock = data.content.find((b) => b.type === "text");
  if (!textBlock?.text) {
    throw new Error("No text response from Claude");
  }

  return {
    text: textBlock.text,
    usage: data.usage,
    model,
  };
}

/**
 * Call Claude API with multi-turn conversation history.
 */
export async function callClaudeMultiTurn(
  system: string,
  messages: ClaudeMessage[],
  maxTokens = 4096,
  model = DEFAULT_MODEL,
): Promise<ClaudeResult> {
  const apiKey = Deno.env.get("ANTHROPIC_API_KEY");
  if (!apiKey) {
    throw new Error("ANTHROPIC_API_KEY not configured");
  }

  const response = await fetch(ANTHROPIC_API_URL, {
    method: "POST",
    headers: {
      "x-api-key": apiKey,
      "anthropic-version": "2023-06-01",
      "content-type": "application/json",
    },
    body: JSON.stringify({
      model,
      max_tokens: maxTokens,
      system,
      messages,
    }),
  });

  if (!response.ok) {
    const errorText = await response.text();
    throw new Error(`Claude API error (${response.status}): ${errorText}`);
  }

  const data: ClaudeResponse = await response.json();
  const textBlock = data.content.find((b) => b.type === "text");
  if (!textBlock?.text) {
    throw new Error("No text response from Claude");
  }

  return {
    text: textBlock.text,
    usage: data.usage,
    model,
  };
}

/**
 * Parse a JSON response from Claude, handling markdown code fences.
 */
export function parseJsonResponse<T>(text: string): T {
  // Strip markdown code fences if present
  let cleaned = text.trim();
  if (cleaned.startsWith("```")) {
    cleaned = cleaned.replace(/^```(?:json)?\s*\n?/, "").replace(/\n?```\s*$/, "");
  }
  return JSON.parse(cleaned);
}
