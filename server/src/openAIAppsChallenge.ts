import { notFound } from "./http";
import type { Env } from "./types";

// Serves the domain-control challenge used by OpenAI's plugin submission
// portal. The token belongs to a particular submission and deployment, so the
// route is generic while the value stays in deployment configuration.
//
// OpenAI requires the response body to contain only the exact token: no JSON,
// wrapper object, list, or explanatory text.
export async function handleOpenAIAppsChallenge(_req: Request, env: Env): Promise<Response> {
  const token = (env.OPENAI_APPS_CHALLENGE_TOKEN ?? "").trim();
  if (!token) return notFound();

  return new Response(token, {
    status: 200,
    headers: {
      "content-type": "text/plain; charset=utf-8",
      "cache-control": "no-store",
      "x-content-type-options": "nosniff",
    },
  });
}
