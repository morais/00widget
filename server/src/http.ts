export function json(body: unknown, status = 200, headers: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json", ...headers },
  });
}

export function badRequest(message: string): Response {
  return json({ error: message }, 400);
}

export function notFound(): Response {
  return json({ error: "not found" }, 404);
}

export function unauthorized(message = "unauthorized"): Response {
  return json({ error: message }, 401);
}
