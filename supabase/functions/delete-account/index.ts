// delete-account — Supabase Edge Function (deployed: version 3)
//
// In-app account deletion (App Store Guideline 5.1.1(v)). Called from
// AuthenticationService.deleteAccount() with the user's Bearer token.
// Removes the user's storage files, profile row (FK CASCADE takes
// highlights, likes, comments, follows, reports, blocks and flywheel
// contributions with it), then the auth user itself.
//
// Deploy: supabase functions deploy delete-account
// Note: verify_jwt is disabled in the function config; auth is enforced
// manually below (missing header → 401, getUser() failure → 401).

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") {
    return new Response(JSON.stringify({ error: "Method not allowed" }), {
      status: 405,
      headers: { "Content-Type": "application/json" },
    });
  }

  const authHeader = req.headers.get("Authorization");
  if (!authHeader) {
    return new Response(JSON.stringify({ error: "Missing authorization header" }), {
      status: 401,
      headers: { "Content-Type": "application/json" },
    });
  }

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

    // Authenticate the user from their JWT
    const userClient = createClient(supabaseUrl, serviceRoleKey, {
      global: { headers: { Authorization: authHeader } },
    });

    const { data: { user }, error: userError } = await userClient.auth.getUser();
    if (userError || !user) {
      return new Response(JSON.stringify({ error: "Unable to authenticate user" }), {
        status: 401,
        headers: { "Content-Type": "application/json" },
      });
    }

    const adminClient = createClient(supabaseUrl, serviceRoleKey);
    const userId = user.id;

    // Clean up storage files before deleting DB records
    for (const bucket of ["videos", "avatars"]) {
      const { data: files } = await adminClient.storage
        .from(bucket)
        .list(userId, { limit: 1000 });

      if (files && files.length > 0) {
        const paths = files.map((f: { name: string }) => `${userId}/${f.name}`);
        await adminClient.storage.from(bucket).remove(paths);
      }
    }

    // Delete profile (CASCADE handles highlights, likes, comments, follows, reports, blocks)
    await adminClient.from("profiles").delete().eq("id", userId);

    // Delete the auth user
    const { error: deleteError } = await adminClient.auth.admin.deleteUser(userId);
    if (deleteError) {
      return new Response(JSON.stringify({ error: "Failed to delete account" }), {
        status: 500,
        headers: { "Content-Type": "application/json" },
      });
    }

    return new Response(JSON.stringify({ success: true }), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });
  } catch (err) {
    return new Response(JSON.stringify({ error: "Internal server error" }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }
});
