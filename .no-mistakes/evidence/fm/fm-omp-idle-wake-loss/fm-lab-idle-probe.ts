import { appendFileSync, existsSync, unlinkSync, writeFileSync } from "node:fs";

type Entry = { type?: string; customType?: string; message?: { role?: string } };
type Ctx = { isIdle?: () => boolean; sessionManager?: { getLeafEntry?: () => Entry | undefined } };
type Part = { type?: string; text?: unknown };
type Event = { willContinue?: boolean; message?: { role?: string; content?: unknown } };
type Api = {
  on: (event: string, handler: (event: Event, ctx: Ctx) => void) => void;
  sendMessage: (message: { customType: string; content: string; display: boolean }) => void;
};

const state = `${process.env.FM_HOME}/state`;
const record = (line: string) => appendFileSync(`${state}/.lab-probe.log`, `${line}\n`);

// The text parts of a message, joined.
function messageText(content: unknown): string {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  return content.map((part: Part) => (part?.type === "text" && typeof part.text === "string" ? part.text : "")).join("");
}

export default function (pi: Api) {
  let latest: Ctx | undefined;
  pi.on("session_start", (_event, ctx) => {
    latest = ctx;
  });
  pi.on("message_start", (event, ctx) => {
    latest = ctx;
    if (event.message?.role !== "user") return;
    const text = messageText(event.message.content);
    record(`${text.includes("FIRSTMATE WATCHER WAKE") ? "wake" : "user"} ${text.slice(0, 60).replace(/\s+/g, " ")}`);
  });
  pi.on("message_end", (event) => {
    const reply = event.message?.role === "assistant" ? messageText(event.message.content).trim() : "";
    if (reply) record(`reply ${reply}`);
  });
  pi.on("agent_end", (event, ctx) => {
    latest = ctx;
    const flag = `${state}/.lab-advisor-note`;
    if (event.willContinue === true || !existsSync(flag)) return;
    unlinkSync(flag);
    // omp's advisor keeps its note for a finished answer only once omp is idle.
    const append = (tries: number): void => {
      if (latest?.isIdle?.() !== true && tries > 0) {
        setTimeout(() => append(tries - 1), 250);
        return;
      }
      pi.sendMessage({ customType: "advisor", content: "lab advisory after the final answer", display: true });
      record("note");
    };
    setTimeout(() => append(80), 1500);
  });
  setInterval(() => {
    const leaf = latest?.sessionManager?.getLeafEntry?.();
    const last = leaf?.type === "custom_message" ? `custom_message/${leaf.customType}` : `${leaf?.type}/${leaf?.message?.role}`;
    writeFileSync(`${state}/.lab-probe.json`, `idle=${latest?.isIdle?.() === true} last=${last}\n`);
  }, 1000).unref();
}
