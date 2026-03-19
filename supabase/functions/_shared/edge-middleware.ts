/**
 * Shared edge function middleware for IvyPi.
 * Handles CORS, Supabase client creation, auth, and role checks.
 */
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";

export const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

type UserRole = "student_parent" | "counselor" | "admin" | "pending_counselor";

export type EdgeContext = {
  /** Service-role Supabase client (bypasses RLS). Use for admin operations. */
  supabase: SupabaseClient;
  body: Record<string, unknown>;
  /** Set when requireAuth is true (or requireRole is set). */
  callerId?: string;
  /** Set only when requireRole is specified and the caller's role passes the check. */
  callerRole?: UserRole;
};

type HandlerResult = Response | Record<string, unknown>;

/**
 * Creates a Deno.serve-compatible handler with common middleware.
 *
 * Usage:
 *   Deno.serve(createEdgeHandler({
 *     requireRole: ["counselor", "admin"],
 *     handler: async (ctx) => {
 *       const { student_id } = ctx.body;
 *       // ... business logic ...
 *       return { success: true };
 *     },
 *   }));
 */
export function createEdgeHandler(opts: {
  /** Set to false to skip auth entirely (e.g. webhook handlers). Default: true */
  requireAuth?: boolean;
  /** If set, verifies the caller has one of these roles. Implies requireAuth. */
  requireRole?: UserRole[];
  handler: (ctx: EdgeContext) => Promise<HandlerResult>;
}): (req: Request) => Promise<Response> {
  return async (req: Request) => {
    if (req.method === "OPTIONS") {
      return new Response("ok", { headers: corsHeaders });
    }

    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    try {
      const body = await req.json();
      const ctx: EdgeContext = { supabase, body };

      // Authentication
      if (opts.requireAuth !== false) {
        const authHeader = req.headers.get("Authorization");
        if (!authHeader) {
          return jsonResponse({ error: "Missing authorization header" }, 401);
        }

        const token = authHeader.replace("Bearer ", "");
        const {
          data: { user },
          error: authError,
        } = await supabase.auth.getUser(token);
        if (authError || !user) {
          return jsonResponse({ error: "Invalid token" }, 401);
        }

        ctx.callerId = user.id;

        // Role authorization
        if (opts.requireRole) {
          const { data: profile } = await supabase
            .from("profiles")
            .select("id, role")
            .eq("id", user.id)
            .single();

          if (
            !profile ||
            !opts.requireRole.includes(profile.role as UserRole)
          ) {
            return jsonResponse(
              {
                error: `${opts.requireRole.join(" or ")} access required`,
              },
              403,
            );
          }

          ctx.callerRole = profile.role as UserRole;
        }
      }

      const result = await opts.handler(ctx);

      if (result instanceof Response) {
        return result;
      }

      return jsonResponse(result, 200);
    } catch (err) {
      console.error("Edge function error:", err);
      return jsonResponse(
        { error: "Internal server error", details: (err as Error).message },
        500,
      );
    }
  };
}

/** Helper to create a JSON response with CORS headers. */
export function jsonResponse(
  data: Record<string, unknown>,
  status = 200,
): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}
