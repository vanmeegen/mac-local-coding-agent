#!/usr/bin/env bun
/**
 * agent.ts — a minimal terminal coding agent (REPL) built on LocalLLM.
 *
 * Everything runs locally against Ollama. Streaming output, conversation
 * history, file inlining, and a handful of slash commands.
 *
 * Usage:
 *   bun src/agent.ts [files...]      # files are preloaded into context
 *
 * Commands (type /help inside the REPL):
 *   @path                inline a file's contents into your next message
 *   /add <path>          add a file to the conversation
 *   /run <cmd>           run a shell command, feed its output back to the model
 *   /write <path>        write the last code block to <path> (asks y/N first)
 *   /model dense|moe     switch model (dense = reliable, moe = fast)
 *   /reset               clear the conversation
 *   /save                save the transcript to a markdown file
 *   /help                show commands
 *   /exit                quit
 */

import { createInterface, type Interface } from "node:readline";
import { LocalLLM, type Message, type ModelKey } from "./local-llm.ts";

const SYSTEM_PROMPT = `You are a senior TypeScript engineer pair-programming in a terminal.

The stack is: Bun (not Node), React, TypeScript in strict mode, and Tailwind CSS.
Deploy target is GitHub Pages.

Conventions:
- Prefer dependency-free, functional code. Avoid adding libraries unless asked.
- Strict types — no \`any\`, no implicit returns, handle errors explicitly.
- When you produce a file, emit the COMPLETE file (not a diff), and put the file
  path on the fence info line so it can be written directly, e.g.:

  \`\`\`ts src/foo.ts
  // complete contents here
  \`\`\`

- Be concise. Show code, not prose, when code is the answer.`;

// --- Small terminal helpers --------------------------------------------------

const C = {
  reset: "\x1b[0m",
  dim: "\x1b[2m",
  bold: "\x1b[1m",
  cyan: "\x1b[36m",
  green: "\x1b[32m",
  yellow: "\x1b[33m",
  red: "\x1b[31m",
} as const;

const color = (c: keyof typeof C, s: string): string => `${C[c]}${s}${C.reset}`;

// --- Filesystem / shell helpers ---------------------------------------------

async function readFileSafe(path: string): Promise<string | null> {
  try {
    return await Bun.file(path).text();
  } catch {
    return null;
  }
}

/** Run a shell command via Bun.spawn, capturing stdout+stderr. */
async function runCommand(
  cmd: string,
): Promise<{ ok: boolean; output: string }> {
  const proc = Bun.spawn(["/bin/sh", "-c", cmd], {
    stdout: "pipe",
    stderr: "pipe",
  });
  const [stdout, stderr] = await Promise.all([
    new Response(proc.stdout).text(),
    new Response(proc.stderr).text(),
  ]);
  const code = await proc.exited;
  const output = [stdout, stderr].filter(Boolean).join("\n").trim();
  return { ok: code === 0, output: output || `(no output, exit ${code})` };
}

/** Extract the last fenced code block from text; returns its body. */
function lastCodeBlock(text: string): string | null {
  const matches = [...text.matchAll(/```[^\n]*\n([\s\S]*?)```/g)];
  const last = matches.at(-1);
  return last?.[1]?.replace(/\n$/, "") ?? null;
}

/** Inline any `@path` tokens in a line, replacing them with file contents. */
async function inlineFileRefs(line: string): Promise<string> {
  const refs = [...line.matchAll(/(?:^|\s)@(\S+)/g)].map((m) => m[1]!);
  if (refs.length === 0) return line;
  let result = line;
  for (const path of refs) {
    const contents = await readFileSafe(path);
    const block =
      contents === null
        ? `\n[could not read @${path}]\n`
        : `\n\n--- ${path} ---\n${contents}\n--- end ${path} ---\n`;
    result = result.replace(new RegExp(`@${path.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}`), block);
  }
  return result;
}

// --- Agent -------------------------------------------------------------------

class Agent {
  private readonly llm = new LocalLLM();
  private readonly history: Message[] = [
    { role: "system", content: SYSTEM_PROMPT },
  ];
  private lastReply = "";
  private rl!: Interface;

  async start(preloadFiles: string[]): Promise<void> {
    await this.healthCheck();
    await this.preload(preloadFiles);

    this.rl = createInterface({ input: process.stdin, output: process.stdout });
    this.printHelp();
    this.prompt();

    this.rl.on("line", (line) => void this.handleLine(line));
    this.rl.on("close", () => {
      console.log(color("dim", "\nbye."));
      process.exit(0);
    });
  }

  private prompt(): void {
    const tag = this.llm.currentModel;
    this.rl.setPrompt(color("cyan", `\n${tag} ❯ `));
    this.rl.prompt();
  }

  private async healthCheck(): Promise<void> {
    process.stdout.write(color("dim", "Checking local LLM server… "));
    try {
      const models = await this.llm.health(AbortSignal.timeout(5000));
      console.log(color("green", "ok"));
      if (models.length > 0) {
        console.log(color("dim", `Available: ${models.join(", ")}`));
      }
    } catch {
      console.log(color("red", "unreachable"));
      console.log(
        color(
          "yellow",
          "Could not reach http://localhost:11434/v1 — is Ollama running?\n" +
            "Start it with:  ollama serve   (then re-run, or run ./setup.sh)",
        ),
      );
      process.exit(1);
    }
  }

  private async preload(files: string[]): Promise<void> {
    for (const path of files) {
      const contents = await readFileSafe(path);
      if (contents === null) {
        console.log(color("yellow", `Skipped (unreadable): ${path}`));
        continue;
      }
      this.history.push({
        role: "user",
        content: `Here is \`${path}\` for context:\n\n--- ${path} ---\n${contents}\n--- end ${path} ---`,
      });
      console.log(color("dim", `Loaded ${path}`));
    }
  }

  private printHelp(): void {
    console.log(
      color("bold", "\nLocal coding agent") +
        color("dim", " — fully local via Ollama.\n") +
        [
          "  @path           inline a file into your message",
          "  /add <path>     add a file to the conversation",
          "  /run <cmd>      run a command, feed output back to the model",
          "  /write <path>   write the last code block to <path>",
          "  /model dense|moe   switch model",
          "  /reset          clear the conversation",
          "  /save           save the transcript",
          "  /help           show this help",
          "  /exit           quit",
        ].join("\n"),
    );
  }

  private async handleLine(raw: string): Promise<void> {
    const line = raw.trim();
    if (line.length === 0) {
      this.prompt();
      return;
    }

    if (line.startsWith("/")) {
      await this.handleCommand(line);
      return;
    }

    const content = await inlineFileRefs(line);
    this.history.push({ role: "user", content });
    await this.respond();
    this.prompt();
  }

  private async handleCommand(line: string): Promise<void> {
    const [cmd, ...rest] = line.split(/\s+/);
    const arg = rest.join(" ");

    switch (cmd) {
      case "/exit":
      case "/quit":
        this.rl.close();
        return;

      case "/help":
        this.printHelp();
        break;

      case "/reset":
        this.history.length = 1; // keep the system prompt
        this.lastReply = "";
        console.log(color("dim", "Conversation cleared."));
        break;

      case "/model": {
        if (arg !== "dense" && arg !== "moe") {
          console.log(color("yellow", "Usage: /model dense|moe"));
          break;
        }
        this.llm.use(arg as ModelKey);
        console.log(color("dim", `Switched to ${this.llm.currentModel}`));
        break;
      }

      case "/add": {
        if (!arg) {
          console.log(color("yellow", "Usage: /add <path>"));
          break;
        }
        const contents = await readFileSafe(arg);
        if (contents === null) {
          console.log(color("red", `Could not read ${arg}`));
          break;
        }
        this.history.push({
          role: "user",
          content: `Here is \`${arg}\`:\n\n--- ${arg} ---\n${contents}\n--- end ${arg} ---`,
        });
        console.log(color("dim", `Added ${arg} to context.`));
        break;
      }

      case "/run": {
        if (!arg) {
          console.log(color("yellow", "Usage: /run <cmd>"));
          break;
        }
        console.log(color("dim", `$ ${arg}`));
        const { ok, output } = await runCommand(arg);
        console.log(ok ? output : color("red", output));
        this.history.push({
          role: "user",
          content: `I ran \`${arg}\`. Output:\n\n\`\`\`\n${output}\n\`\`\``,
        });
        await this.respond();
        break;
      }

      case "/write": {
        if (!arg) {
          console.log(color("yellow", "Usage: /write <path>"));
          break;
        }
        await this.writeLastBlock(arg);
        break;
      }

      case "/save":
        await this.saveTranscript();
        break;

      default:
        console.log(color("yellow", `Unknown command: ${cmd} (try /help)`));
    }

    this.prompt();
  }

  /** Stream a model reply, printing as it arrives, and store it in history. */
  private async respond(): Promise<void> {
    process.stdout.write("\n");
    let reply = "";
    try {
      for await (const delta of this.llm.stream(this.history)) {
        process.stdout.write(delta);
        reply += delta;
      }
    } catch (err) {
      console.log(color("red", `\nRequest failed: ${(err as Error).message}`));
      return;
    }
    process.stdout.write("\n");
    this.lastReply = reply;
    this.history.push({ role: "assistant", content: reply });
  }

  private async writeLastBlock(path: string): Promise<void> {
    const block = lastCodeBlock(this.lastReply);
    if (block === null) {
      console.log(color("yellow", "No code block in the last reply."));
      return;
    }
    const answer = await this.ask(
      color("yellow", `Write ${block.length} chars to ${path}? [y/N] `),
    );
    if (answer.trim().toLowerCase() !== "y") {
      console.log(color("dim", "Cancelled."));
      return;
    }
    await Bun.write(path, block);
    console.log(color("green", `Wrote ${path}`));
  }

  private async saveTranscript(): Promise<void> {
    const stamp = new Date().toISOString().replace(/[:.]/g, "-");
    const path = `transcript-${stamp}.md`;
    const body = this.history
      .filter((m) => m.role !== "system")
      .map((m) => `## ${m.role}\n\n${m.content}`)
      .join("\n\n");
    await Bun.write(path, body);
    console.log(color("green", `Saved transcript to ${path}`));
  }

  /** One-off question that doesn't go through the main line handler. */
  private ask(question: string): Promise<string> {
    return new Promise((resolve) => this.rl.question(question, resolve));
  }
}

// --- Entry point -------------------------------------------------------------

const files = process.argv.slice(2);
await new Agent().start(files);
