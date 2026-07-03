/**
 * local-llm.ts — a dependency-free client for a local, OpenAI-compatible LLM
 * server (Ollama 0.30+ at http://localhost:11434/v1). No SDK, no cloud, no API
 * keys leaving the machine — just Bun's native `fetch`.
 *
 * NOTE: if you already have code built on the official `openai` SDK, you don't
 * need this client at all — just point that SDK at the same endpoint:
 *
 *     OPENAI_BASE_URL=http://localhost:11434/v1  OPENAI_API_KEY=ollama
 *
 * This file exists for the zero-dependency path.
 */

// --- Types -------------------------------------------------------------------

/** OpenAI-style roles. `developer` is supported by the Unsloth Qwen3.6 build. */
export type Role = "system" | "developer" | "user" | "assistant";

export interface Message {
  readonly role: Role;
  readonly content: string;
}

/** A prompt is either a bare string (treated as a user turn) or full messages. */
export type Input = string | readonly Message[];

/** Logical model selector → resolved Ollama model tag. */
export type ModelKey = "dense" | "moe";

export const MODELS: Readonly<Record<ModelKey, string>> = {
  dense: "qwen3.6-coder", // 27B dense, the reliable agent driver
  moe: "qwen3.6:35b-a3b", // 35B-A3B MoE (3B active), the fast gear
};

export interface LocalLLMConfig {
  /** OpenAI-compatible base URL. Default: http://localhost:11434/v1 */
  readonly baseURL?: string;
  /** API key. Ollama ignores it but the OpenAI wire format wants one. */
  readonly apiKey?: string;
  /** Initial model tag. Default: MODELS.dense */
  readonly model?: string;
  readonly temperature?: number;
  readonly topP?: number;
  /** Per-request timeout in ms. Default: 600_000 (10 min — agentic turns are long). */
  readonly timeoutMs?: number;
  /** Retry attempts on 429 / 5xx / network errors. Default: 3 */
  readonly retries?: number;
}

export interface RequestOpts {
  /** Override the model for this single call. */
  readonly model?: string;
  readonly temperature?: number;
  readonly topP?: number;
  readonly maxTokens?: number;
  /** Prepended as a system message if `input` is a string or lacks one. */
  readonly system?: string;
  /** Caller-supplied cancellation, merged with the per-request timeout. */
  readonly signal?: AbortSignal;
  /** Override the per-request timeout in ms. */
  readonly timeoutMs?: number;
  /** Override retry attempts. */
  readonly retries?: number;
  /** Extra stop sequences. */
  readonly stop?: readonly string[];
}

interface ChatCompletionChoice {
  readonly message?: { readonly content?: string | null };
  readonly delta?: { readonly content?: string | null };
}

interface ChatCompletionResponse {
  readonly choices?: readonly ChatCompletionChoice[];
}

// --- Errors ------------------------------------------------------------------

export class LocalLLMError extends Error {
  constructor(
    message: string,
    readonly status?: number,
    readonly body?: string,
  ) {
    super(message);
    this.name = "LocalLLMError";
  }
}

// --- Helpers -----------------------------------------------------------------

const DEFAULTS = {
  baseURL: "http://localhost:11434/v1",
  apiKey: "ollama",
  temperature: 0.2,
  topP: 0.9,
  timeoutMs: 600_000,
  retries: 3,
} as const;

/** Normalize a string-or-messages input into a concrete message array. */
function toMessages(input: Input, system?: string): Message[] {
  const base: Message[] =
    typeof input === "string"
      ? [{ role: "user", content: input }]
      : [...input];
  if (system && !base.some((m) => m.role === "system" || m.role === "developer")) {
    return [{ role: "system", content: system }, ...base];
  }
  return base;
}

/** Merge a caller signal with a fresh timeout signal. */
function mergeSignals(timeoutMs: number, signal?: AbortSignal): AbortSignal {
  const timeout = AbortSignal.timeout(timeoutMs);
  return signal ? AbortSignal.any([signal, timeout]) : timeout;
}

const sleep = (ms: number): Promise<void> =>
  new Promise((resolve) => setTimeout(resolve, ms));

/** Strip a single leading/trailing ```json … ``` (or bare ```) fence. */
export function stripCodeFences(text: string): string {
  const trimmed = text.trim();
  const fenced = /^```(?:json)?\s*\n?([\s\S]*?)\n?```$/i.exec(trimmed);
  return (fenced?.[1] ?? trimmed).trim();
}

// --- Client ------------------------------------------------------------------

export class LocalLLM {
  private readonly baseURL: string;
  private readonly apiKey: string;
  private readonly temperature: number;
  private readonly topP: number;
  private readonly timeoutMs: number;
  private readonly retries: number;
  private model: string;

  constructor(config: LocalLLMConfig = {}) {
    this.baseURL = (config.baseURL ?? DEFAULTS.baseURL).replace(/\/$/, "");
    this.apiKey = config.apiKey ?? DEFAULTS.apiKey;
    this.temperature = config.temperature ?? DEFAULTS.temperature;
    this.topP = config.topP ?? DEFAULTS.topP;
    this.timeoutMs = config.timeoutMs ?? DEFAULTS.timeoutMs;
    this.retries = config.retries ?? DEFAULTS.retries;
    this.model = config.model ?? MODELS.dense;
  }

  /** Chainable model switch: `llm.use("moe").complete(...)`. */
  use(key: ModelKey): this {
    this.model = MODELS[key];
    return this;
  }

  /** The currently selected model tag. */
  get currentModel(): string {
    return this.model;
  }

  /** Health check — pings the OpenAI-compatible /models endpoint. */
  async health(signal?: AbortSignal): Promise<string[]> {
    const res = await fetch(`${this.baseURL}/models`, {
      headers: { authorization: `Bearer ${this.apiKey}` },
      signal: mergeSignals(this.timeoutMs, signal),
    });
    if (!res.ok) {
      throw new LocalLLMError(
        `Health check failed: ${res.status} ${res.statusText}`,
        res.status,
      );
    }
    const data = (await res.json()) as { data?: { id: string }[] };
    return (data.data ?? []).map((m) => m.id);
  }

  /** Non-streaming completion → full text. */
  async complete(input: Input, opts: RequestOpts = {}): Promise<string> {
    const res = await this.request(input, opts, false, false);
    const data = (await res.json()) as ChatCompletionResponse;
    return data.choices?.[0]?.message?.content ?? "";
  }

  /** Streaming completion → async generator of text deltas (OpenAI SSE). */
  async *stream(
    input: Input,
    opts: RequestOpts = {},
  ): AsyncGenerator<string, void, unknown> {
    const res = await this.request(input, opts, true, false);
    if (!res.body) throw new LocalLLMError("No response body to stream");

    const decoder = new TextDecoder();
    let buffer = "";

    for await (const chunk of res.body as unknown as AsyncIterable<Uint8Array>) {
      buffer += decoder.decode(chunk, { stream: true });

      // SSE frames are separated by a blank line; lines start with "data: ".
      let nl: number;
      while ((nl = buffer.indexOf("\n")) !== -1) {
        const line = buffer.slice(0, nl).trim();
        buffer = buffer.slice(nl + 1);
        if (!line.startsWith("data:")) continue;
        const payload = line.slice(5).trim();
        if (payload === "[DONE]") return;
        try {
          const frame = JSON.parse(payload) as ChatCompletionResponse;
          const delta = frame.choices?.[0]?.delta?.content;
          if (delta) yield delta;
        } catch {
          // Partial/garbled frame — wait for more bytes.
        }
      }
    }
  }

  /**
   * Forces JSON output via `response_format: json_object`, strips any ```json
   * fences the model adds anyway, and parses to T.
   */
  async json<T>(input: Input, opts: RequestOpts = {}): Promise<T> {
    // Force structured output; the model often still wraps it in a ```json
    // fence anyway, so we strip fences before parsing.
    const res = await this.request(input, opts, false, true);
    const data = (await res.json()) as ChatCompletionResponse;
    const text = data.choices?.[0]?.message?.content ?? "";
    const cleaned = stripCodeFences(text);
    try {
      return JSON.parse(cleaned) as T;
    } catch (err) {
      throw new LocalLLMError(
        `Failed to parse JSON response: ${(err as Error).message}\n--- raw ---\n${text}`,
      );
    }
  }

  // --- Internal --------------------------------------------------------------

  private buildBody(
    input: Input,
    opts: RequestOpts,
    stream: boolean,
    forceJson: boolean,
  ): Record<string, unknown> {
    const body: Record<string, unknown> = {
      model: opts.model ?? this.model,
      messages: toMessages(input, opts.system),
      temperature: opts.temperature ?? this.temperature,
      top_p: opts.topP ?? this.topP,
      stream,
    };
    if (opts.maxTokens !== undefined) body.max_tokens = opts.maxTokens;
    if (opts.stop && opts.stop.length > 0) body.stop = opts.stop;
    if (forceJson) body.response_format = { type: "json_object" };
    return body;
  }

  /** POST /chat/completions with retry + exponential backoff. */
  private async request(
    input: Input,
    opts: RequestOpts,
    stream: boolean,
    forceJson: boolean,
  ): Promise<Response> {
    const retries = opts.retries ?? this.retries;
    const timeoutMs = opts.timeoutMs ?? this.timeoutMs;
    const body = this.buildBody(input, opts, stream, forceJson);

    let lastErr: unknown;
    for (let attempt = 0; attempt <= retries; attempt++) {
      try {
        const res = await fetch(`${this.baseURL}/chat/completions`, {
          method: "POST",
          headers: {
            "content-type": "application/json",
            authorization: `Bearer ${this.apiKey}`,
          },
          body: JSON.stringify(body),
          signal: mergeSignals(timeoutMs, opts.signal),
        });

        if (res.ok) return res;

        // Retry only on transient statuses; surface everything else.
        if (res.status === 429 || res.status >= 500) {
          lastErr = new LocalLLMError(
            `Server returned ${res.status} ${res.statusText}`,
            res.status,
            await res.text().catch(() => undefined),
          );
        } else {
          throw new LocalLLMError(
            `Request failed: ${res.status} ${res.statusText}`,
            res.status,
            await res.text().catch(() => undefined),
          );
        }
      } catch (err) {
        // AbortError from the caller's signal should not be retried.
        if (err instanceof DOMException && err.name === "AbortError" && opts.signal?.aborted) {
          throw err;
        }
        lastErr = err;
      }

      if (attempt < retries) {
        await sleep(2 ** attempt * 1000); // 1s, 2s, 4s, …
      }
    }

    if (lastErr instanceof Error) throw lastErr;
    throw new LocalLLMError("Request failed after retries");
  }
}

export default LocalLLM;
