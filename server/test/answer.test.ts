// Tests for the DocSnap Answer server. Run from the repo root with `node --test server/test/`
// (or `npm test` in server/). They never reach the Anthropic API: streamAnswer gets a fake client,
// and the end-to-end handleAnswer tests replace globalThis.fetch and point the SDK at 127.0.0.1.

import { test, describe, beforeEach, afterEach } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import Anthropic from "@anthropic-ai/sdk";
import {
  ALLOWED_MODELS,
  DEFAULT_MODEL,
  GET,
  POST,
  handleAnswer,
  parseAnswerRequest,
  streamAnswer,
  type AnswerEvent,
  type AnswerRequest,
} from "../api/answer.ts";

// MARK: - Helpers

/** Plain base64 of a fake JPEG, long enough to pass the size check. */
const IMAGE = Buffer.from("\xFF\xD8" + "fake jpeg bytes ".repeat(40), "latin1").toString("base64");
const TOKEN = "test-app-token-0123456789";
const ENV = { DOCSNAP_APP_TOKEN: TOKEN, ANTHROPIC_API_KEY: "sk-ant-test-not-a-real-key" };

function message(overrides: Record<string, unknown> = {}) {
  return {
    id: "msg_test",
    type: "message",
    role: "assistant",
    model: "claude-opus-5-5",
    content: [],
    stop_reason: "end_turn",
    stop_sequence: null,
    usage: { input_tokens: 1200, output_tokens: 34 },
    ...overrides,
  };
}

function textDelta(text: string) {
  return { type: "content_block_delta", index: 0, delta: { type: "text_delta", text } };
}

interface FakeCall {
  params: Record<string, any>;
  options: { signal?: AbortSignal } | undefined;
}

/**
 * A stand-in for `new Anthropic()`: `beta.messages.stream()` returns an async-iterable of SSE-like
 * events plus `finalMessage()`. `throwAfter` makes the iterator throw once the events run out.
 */
function fakeClient(opts: {
  events?: unknown[];
  final?: Record<string, unknown>;
  throwAfter?: unknown;
  throwOnCreate?: unknown;
  waitForAbort?: boolean;
} = {}) {
  const calls: FakeCall[] = [];
  const client = {
    beta: {
      messages: {
        stream(params: Record<string, any>, options?: { signal?: AbortSignal }) {
          calls.push({ params, options });
          if (opts.throwOnCreate) throw opts.throwOnCreate;
          return {
            async *[Symbol.asyncIterator]() {
              for (const event of opts.events ?? []) yield event;
              if (opts.waitForAbort) {
                const signal = options?.signal;
                await new Promise<void>((resolve) => {
                  if (signal?.aborted) resolve();
                  signal?.addEventListener("abort", () => resolve(), { once: true });
                });
                // What the SDK's MessageStream throws when its signal aborts.
                throw new Anthropic.APIUserAbortError();
              }
              if (opts.throwAfter) throw opts.throwAfter;
            },
            async finalMessage() {
              return message(opts.final);
            },
          };
        },
      },
    },
  };
  return { client: client as unknown as Anthropic, calls };
}

async function collect(gen: AsyncGenerator<AnswerEvent>): Promise<AnswerEvent[]> {
  const out: AnswerEvent[] = [];
  for await (const event of gen) out.push(event);
  return out;
}

function request(body: unknown, headers: Record<string, string> = { "x-docsnap-token": TOKEN }, signal?: AbortSignal) {
  return new Request("https://docsnap.test/api/answer", {
    method: "POST",
    headers: { "content-type": "application/json", ...headers },
    body: typeof body === "string" ? body : JSON.stringify(body),
    signal,
  });
}

async function readNDJSON(response: Response): Promise<any[]> {
  const text = await response.text();
  assert.ok(text.endsWith("\n"), "every NDJSON line ends with a newline");
  return text.trimEnd().split("\n").map((line) => JSON.parse(line));
}

// MARK: - parseAnswerRequest

describe("parseAnswerRequest", () => {
  test("accepts a minimal request", () => {
    assert.deepEqual(parseAnswerRequest({ image: IMAGE }), { image: IMAGE, text: undefined, model: undefined });
  });

  test("accepts every allowed model and OCR text", () => {
    for (const model of Object.keys(ALLOWED_MODELS)) {
      assert.deepEqual(parseAnswerRequest({ image: IMAGE, text: "1. x² = 4", model }), { image: IMAGE, text: "1. x² = 4", model });
    }
  });

  test("rejects non-object bodies", () => {
    for (const body of [null, undefined, "str", 42, true]) {
      assert.equal(parseAnswerRequest(body), "Body must be a JSON object.");
    }
  });

  test("rejects a missing, short, huge or non-base64 image", () => {
    assert.equal(parseAnswerRequest({}), "Missing page image.");
    assert.equal(parseAnswerRequest({ image: 123 }), "Missing page image.");
    assert.equal(parseAnswerRequest({ image: "QUJD" }), "Missing page image.");
    assert.equal(parseAnswerRequest({ image: "A".repeat(3_400_001) }), "Page image is too large.");
    assert.equal(parseAnswerRequest({ image: "data:image/jpeg;base64," + IMAGE }), "Page image must be plain base64.");
    assert.equal(parseAnswerRequest({ image: IMAGE.slice(0, 80) + "\n" + IMAGE.slice(80) }), "Page image must be plain base64.");
    assert.equal(parseAnswerRequest({ image: IMAGE + "===" }), "Page image must be plain base64.");
  });

  test("accepts an image right at the size limit", () => {
    const parsed = parseAnswerRequest({ image: "A".repeat(3_400_000) });
    assert.equal(typeof parsed, "object");
  });

  test("rejects non-string text", () => {
    assert.equal(parseAnswerRequest({ image: IMAGE, text: 5 }), "text must be a string.");
    assert.equal(parseAnswerRequest({ image: IMAGE, text: null }), "text must be a string.");
  });

  test("caps OCR text at 20,000 characters", () => {
    const parsed = parseAnswerRequest({ image: IMAGE, text: "x".repeat(25_000) });
    assert.equal(typeof parsed, "object");
    assert.equal((parsed as AnswerRequest).text?.length, 20_000);
  });

  test("rejects unsupported models", () => {
    for (const model of ["claude-3-opus", "gpt-4o", "", 7, "CLAUDE-OPUS-5-5"]) {
      assert.equal(parseAnswerRequest({ image: IMAGE, model }), "Unsupported model.", `model ${JSON.stringify(model)}`);
    }
  });

  test("rejects Object.prototype names as models", () => {
    // Regression: `model in ALLOWED_MODELS` used to accept inherited keys and forward them to Claude.
    for (const model of ["toString", "constructor", "__proto__", "hasOwnProperty"]) {
      assert.equal(parseAnswerRequest({ image: IMAGE, model }), "Unsupported model.", `model ${model}`);
    }
  });
});

// MARK: - Swift <-> server contract

test("the app's AnswerModel raw values are exactly the server's allowed models", () => {
  const swift = readFileSync(new URL("../../DocSnap/Services/AnswerService.swift", import.meta.url), "utf8");
  const enumBody = swift.slice(swift.indexOf("enum AnswerModel"), swift.indexOf("var id: String"));
  const raw = [...enumBody.matchAll(/case \w+ = "([^"]+)"/g)].map((m) => m[1]);
  assert.ok(raw.length >= 3, "found the Swift model cases");
  assert.deepEqual(raw.sort(), Object.keys(ALLOWED_MODELS).sort());
  assert.ok(raw.includes(DEFAULT_MODEL));
});

// MARK: - streamAnswer (fake client)

describe("streamAnswer", () => {
  test("streams start, text and done events", async () => {
    const { client } = fakeClient({
      events: [
        { type: "message_start", message: message() },
        { type: "content_block_start", index: 0, content_block: { type: "thinking", thinking: "" } },
        { type: "content_block_delta", index: 0, delta: { type: "thinking_delta", thinking: "secret reasoning" } },
        textDelta("### 1. Q\n"),
        textDelta("**x = 2**"),
        { type: "message_delta", delta: { stop_reason: "end_turn" }, usage: { output_tokens: 34 } },
        { type: "message_stop" },
      ],
      final: { model: "claude-opus-5-5", stop_reason: "end_turn", usage: { input_tokens: 1200, output_tokens: 34 } },
    });
    const events = await collect(streamAnswer(client, { image: IMAGE }));
    assert.deepEqual(events, [
      { type: "start", model: "claude-opus-5-5" },
      { type: "text", text: "### 1. Q\n" },
      { type: "text", text: "**x = 2**" },
      { type: "done", stopReason: "end_turn", model: "claude-opus-5-5", inputTokens: 1200, outputTokens: 34 },
    ]);
    assert.ok(!JSON.stringify(events).includes("secret reasoning"), "thinking is never sent to the app");
  });

  test("done reports the model that actually answered (e.g. after a fallback)", async () => {
    const { client } = fakeClient({ events: [textDelta("hi")], final: { model: "claude-fallback-model" } });
    const events = await collect(streamAnswer(client, { image: IMAGE, model: "claude-sonnet-5-5" }));
    assert.deepEqual(events[0], { type: "start", model: "claude-sonnet-5-5" });
    assert.equal((events.at(-1) as any).model, "claude-fallback-model");
  });

  test("max_tokens is passed through so the app can say the answer was cut off", async () => {
    const { client } = fakeClient({ events: [textDelta("long…")], final: { stop_reason: "max_tokens" } });
    const events = await collect(streamAnswer(client, { image: IMAGE }));
    assert.equal((events.at(-1) as any).stopReason, "max_tokens");
  });

  test("a refusal becomes an error event instead of done", async () => {
    const { client } = fakeClient({ events: [textDelta("I can")], final: { stop_reason: "refusal" } });
    const events = await collect(streamAnswer(client, { image: IMAGE }));
    assert.deepEqual(events.at(-1), { type: "error", code: "refusal", message: "Claude declined to answer this page." });
    assert.ok(!events.some((e) => e.type === "done"));
  });

  test("sends the image, prompt and system prompt", async () => {
    const { client, calls } = fakeClient();
    await collect(streamAnswer(client, { image: IMAGE }));
    assert.equal(calls.length, 1);
    const { params } = calls[0];
    assert.equal(params.model, DEFAULT_MODEL, "defaults to Opus");
    assert.ok(params.max_tokens > 0);
    assert.equal(typeof params.system, "string");
    const [msg] = params.messages;
    assert.equal(msg.role, "user");
    assert.deepEqual(msg.content[0], { type: "image", source: { type: "base64", media_type: "image/jpeg", data: IMAGE } });
    assert.equal(msg.content[1].type, "text");
    assert.ok(!msg.content[1].text.includes("OCR"), "no OCR section without OCR text");
  });

  test("OCR text is trimmed and added to the prompt; blank OCR text is ignored", async () => {
    const withText = fakeClient();
    await collect(streamAnswer(withText.client, { image: IMAGE, text: "  1. Solve x² = 4 \n" }));
    const prompt = withText.calls[0].params.messages[0].content[1].text as string;
    assert.ok(prompt.includes("OCR"));
    assert.ok(prompt.endsWith("1. Solve x² = 4"));

    const blank = fakeClient();
    await collect(streamAnswer(blank.client, { image: IMAGE, text: "   \n " }));
    assert.ok(!blank.calls[0].params.messages[0].content[1].text.includes("OCR"));
  });

  test("server-side fallbacks are requested only for Opus and Sonnet", async () => {
    for (const model of Object.keys(ALLOWED_MODELS)) {
      const { client, calls } = fakeClient();
      await collect(streamAnswer(client, { image: IMAGE, model }));
      const { params } = calls[0];
      assert.equal(params.model, model);
      if (model === "claude-haiku-5-5") {
        assert.ok(!("fallbacks" in params), "Haiku has no fallbacks");
        assert.ok(!("betas" in params), "Haiku sends no fallback beta");
      } else {
        assert.ok(model.includes("opus") || model.includes("sonnet"));
        assert.equal(params.fallbacks, "default", `${model} asks for fallbacks`);
        assert.ok(Array.isArray(params.betas) && params.betas.some((b: string) => b.startsWith("server-side-fallback")),
          `${model} sends the fallback beta`);
      }
    }
  });

  test("passes the abort signal to the SDK", async () => {
    const { client, calls } = fakeClient();
    const controller = new AbortController();
    await collect(streamAnswer(client, { image: IMAGE }, controller.signal));
    assert.equal(calls[0].options?.signal, controller.signal);
  });

  test("aborting mid-stream ends with a cancelled event", async () => {
    // Regression: APIUserAbortError extends APIError and used to be reported as "api_error".
    const controller = new AbortController();
    const { client } = fakeClient({ events: [textDelta("partial")], waitForAbort: true });
    const events: AnswerEvent[] = [];
    for await (const event of streamAnswer(client, { image: IMAGE }, controller.signal)) {
      events.push(event);
      if (event.type === "text") controller.abort();
    }
    assert.deepEqual(events.slice(0, 2), [{ type: "start", model: DEFAULT_MODEL }, { type: "text", text: "partial" }]);
    assert.deepEqual(events.at(-1), { type: "error", code: "cancelled", message: "Cancelled." });
  });

  test("a DOM AbortError also maps to cancelled", async () => {
    const { client } = fakeClient({ throwAfter: new DOMException("The operation was aborted.", "AbortError") });
    const events = await collect(streamAnswer(client, { image: IMAGE }));
    assert.deepEqual(events.at(-1), { type: "error", code: "cancelled", message: "Cancelled." });
  });

  test("never throws: SDK errors become error events with friendly codes", async () => {
    const headers = new Headers();
    // The SDK builds error.message from the API's JSON error body.
    const body = (type: string, msg = "x") => ({ type: "error", error: { type, message: msg } });
    const cases: [unknown, string, RegExp][] = [
      [new Anthropic.AuthenticationError(401, body("authentication_error"), "invalid x-api-key", headers), "server_key", /API key/],
      [new Anthropic.PermissionDeniedError(403, body("permission_error"), "denied", headers), "server_key", /API key/],
      [new Anthropic.RateLimitError(429, body("rate_limit_error"), "rate limited", headers), "rate_limited", /busy/i],
      [new Anthropic.BadRequestError(400, body("invalid_request_error", "Could not process image"), undefined, headers), "bad_request",
        /^Claude couldn't read this request: Could not process image$/],
      [new Anthropic.APIConnectionError({ message: "ECONNRESET" }), "connection", /couldn't reach Claude/],
      [new Anthropic.APIConnectionTimeoutError(), "connection", /couldn't reach Claude/],
      [new Anthropic.InternalServerError(529, body("overloaded_error"), "Overloaded", headers), "api_error", /^Claude API error 529$/],
      [new Anthropic.NotFoundError(404, body("not_found_error"), "model not found", headers), "api_error", /404/],
      [new Error("boom"), "server_error", /went wrong/],
      ["a string", "server_error", /went wrong/],
    ];
    for (const [error, code, pattern] of cases) {
      // Thrown before any event (stream creation) ...
      const early = await collect(streamAnswer(fakeClient({ throwOnCreate: error }).client, { image: IMAGE }));
      assert.equal(early.length, 1, `${code}: only the error event`);
      assert.equal((early[0] as any).code, code, String(error));
      assert.match((early[0] as any).message, pattern);
      // ... and mid-stream, after some text was already sent.
      const late = await collect(streamAnswer(fakeClient({ events: [textDelta("a")], throwAfter: error }).client, { image: IMAGE }));
      assert.deepEqual(late.slice(0, 2), [{ type: "start", model: DEFAULT_MODEL }, { type: "text", text: "a" }]);
      assert.equal((late.at(-1) as any).code, code);
    }
  });

  test("error messages never leak the API key", async () => {
    const error = new Anthropic.AuthenticationError(401, { type: "error" }, `bad key ${ENV.ANTHROPIC_API_KEY}`, new Headers());
    const events = await collect(streamAnswer(fakeClient({ throwOnCreate: error }).client, { image: IMAGE }));
    assert.ok(!JSON.stringify(events).includes(ENV.ANTHROPIC_API_KEY));
  });
});

// MARK: - handleAnswer: checks that happen before Claude is called

describe("handleAnswer validation", () => {
  let realFetch: typeof fetch;
  let fetchCalls = 0;
  beforeEach(() => {
    realFetch = globalThis.fetch;
    fetchCalls = 0;
    globalThis.fetch = (async () => {
      fetchCalls++;
      throw new Error("network is disabled in tests");
    }) as typeof fetch;
  });
  afterEach(() => {
    globalThis.fetch = realFetch;
    assert.equal(fetchCalls, 0, "rejected requests must not call Claude");
  });

  async function expectError(response: Response, status: number, error: string) {
    assert.equal(response.status, status);
    assert.match(response.headers.get("content-type") ?? "", /application\/json/);
    assert.equal(response.headers.get("cache-control"), "no-store");
    const body = await response.json();
    assert.equal(body.error, error);
    assert.equal(typeof body.message, "string", "the app shows `message`");
    return body;
  }

  test("503 when the server is missing its keys", async () => {
    for (const env of [{}, { DOCSNAP_APP_TOKEN: TOKEN }, { ANTHROPIC_API_KEY: ENV.ANTHROPIC_API_KEY }, { DOCSNAP_APP_TOKEN: "", ANTHROPIC_API_KEY: "" }]) {
      const body = await expectError(await handleAnswer(request({ image: IMAGE }), env), 503, "not_configured");
      assert.ok(!JSON.stringify(body).includes(ENV.ANTHROPIC_API_KEY));
    }
  });

  test("401 for a missing, empty or wrong token", async () => {
    const headerSets: Record<string, string>[] = [
      {},
      { "x-docsnap-token": "" },
      { "x-docsnap-token": "wrong" },
      { "x-docsnap-token": TOKEN.slice(0, -1) + "X" }, // same length
      { "x-docsnap-token": TOKEN + "extra" },
      { "x-docsnap-token": TOKEN.toUpperCase() },
      { authorization: `Bearer ${TOKEN}` },
    ];
    for (const headers of headerSets) {
      await expectError(await handleAnswer(request({ image: IMAGE }, headers), ENV), 401, "unauthorized");
    }
  });

  test("the token is checked before the body is read", async () => {
    await expectError(await handleAnswer(request("{not json", {}), ENV), 401, "unauthorized");
  });

  test("400 for a body that isn't JSON", async () => {
    for (const body of ["{not json", "", "image=abc"]) {
      await expectError(await handleAnswer(request(body), ENV), 400, "bad_json");
    }
  });

  test("400 for a bad image", async () => {
    const body = await expectError(await handleAnswer(request({ image: "data:image/jpeg;base64," + IMAGE }), ENV), 400, "bad_request");
    assert.equal(body.message, "Page image must be plain base64.");
    await expectError(await handleAnswer(request({}), ENV), 400, "bad_request");
    await expectError(await handleAnswer(request("null"), ENV), 400, "bad_request");
    await expectError(await handleAnswer(request([IMAGE]), ENV), 400, "bad_request");
  });

  test("400 for an unsupported model", async () => {
    const body = await expectError(await handleAnswer(request({ image: IMAGE, model: "claude-2" }), ENV), 400, "bad_request");
    assert.equal(body.message, "Unsupported model.");
  });

  test("POST uses process.env", async () => {
    const saved = { token: process.env.DOCSNAP_APP_TOKEN, key: process.env.ANTHROPIC_API_KEY };
    try {
      delete process.env.DOCSNAP_APP_TOKEN;
      delete process.env.ANTHROPIC_API_KEY;
      await expectError(await POST(request({ image: IMAGE })), 503, "not_configured");
      process.env.DOCSNAP_APP_TOKEN = TOKEN;
      process.env.ANTHROPIC_API_KEY = ENV.ANTHROPIC_API_KEY;
      await expectError(await POST(request({ image: IMAGE }, { "x-docsnap-token": "nope" })), 401, "unauthorized");
    } finally {
      restoreEnv("DOCSNAP_APP_TOKEN", saved.token);
      restoreEnv("ANTHROPIC_API_KEY", saved.key);
    }
  });

  test("GET is a health check that reports whether keys are configured", async () => {
    const saved = { token: process.env.DOCSNAP_APP_TOKEN, key: process.env.ANTHROPIC_API_KEY };
    try {
      delete process.env.DOCSNAP_APP_TOKEN;
      delete process.env.ANTHROPIC_API_KEY;
      let response = GET();
      assert.equal(response.status, 200);
      assert.deepEqual(await response.json(), { ok: true, service: "docsnap-answer", configured: false, defaultModel: DEFAULT_MODEL });
      process.env.DOCSNAP_APP_TOKEN = TOKEN;
      process.env.ANTHROPIC_API_KEY = ENV.ANTHROPIC_API_KEY;
      response = GET();
      const text = await response.text();
      assert.equal(JSON.parse(text).configured, true);
      assert.ok(!text.includes(ENV.ANTHROPIC_API_KEY) && !text.includes(TOKEN), "health check never echoes secrets");
    } finally {
      restoreEnv("DOCSNAP_APP_TOKEN", saved.token);
      restoreEnv("ANTHROPIC_API_KEY", saved.key);
    }
  });
});

function restoreEnv(name: string, value: string | undefined) {
  if (value === undefined) delete process.env[name];
  else process.env[name] = value;
}

// MARK: - handleAnswer end to end, with the SDK talking to a fake fetch

describe("handleAnswer streaming (fake Anthropic HTTP)", () => {
  const BASE = "http://127.0.0.1:9"; // discard port; fetch is replaced anyway, so nothing leaves the machine
  let realFetch: typeof fetch;
  let savedBase: string | undefined;
  let sent: { url: string; headers: Headers; body: any }[] = [];
  let sse = "";

  function sseOf(events: Record<string, unknown>[]): string {
    return events.map((e) => `event: ${e.type}\ndata: ${JSON.stringify(e)}\n\n`).join("");
  }

  beforeEach(() => {
    realFetch = globalThis.fetch;
    savedBase = process.env.ANTHROPIC_BASE_URL;
    process.env.ANTHROPIC_BASE_URL = BASE;
    sent = [];
    globalThis.fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = typeof input === "string" ? input : input instanceof URL ? input.href : input.url;
      if (!url.startsWith(BASE)) throw new Error(`unexpected network call to ${url}`);
      sent.push({ url, headers: new Headers(init?.headers), body: JSON.parse(String(init?.body)) });
      return new Response(sse, { status: 200, headers: { "content-type": "text/event-stream", "request-id": "req_test" } });
    }) as typeof fetch;
  });
  afterEach(() => {
    globalThis.fetch = realFetch;
    restoreEnv("ANTHROPIC_BASE_URL", savedBase);
  });

  function streamOf(text: string[], stopReason = "end_turn", model = "claude-opus-5-5") {
    return sseOf([
      { type: "message_start", message: { ...message({ model, stop_reason: null }), usage: { input_tokens: 1500, output_tokens: 1 } } },
      { type: "content_block_start", index: 0, content_block: { type: "text", text: "" } },
      ...text.map(textDelta),
      { type: "content_block_stop", index: 0 },
      { type: "message_delta", delta: { stop_reason: stopReason, stop_sequence: null }, usage: { output_tokens: 42 } },
      { type: "message_stop" },
    ]);
  }

  test("streams NDJSON text and done lines", async () => {
    sse = streamOf(["### 1. Câu hỏi\n", "**Đáp án: x = 2**"]);
    const response = await handleAnswer(request({ image: IMAGE, model: "claude-opus-5-5", text: "1. x² = 4" }), ENV);
    assert.equal(response.status, 200);
    assert.match(response.headers.get("content-type") ?? "", /^application\/x-ndjson/);
    assert.equal(response.headers.get("cache-control"), "no-store");
    const lines = await readNDJSON(response);
    assert.deepEqual(lines, [
      { type: "start", model: "claude-opus-5-5" },
      { type: "text", text: "### 1. Câu hỏi\n" },
      { type: "text", text: "**Đáp án: x = 2**" },
      { type: "done", stopReason: "end_turn", model: "claude-opus-5-5", inputTokens: 1500, outputTokens: 42 },
    ]);

    assert.equal(sent.length, 1, "one request to Claude (no retries)");
    assert.match(sent[0].url, /\/v1\/messages/);
    // SDK 1.x sends the key as a bearer token; older versions used x-api-key.
    const key = sent[0].headers.get("x-api-key") ?? sent[0].headers.get("authorization")?.replace(/^Bearer /, "");
    assert.equal(key, ENV.ANTHROPIC_API_KEY, "the server's key is used");
    assert.equal(sent[0].body.model, "claude-opus-5-5");
    assert.equal(sent[0].body.stream, true);
    assert.equal(sent[0].body.fallbacks, "default");
    assert.match(sent[0].headers.get("anthropic-beta") ?? "", /server-side-fallback/);
    assert.ok(!("betas" in sent[0].body), "betas travel as a header, not in the body");
  });

  test("Haiku requests carry no fallback parameters", async () => {
    sse = streamOf(["ok"], "end_turn", "claude-haiku-5-5");
    const lines = await readNDJSON(await handleAnswer(request({ image: IMAGE, model: "claude-haiku-5-5" }), ENV));
    assert.equal(lines.at(-1).type, "done");
    assert.equal(sent[0].body.model, "claude-haiku-5-5");
    assert.ok(!("fallbacks" in sent[0].body));
    assert.doesNotMatch(sent[0].headers.get("anthropic-beta") ?? "", /server-side-fallback/);
  });

  test("a refusal ends the NDJSON stream with an error line", async () => {
    sse = streamOf(["I"], "refusal");
    const lines = await readNDJSON(await handleAnswer(request({ image: IMAGE }), ENV));
    assert.deepEqual(lines.at(-1), { type: "error", code: "refusal", message: "Claude declined to answer this page." });
    assert.ok(!lines.some((l) => l.type === "done"));
  });

  test("an Anthropic error still answers 200 with an error line the app can show", async () => {
    globalThis.fetch = (async (input: RequestInfo | URL) => {
      const url = typeof input === "string" ? input : input instanceof URL ? input.href : input.url;
      if (!url.startsWith(BASE)) throw new Error(`unexpected network call to ${url}`);
      sent.push({ url, headers: new Headers(), body: null });
      return new Response(JSON.stringify({ type: "error", error: { type: "authentication_error", message: "invalid x-api-key" } }),
        { status: 401, headers: { "content-type": "application/json" } });
    }) as typeof fetch;
    const response = await handleAnswer(request({ image: IMAGE }), ENV);
    assert.equal(response.status, 200);
    const lines = await readNDJSON(response);
    assert.deepEqual(lines.at(-1), { type: "error", code: "server_key", message: "The server's Claude API key is missing or invalid." });
    assert.equal(sent.length, 1, "401 is not retried");
  });

  test("a 400 from Claude gives the app a readable message, not raw JSON", async () => {
    // Regression: the SDK's error.message is `400 {"type":"error",...}`; students used to see raw JSON.
    globalThis.fetch = (async (input: RequestInfo | URL) => {
      const url = typeof input === "string" ? input : input instanceof URL ? input.href : input.url;
      if (!url.startsWith(BASE)) throw new Error(`unexpected network call to ${url}`);
      return new Response(JSON.stringify({ type: "error", error: { type: "invalid_request_error", message: "Could not process image" } }),
        { status: 400, headers: { "content-type": "application/json", "request-id": "req_test" } });
    }) as typeof fetch;
    const lines = await readNDJSON(await handleAnswer(request({ image: IMAGE }), ENV));
    const last = lines.at(-1);
    assert.equal(last.code, "bad_request");
    assert.match(last.message, /Could not process image/);
    assert.doesNotMatch(last.message, /\{"type"/, `message shown in the app: ${last.message}`);
  });
});
