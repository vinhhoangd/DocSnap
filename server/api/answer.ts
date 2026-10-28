// DocSnap Answer API (Vercel Function).
//
// POST /api/answer  — the iPhone app sends a scanned page; Claude's answer streams back
//                     as NDJSON lines: {"type":"text","text":"..."} … {"type":"done",…}
// GET  /api/answer  — health check (does not touch the Anthropic API).
//
// The Anthropic API key lives only in this server's environment (ANTHROPIC_API_KEY).
// The app proves it is DocSnap with a shared secret header (x-docsnap-token == DOCSNAP_APP_TOKEN).
// Everything is in this one file so it runs both on Vercel and locally under Node's type stripping.

import Anthropic from "@anthropic-ai/sdk";
import { timingSafeEqual } from "node:crypto";

export const DEFAULT_MODEL = "claude-opus-5-5";

/** Models the app may request. Haiku has no server-side refusal fallback. */
export const ALLOWED_MODELS: Record<string, { fallbacks: boolean }> = {
  "claude-opus-5-5": { fallbacks: true },
  "claude-sonnet-5-5": { fallbacks: true },
  "claude-haiku-5-5": { fallbacks: false },
};

/** ~3.3 MB of base64 ≈ 2.5 MB JPEG; Vercel's request body limit is 4.5 MB. */
const MAX_IMAGE_BASE64 = 3_400_000;
const MAX_OCR_CHARS = 20_000;

export const SYSTEM_PROMPT = `You help a student with a photo of a paper page: homework, a worksheet, practice questions or notes. The image is the source of truth; OCR text, when given, may contain recognition errors.

Find every question or task on the page that has not been answered yet and answer each one. If the page contains no questions, say so in one sentence and briefly summarize what the page is about.

How to write the answer (it is shown in a phone app that renders simple Markdown but not LaTeX):
- Start each answer with a heading that names the question, like "### 1. Are v₁, v₂, v₃ linearly independent?"
- Put the final answer first, in bold, then the working a student needs to follow and check it.
- Write math in plain text with Unicode symbols (v₁, x², √, ≤, ≠, →, ×, ∈, ℝ³). Never use LaTeX or $ delimiters. Put each step of a calculation, vector or matrix on its own line.
- Use only ### headings, **bold**, *italics* and simple "-" or "1." lists. No tables, no code blocks.
- For essay, philosophy or other open questions, give a structured answer of a few short paragraphs: the main argument, supporting reasons, and a counterpoint.
- Answer in the language the questions are written in (Vietnamese questions get Vietnamese answers).
- If part of the page is unreadable, say which part and answer the rest.`;

export interface AnswerRequest {
  /** Base64 JPEG of the page (no data: prefix). */
  image: string;
  /** Optional on-device OCR text to help with small handwriting. */
  text?: string;
  model?: string;
}

export type AnswerEvent =
  | { type: "start"; model: string }
  | { type: "text"; text: string }
  | { type: "done"; stopReason: string | null; model: string; inputTokens: number; outputTokens: number }
  | { type: "error"; code: string; message: string };

/** Returns the parsed request, or an error message for a 400. */
export function parseAnswerRequest(body: unknown): AnswerRequest | string {
  if (typeof body !== "object" || body === null) return "Body must be a JSON object.";
  const { image, text, model } = body as Record<string, unknown>;
  if (typeof image !== "string" || image.length < 100) return "Missing page image.";
  if (image.length > MAX_IMAGE_BASE64) return "Page image is too large.";
  if (!/^[A-Za-z0-9+/]+={0,2}$/.test(image)) return "Page image must be plain base64.";
  if (text !== undefined && typeof text !== "string") return "text must be a string.";
  // Object.hasOwn: `in` would also accept inherited names like "toString" or "__proto__".
  if (model !== undefined && (typeof model !== "string" || !Object.hasOwn(ALLOWED_MODELS, model))) return "Unsupported model.";
  return {
    image,
    text: typeof text === "string" ? text.slice(0, MAX_OCR_CHARS) : undefined,
    model: typeof model === "string" ? model : undefined,
  };
}

/** Streams Claude's answer for one page as AnswerEvents. Never throws: errors become an "error" event. */
export async function* streamAnswer(
  client: Anthropic,
  request: AnswerRequest,
  signal?: AbortSignal,
): AsyncGenerator<AnswerEvent> {
  const model = request.model ?? DEFAULT_MODEL;
  const ocr = request.text?.trim();
  const prompt = ocr
    ? `Answer the unanswered questions on this page.\n\nOCR text of the page (may contain errors):\n${ocr}`
    : "Answer the unanswered questions on this page.";

  try {
    const stream = client.beta.messages.stream(
      {
        model,
        max_tokens: 16000,
        thinking: { type: "adaptive" },
        // Homework needs correct reasoning more than speed.
        output_config: { effort: "high" },
        // If a safety classifier wrongly declines a benign page, retry on Anthropic's recommended model.
        ...(ALLOWED_MODELS[model]?.fallbacks
          ? { betas: ["server-side-fallback-2026-07-01"], fallbacks: "default" as const }
          : {}),
        system: SYSTEM_PROMPT,
        messages: [
          {
            role: "user",
            content: [
              { type: "image", source: { type: "base64", media_type: "image/jpeg", data: request.image } },
              { type: "text", text: prompt },
            ],
          },
        ],
      },
      { signal },
    );

    yield { type: "start", model };
    for await (const event of stream) {
      if (event.type === "content_block_delta" && event.delta.type === "text_delta") {
        yield { type: "text", text: event.delta.text };
      }
    }
    const final = await stream.finalMessage();
    if (final.stop_reason === "refusal") {
      yield { type: "error", code: "refusal", message: "Claude declined to answer this page." };
      return;
    }
    yield {
      type: "done",
      stopReason: final.stop_reason,
      model: final.model,
      inputTokens: final.usage.input_tokens,
      outputTokens: final.usage.output_tokens,
    };
  } catch (error) {
    yield toErrorEvent(error);
  }
}

function toErrorEvent(error: unknown): AnswerEvent {
  // APIUserAbortError extends APIError, so check cancellation first.
  if (error instanceof Anthropic.APIUserAbortError || (error instanceof Error && error.name === "AbortError")) {
    return { type: "error", code: "cancelled", message: "Cancelled." };
  }
  if (error instanceof Anthropic.AuthenticationError || error instanceof Anthropic.PermissionDeniedError) {
    return { type: "error", code: "server_key", message: "The server's Claude API key is missing or invalid." };
  }
  if (error instanceof Anthropic.RateLimitError) {
    return { type: "error", code: "rate_limited", message: "Claude is busy right now. Try again in a minute." };
  }
  if (error instanceof Anthropic.BadRequestError) {
    return { type: "error", code: "bad_request", message: `Claude couldn't read this request: ${apiErrorText(error)}` };
  }
  if (error instanceof Anthropic.APIConnectionError) {
    return { type: "error", code: "connection", message: "The server couldn't reach Claude. Try again." };
  }
  if (error instanceof Anthropic.APIError) {
    return { type: "error", code: "api_error", message: `Claude API error ${error.status ?? ""}`.trim() };
  }
  return { type: "error", code: "server_error", message: "Something went wrong on the server." };
}

/** The human-readable part of an API error body ({"type":"error","error":{"message":"…"}}), not the raw JSON. */
function apiErrorText(error: InstanceType<typeof Anthropic.APIError>): string {
  const body = error.error as { error?: { message?: unknown }; message?: unknown } | undefined;
  const message = body?.error?.message ?? body?.message;
  return typeof message === "string" && message.length > 0 ? message : "the request was invalid.";
}

/** JSON.stringify leaves U+2028/U+2029/U+0085 raw; line readers (e.g. Swift's AsyncLineSequence) split on them. */
export function toNDJSONLine(value: unknown): string {
  return JSON.stringify(value).replace(/[\u2028\u2029\u0085]/g, (c) => `\\u${c.charCodeAt(0).toString(16).padStart(4, "0")}`) + "\n";
}

function tokenMatches(given: string | null, expected: string | undefined): boolean {
  if (!given || !expected) return false;
  const a = Buffer.from(given);
  const b = Buffer.from(expected);
  return a.length === b.length && timingSafeEqual(a, b);
}

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json", "cache-control": "no-store" },
  });
}

type Env = Record<string, string | undefined>;

export async function handleAnswer(request: Request, env: Env = process.env): Promise<Response> {
  if (!env.DOCSNAP_APP_TOKEN || !env.ANTHROPIC_API_KEY) {
    return json(503, { error: "not_configured", message: "Server is missing ANTHROPIC_API_KEY or DOCSNAP_APP_TOKEN." });
  }
  if (!tokenMatches(request.headers.get("x-docsnap-token"), env.DOCSNAP_APP_TOKEN)) {
    return json(401, { error: "unauthorized", message: "Unknown app token." });
  }
  let body: unknown;
  try {
    body = await request.json();
  } catch {
    return json(400, { error: "bad_json", message: "Body must be JSON." });
  }
  const parsed = parseAnswerRequest(body);
  if (typeof parsed === "string") return json(400, { error: "bad_request", message: parsed });

  const client = new Anthropic({ apiKey: env.ANTHROPIC_API_KEY, maxRetries: 2 });
  const encoder = new TextEncoder();
  const events = streamAnswer(client, parsed, request.signal);
  const stream = new ReadableStream<Uint8Array>({
    async pull(controller) {
      const { value, done } = await events.next();
      if (done) {
        controller.close();
        return;
      }
      controller.enqueue(encoder.encode(toNDJSONLine(value)));
    },
    async cancel() {
      await events.return(undefined);
    },
  });
  return new Response(stream, {
    status: 200,
    headers: {
      "content-type": "application/x-ndjson; charset=utf-8",
      "cache-control": "no-store",
      "x-accel-buffering": "no",
    },
  });
}

// Vercel Function entry points.
export async function POST(request: Request): Promise<Response> {
  return handleAnswer(request);
}

export function GET(): Response {
  const configured = Boolean(process.env.ANTHROPIC_API_KEY && process.env.DOCSNAP_APP_TOKEN);
  return json(200, { ok: true, service: "docsnap-answer", configured, defaultModel: DEFAULT_MODEL });
}
