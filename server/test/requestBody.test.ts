import { describe, expect, it } from "vitest";
import { readTextUpTo, RequestBodyTooLargeError } from "../src/requestBody";

describe("bounded request bodies", () => {
  it("stops reading a chunked body at the byte limit", async () => {
    let pulls = 0;
    let cancelled = false;
    const stream = new ReadableStream<Uint8Array>({
      pull(controller) {
        pulls++;
        controller.enqueue(new Uint8Array(4));
      },
      cancel() { cancelled = true; },
    });
    const req = new Request("https://api.test/", { method: "POST", body: stream, duplex: "half" } as RequestInit);

    await expect(readTextUpTo(req, 8)).rejects.toBeInstanceOf(RequestBodyTooLargeError);
    expect(pulls).toBeLessThanOrEqual(4);
    expect(cancelled).toBe(true);
  });

  it("counts UTF-8 bytes and accepts a body at the limit", async () => {
    const exact = new Request("https://api.test/", { method: "POST", body: "é" });
    expect(await readTextUpTo(exact, 2)).toBe("é");

    const oversized = new Request("https://api.test/", { method: "POST", body: "é" });
    await expect(readTextUpTo(oversized, 1)).rejects.toBeInstanceOf(RequestBodyTooLargeError);
  });
});
