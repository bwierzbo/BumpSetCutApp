// push-message — Supabase Edge Function
//
// Fired by the `trg_push_on_message` AFTER INSERT trigger on public.messages
// (via pg_net; see migration 024). Sends an APNs alert to every device the
// recipient has registered.
//
// Auth is a shared secret, not a JWT: the trigger sends
// `Authorization: Bearer <vault:push_webhook_secret>` and this function
// compares it to PUSH_WEBHOOK_SECRET. verify_jwt is disabled.
//
// Message requests push too — a message from someone you don't follow still
// reaches you, with a title that says so rather than pretending you're already
// in a conversation.
//
// Secrets: PUSH_WEBHOOK_SECRET, APNS_KEY_ID, APNS_TEAM_ID, APNS_PRIVATE_KEY
// (the full .p8 contents), APNS_BUNDLE_ID.
//
// Deploy: supabase functions deploy push-message --no-verify-jwt

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";
import { importPKCS8, SignJWT } from "npm:jose@5";

const APNS_HOSTS = {
  production: "https://api.push.apple.com",
  sandbox: "https://api.sandbox.push.apple.com",
} as const;

type Environment = keyof typeof APNS_HOSTS;

interface MessageRecord {
  id: string;
  conversation_id: string;
  sender_id: string;
  recipient_id: string;
  body: string | null;
  attachment_type: "highlight" | "clip" | null;
}

// APNs provider tokens are valid for an hour and Apple rejects a *new* one
// issued more than once every 20 minutes, so it must be cached across
// invocations rather than signed per push.
let cachedToken: { jwt: string; issuedAt: number } | null = null;

async function providerToken(force = false): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  if (!force && cachedToken && now - cachedToken.issuedAt < 50 * 60) {
    return cachedToken.jwt;
  }
  const keyId = Deno.env.get("APNS_KEY_ID")!;
  const teamId = Deno.env.get("APNS_TEAM_ID")!;
  // Supabase secrets flatten newlines when pasted; restore them so the PEM parses.
  const pem = Deno.env.get("APNS_PRIVATE_KEY")!.replace(/\\n/g, "\n");
  const key = await importPKCS8(pem, "ES256");
  const jwt = await new SignJWT({ iss: teamId, iat: now })
    .setProtectedHeader({ alg: "ES256", kid: keyId })
    .sign(key);
  cachedToken = { jwt, issuedAt: now };
  return jwt;
}

function alertBody(record: MessageRecord): string {
  const text = record.body?.trim();
  if (text) return text.length > 140 ? `${text.slice(0, 139)}…` : text;
  return record.attachment_type === "highlight" ? "Sent a highlight" : "Sent a rally";
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") {
    return new Response(JSON.stringify({ error: "Method not allowed" }), {
      status: 405,
      headers: { "Content-Type": "application/json" },
    });
  }

  const expected = Deno.env.get("PUSH_WEBHOOK_SECRET");
  if (!expected || req.headers.get("Authorization") !== `Bearer ${expected}`) {
    return new Response(JSON.stringify({ error: "Unauthorized" }), {
      status: 401,
      headers: { "Content-Type": "application/json" },
    });
  }

  try {
    const payload = await req.json();
    const record = payload?.record as MessageRecord | undefined;
    if (!record?.recipient_id || !record.id) {
      return new Response(JSON.stringify({ error: "Malformed payload" }), {
        status: 400,
        headers: { "Content-Type": "application/json" },
      });
    }

    const admin = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );

    const [tokensResult, senderResult, memberResult, badgeResult] = await Promise.all([
      admin.from("device_tokens").select("token, environment").eq("user_id", record.recipient_id),
      admin.from("profiles").select("username").eq("id", record.sender_id).maybeSingle(),
      admin.from("conversation_members").select("status")
        .eq("conversation_id", record.conversation_id)
        .eq("user_id", record.recipient_id).maybeSingle(),
      admin.rpc("dm_unread_count_for", { p_user_id: record.recipient_id }),
    ]);

    const tokens = (tokensResult.data ?? []) as { token: string; environment: Environment }[];
    if (tokens.length === 0) {
      return new Response(JSON.stringify({ sent: 0, reason: "no devices" }), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      });
    }

    const username = senderResult.data?.username ?? "Someone";
    const isRequest = memberResult.data?.status === "pending";
    const apsPayload = JSON.stringify({
      aps: {
        alert: {
          title: isRequest ? `${username} wants to message you` : username,
          body: alertBody(record),
        },
        badge: typeof badgeResult.data === "number" ? badgeResult.data : undefined,
        sound: "default",
        "thread-id": record.conversation_id,
      },
      conversationId: record.conversation_id,
      messageId: record.id,
    });

    const bundleId = Deno.env.get("APNS_BUNDLE_ID")!;
    const stale: string[] = [];
    let sent = 0;

    const send = async (token: string, environment: Environment, jwt: string) =>
      await fetch(`${APNS_HOSTS[environment] ?? APNS_HOSTS.production}/3/device/${token}`, {
        method: "POST",
        headers: {
          authorization: `bearer ${jwt}`,
          "apns-topic": bundleId,
          "apns-push-type": "alert",
          "apns-priority": "10",
          // One banner per conversation — a burst of messages coalesces.
          "apns-collapse-id": `dm-${record.conversation_id}`.slice(0, 64),
          "content-type": "application/json",
        },
        body: apsPayload,
      });

    await Promise.all(tokens.map(async ({ token, environment }) => {
      try {
        let response = await send(token, environment, await providerToken());
        if (response.status === 403) {
          const reason = await response.clone().json().catch(() => null);
          if (reason?.reason === "ExpiredProviderToken") {
            response = await send(token, environment, await providerToken(true));
          }
        }
        if (response.ok) {
          sent += 1;
          return;
        }
        const reason = (await response.json().catch(() => null))?.reason;
        if (
          response.status === 410 ||
          ["BadDeviceToken", "Unregistered", "DeviceTokenNotForTopic"].includes(reason)
        ) {
          stale.push(token);
        } else {
          console.error(`APNs ${response.status} for ${token.slice(0, 8)}…: ${reason ?? "unknown"}`);
        }
      } catch (err) {
        console.error(`APNs request failed for ${token.slice(0, 8)}…:`, err);
      }
    }));

    if (stale.length > 0) {
      await admin.from("device_tokens").delete().in("token", stale);
    }

    return new Response(JSON.stringify({ sent, pruned: stale.length }), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });
  } catch (err) {
    console.error("push-message failed:", err);
    return new Response(JSON.stringify({ error: "Internal server error" }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }
});
