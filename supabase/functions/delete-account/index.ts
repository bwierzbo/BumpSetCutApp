// delete-account — Supabase Edge Function
//
// In-app account deletion (App Store Guideline 5.1.1(v)). Called from
// AuthenticationService.deleteAccount() with the user's Bearer token.
//   1. Revokes the app's Sign in with Apple tokens when the app sends a
//      fresh authorization code (Apple accounts confirm with Apple first —
//      codes are single-use and short-lived, so none is kept from sign-in).
//   2. Removes every storage file under the user's folder in each bucket
//      (recursively, past the 1000-per-page list limit).
//   3. Deletes the profile row (FK CASCADE takes highlights, likes,
//      comments, follows, reports, blocks, messages, testers and flywheel
//      contributions with it), then the auth user.
// Any failed step returns 500 so the app reports it instead of claiming
// success with data left behind.
//
// Apple revoke secrets (Supabase → Edge Functions → Secrets):
//   APPLE_TEAM_ID, APPLE_KEY_ID, APPLE_CLIENT_ID (the app's bundle id,
//   app.BumpSetCut), APPLE_PRIVATE_KEY (contents of the Sign in with Apple
//   .p8 key). Without them the revoke is skipped and logged — deletion still
//   proceeds.
//
// Deploy: supabase functions deploy delete-account
// Note: verify_jwt is disabled in the function config; auth is enforced
// manually below (missing header → 401, getUser() failure → 401).

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient, type SupabaseClient } from "jsr:@supabase/supabase-js@2";
import { importPKCS8, SignJWT } from "npm:jose@5";

const BUCKETS = ["videos", "avatars", "message-media", "training-data"];
const PAGE = 1000;

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

/** Every file path under `prefix` in `bucket`, descending into folders. */
async function listAll(admin: SupabaseClient, bucket: string, prefix: string): Promise<string[]> {
  const paths: string[] = [];
  for (let offset = 0; ; offset += PAGE) {
    const { data, error } = await admin.storage.from(bucket).list(prefix, { limit: PAGE, offset });
    if (error) throw new Error(`list ${bucket}/${prefix}: ${error.message}`);
    for (const item of data ?? []) {
      const path = `${prefix}/${item.name}`;
      // Folders come back without an id.
      if (item.id === null) paths.push(...await listAll(admin, bucket, path));
      else paths.push(path);
    }
    if (!data || data.length < PAGE) return paths;
  }
}

async function deleteStorage(admin: SupabaseClient, userId: string): Promise<void> {
  for (const bucket of BUCKETS) {
    const paths = await listAll(admin, bucket, userId);
    for (let i = 0; i < paths.length; i += PAGE) {
      const { error } = await admin.storage.from(bucket).remove(paths.slice(i, i + PAGE));
      if (error) throw new Error(`remove from ${bucket}: ${error.message}`);
    }
  }
}

/** Exchange the authorization code for a refresh token and revoke it. */
async function revokeApple(code: string): Promise<void> {
  const teamId = Deno.env.get("APPLE_TEAM_ID");
  const keyId = Deno.env.get("APPLE_KEY_ID");
  const clientId = Deno.env.get("APPLE_CLIENT_ID");
  const privateKey = Deno.env.get("APPLE_PRIVATE_KEY");
  if (!teamId || !keyId || !clientId || !privateKey) {
    console.warn("delete-account: Apple revoke skipped — APPLE_* secrets not set");
    return;
  }
  const clientSecret = await new SignJWT({})
    .setProtectedHeader({ alg: "ES256", kid: keyId })
    .setIssuer(teamId)
    .setIssuedAt()
    .setExpirationTime("5m")
    .setAudience("https://appleid.apple.com")
    .setSubject(clientId)
    .sign(await importPKCS8(privateKey.replace(/\\n/g, "\n"), "ES256"));

  const tokenResponse = await fetch("https://appleid.apple.com/auth/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      client_id: clientId,
      client_secret: clientSecret,
      code,
      grant_type: "authorization_code",
    }),
  });
  const tokens = await tokenResponse.json();
  if (!tokenResponse.ok || !tokens.refresh_token) {
    throw new Error(`Apple token exchange failed: ${tokens.error ?? tokenResponse.status}`);
  }

  const revokeResponse = await fetch("https://appleid.apple.com/auth/revoke", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      client_id: clientId,
      client_secret: clientSecret,
      token: tokens.refresh_token,
      token_type_hint: "refresh_token",
    }),
  });
  if (!revokeResponse.ok) throw new Error(`Apple revoke failed: ${revokeResponse.status}`);
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return json(405, { error: "Method not allowed" });

  const authHeader = req.headers.get("Authorization");
  if (!authHeader) return json(401, { error: "Missing authorization header" });

  const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

  // Authenticate the user from their JWT
  const userClient = createClient(supabaseUrl, serviceRoleKey, {
    global: { headers: { Authorization: authHeader } },
  });
  const { data: { user }, error: userError } = await userClient.auth.getUser();
  if (userError || !user) return json(401, { error: "Unable to authenticate user" });

  const admin = createClient(supabaseUrl, serviceRoleKey);
  const userId = user.id;
  let step = "read request";
  try {
    const body = await req.json().catch(() => ({}));
    if (typeof body.appleAuthorizationCode === "string") {
      step = "revoke Apple sign-in";
      await revokeApple(body.appleAuthorizationCode);
    }

    step = "delete storage files";
    await deleteStorage(admin, userId);

    step = "delete profile";
    const { error: profileError } = await admin.from("profiles").delete().eq("id", userId);
    if (profileError) throw new Error(profileError.message);

    step = "delete auth user";
    const { error: deleteError } = await admin.auth.admin.deleteUser(userId);
    if (deleteError) throw new Error(deleteError.message);

    return json(200, { success: true });
  } catch (err) {
    console.error(`delete-account: ${step} failed for ${userId}:`, err);
    return json(500, { error: `Couldn't ${step}. Nothing after that step was deleted — try again.` });
  }
});
