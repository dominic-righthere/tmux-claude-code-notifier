import { spawn } from "node:child_process";

type AgentNotifierEvent = {
  hook_event_name: string;
  agent: "pi";
  message?: string;
  tool_name?: string;
  session_id?: string;
  cwd?: string;
};

const scriptDir = process.env.AGENT_NOTIFIER_SCRIPT_DIR || "__AGENT_NOTIFIER_SCRIPT_DIR__";
const notifyScript = `${scriptDir}/notify.sh`;

function notify(payload: AgentNotifierEvent) {
  const child = spawn(notifyScript, {
    stdio: ["pipe", "ignore", "ignore"],
    env: {
      ...process.env,
      AGENT_NOTIFIER_AGENT: "pi",
    },
  });

  child.stdin.end(JSON.stringify(payload));
}

export default function agentNotifierExtension(ctx: any) {
  const sessionId = ctx.session?.id || ctx.sessionId || "";
  const cwd = ctx.cwd || process.cwd();

  ctx.on("session_start", () => notify({ hook_event_name: "session_start", agent: "pi", session_id: sessionId, cwd }));
  ctx.on("before_agent_start", () => notify({ hook_event_name: "before_agent_start", agent: "pi", session_id: sessionId, cwd }));
  ctx.on("agent_start", () => notify({ hook_event_name: "agent_start", agent: "pi", session_id: sessionId, cwd }));
  ctx.on("turn_start", () => notify({ hook_event_name: "turn_start", agent: "pi", session_id: sessionId, cwd }));
  ctx.on("tool_execution_start", (event: any) => {
    notify({
      hook_event_name: "tool_execution_start",
      agent: "pi",
      session_id: sessionId,
      cwd,
      tool_name: event?.toolName || event?.tool_name || event?.name || "tool",
    });
  });
  ctx.on("agent_end", () => notify({ hook_event_name: "agent_end", agent: "pi", session_id: sessionId, cwd }));
  ctx.on("session_shutdown", () => notify({ hook_event_name: "session_shutdown", agent: "pi", session_id: sessionId, cwd }));
}
