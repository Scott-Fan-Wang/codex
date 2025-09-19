High-Level Overview

  - Workspace layout:
      - codex-core — core agent engine and business logic (model I/O, tools, sandbox, approvals, state, history).
      - codex-protocol — shared protocol (submission/event types, config enums, model payloads).
      - codex-cli/codex-tui/codex-exec — CLIs and TUI that drive codex-core.
      - MCP integration — mcp-client (stdio JSON-RPC client), mcp-server (server side), mcp-types (typed messages).
      - Sandbox — linux-sandbox, seatbelt policy files, and execpolicy.
  - Interaction model: clients enqueue user submissions; the agent emits events on an async channel. All UI variants are thin shells over this queue/event contract.

  Core Architecture

  - Entry points:
      - core/src/codex.rs exposes Codex::spawn → returns a Codex handle plus a conversation_id.
      - IPC within the process uses an SQ/EQ pattern: Submission { id, op } in; Event { id, msg } out (protocol/src/protocol.rs).
  - Long-lived session:
      - Session holds agent state (history, approvals, MCP connections, exec session management, notifier, rollout, shell).
      - TurnContext is an immutable snapshot of per-turn config (model client, cwd, approval/sandbox policies, tools config).

  Agent Lifecycle & Turn Loop

  - Codex::spawn builds a configured Session and a TurnContext, then spawns submission_loop.
  - submission_loop:
      - Handles Op::UserInput (injects input or starts a new AgentTask), Op::UserTurn (spawn with overrides), Op::OverrideTurnContext (update defaults), approvals, list/custom prompts/history, and shutdown.
  - AgentTask:
      - Executes a streamed turn via the ModelClient (Responses or Chat APIs), processes output items in real time, performs tool calls, appends to history, tracks diffs, and notifies on completion.
      - Can be interrupted/replaced (gracefully emits TurnAborted).

  Prompting & Context Assembly

  - Base and user instructions:
      - project_doc::get_user_instructions reads AGENTS.md and configured docs; EnvironmentContext captures cwd + sandbox + approval policy; both are inserted into the first turn items.
  - Prompt (client_common.rs) builds instructions and input, selects available tools, and formats messages for the selected model family.

  Tools & Tooling Layer

  - Tool registry:
      - Dynamically constructed per turn via ToolsConfig in openai_tools.rs:
      - Shell tool (default, sandbox-aware, streamable variant, or local_shell).
      - Apply patch tool (freeform or function flavor; optional).
      - Plan tool (`update_plan`) for explicit step tracking.
      - `view_image` to attach local image paths.
      - Optional `web_search`.
      - MCP tools discovered at runtime (fully qualified names).
  - Tool JSON is generated per OpenAI API flavor (Responses vs Chat).
  - Tool invocation:
      - Response items include FunctionCall / CustomToolCall / MCP tool calls; each is dispatched in codex.rs:
      - Shell: `container.exec` / `shell` → sanitized `ExecParams` → `process_exec_tool_call`.
      - Apply Patch: forwarded through a controlled apply-patch entry with approval flow and explicit `PatchApplyBegin/End`.
      - Plan tool: parsed to `UpdatePlanArgs` and emitted as a `PlanUpdate` event.
      - MCP: routed via `McpConnectionManager::call_tool`, then the result is normalized into a consistent `FunctionCallOutput`.
      - Interactive PTY tools: `exec_command` and `write_stdin` handled by `ExecSessionManager`.

  Execution & Sandbox

  - Execution paths (core/src/exec.rs):
      - SandboxType::None spawns child via spawn_child_async with StdioPolicy::RedirectForShellTool.
      - SandboxType::MacosSeatbelt uses seatbelt policy (seatbelt.rs).
      - SandboxType::LinuxSeccomp uses the managed sandbox runner binary (codex-linux-sandbox).
  - Output handling:
      - Incremental streaming emits up to MAX_EXEC_OUTPUT_DELTAS_PER_CALL chunks per command; complete aggregated output is retained separately.
      - Truncation for model input is applied conservatively with head/tail elision to cap bytes/lines for model_formatting paths.
  - Environment:
      - exec_env::create_env derives shell environment policy (e.g., profile usage, login shell, PATH handling).

  Approval & Safety

  - Policy:
      - Approval is driven by AskForApproval (UnlessTrusted, OnFailure, OnRequest, Never) and enforced before executing commands or applying patches.
  - Flow:
      - For commands: ExecApprovalRequest event with proposed command, cwd, and reason; the decision is awaited via an oneshot channel.
      - For patches: ApplyPatchApprovalRequest with a structured file-change summary and optional grant root.
      - Approved commands are cached in approved_commands so repeated identical calls skip re-approval where appropriate.
  - Safety checks:
      - safety.rs/is_safe_command.rs assess heuristics for read-only and well-known safe commands; OnFailure can escalate to out-of-sandbox on user approval.

  MCP Integration

  - McpConnectionManager:
      - Spawns configured servers (stdio) via mcp-client with strict init timeouts, lists tools concurrently, and exposes a flattened tool map keyed by <server>__<tool> (length-capped with hashed suffixes).
      - Tool calls are proxied with typed request/response, errors surfaced as structured outputs.
  - Tool exposure:
      - MCP tools get mapped into OpenAI tool definitions using a JSON-Schema subset; anyOf simplification ensures compatibility.

  Streaming & Model Client

  - ModelClient:
      - Chooses wire API (Responses or Chat) based on provider; handles retries, structured error bodies, and auth refresh.
      - For Chat, wraps the raw stream with an aggregator to produce a single assistant message unless show_raw_agent_reasoning is set.
      - For Responses, streams SSE, forwards incremental output_item.done and all reasoning deltas live; emits Completed with token usage.
  - Reasoning:
      - Emits AgentReasoning* deltas and section breaks (encrypted content support) per model capabilities and user settings.

  Conversation & History Management

  - In-memory transcript:
      - ConversationHistory holds response items; turn input/output pairs are appended atomically after tool handling.
  - Persistent rollout:
      - rollout::RolloutRecorder persists structured RolloutItem::{EventMsg, ResponseItem} for replay/resume/fork; recording is transparent to callers.
  - Cross-session history:
      - message_history.rs writes append-only JSONL in ~/.codex/history.jsonl with advisory locks and owner-only permissions; supports introspection via GetHistory and GetHistoryEntryRequest.

  Interactive Exec Sessions (PTY)

  - The exec_command tool family (core/src/exec_command):
      - Spawns a PTY-backed shell process (portable-pty) with configurable shell and login mode; returns a session_id.
      - write_stdin sends characters (including control chars) to the session; both tools return a timed slice of combined output and structured exit status (Exited(code) or Ongoing(session_id)).
      - Output size is capped via middle truncation with token-count estimates; wall time and truncation info are included for UX clarity.

  Notifications & Turn Completion

  - On turn completion:
      - Emits TaskStarted (with model context window, if known) and TaskComplete (with last assistant message).
      - Optional external notifier (notify config) is invoked with a single JSON argument after each completed turn.

  Configuration Surface

  - Central config (core/src/config.rs):
      - Model selection, provider wiring, reasoning effort/summary/verbosity, context window overrides, approval/sandbox policies, shell env policy, MCP servers, tool toggles (plan/apply_patch/web_search/view_image/streamable shell), history behavior, TUI options, file
  opener URI scheme, notifier command, and rollout resume.
      - ConversationManager supports fresh, resumed, and forked conversations (InitialHistory::{New,Resumed,Forked}).

  Event Protocol

  - Submission ops (Op) include UserInput, UserTurn, OverrideTurnContext, approval messages, history requests, listings (MCP tools/custom prompts), Compact, and Shutdown.
  - Events (EventMsg) include:
      - Errors and stream errors; session configuration; agent reasoning (delta/raw/summary/section breaks).
      - Exec stream: ExecCommandBegin, ExecCommandOutputDelta, ExecCommandEnd, approval requests, and patch apply begin/end.
      - Plan updates, token usage, turn diffs, MCP tool call begin/end, web search begin/end, conversation history, turn aborted/complete.

  Sandbox Policy

  - SandboxPolicy variants:
      - DangerFullAccess (no restrictions), ReadOnly, WorkspaceWrite with writable roots, optional network, and tmpdir toggles.
  - Enforcement:
      - macOS seatbelt rules (seatbelt.rs + .sbpl), Linux seccomp/landlock via codex-linux-sandbox; fallback path spawns local process with controlled stdio and cwd.
  - Tool schemas for shell explain escalations and writable roots to guide the model’s usage.

  Extensibility & Composition

  - Tools are plug-and-play:
      - Core tool set toggled via config, MCP adds third-party tools seamlessly, custom prompts shown as listable resources.
  - Providers:
      - Model family abstraction (model_family.rs) chooses tool dialects and model-specific behaviors; provider wiring (model_provider_info.rs) decouples wire API and base URL/auth.
  - UIs:
      - TUI/CLI consume the same event stream; front-ends can render PlanUpdate, diffs, reasoning, and exec streaming consistently.

  Data Flow Summary

  - Input: Submission → Session task
      - Build prompt from instructions+input+history+tools → ModelClient::stream.
      - For each streamed output item:
      - Map to UI events (`AgentMessage*`, `Reasoning*`), dispatch tool calls (shell/apply_patch/MCP/exec_command), collect responses.
  - Append items to ConversationHistory and RolloutRecorder.
  - Emit turn lifecycle events; optionally notify.
  - Output: event stream drives UI, approvals, and side-effects (patches, processes).

  Notable Design Choices

  - SQ/EQ decoupling promotes portability across front-ends.
  - Tool surface is explicitly described in model-facing JSON-Schema, tuned by model family and config.
  - Sandboxing is first-class and OS-aware, with user-mediated escalation for unsafe operations.
  - Streaming-first design ensures responsive feedback (typing, reasoning, stdout deltas).
  - MCP integration is minimal but robust: stdio client with typed requests, concurrent startup, and tool name stability.

  Potential Risks & Gaps

  - Sandbox denial detection is heuristic for non-zero exit codes; nuanced permissions failures can look similar to runtime errors.
  - Large outputs are truncated for model formatting; callers must read aggregated output when full fidelity matters.
  - MCP servers rely on external binaries; startup timeouts and error surfacing are present but mean UX depends on third-party stability.

  If you want, I can produce a diagram of the data flow (submissions → turns → tool calls → events) or drill into specific parts like the approval pipeline or MCP tool schema conversion.


  Overview

  - Codex sandboxes all model-run shell commands to protect your machine and data.
  - It scopes file writes, optionally blocks network, and uses OS-native isolation:
      - macOS: Seatbelt via /usr/bin/sandbox-exec
      - Linux: Landlock + seccomp via the codex-linux-sandbox helper
      - Windows: no sandbox (commands run without OS isolation)

  Quick Start

  - Interactive/Exec modes automatically apply your configured sandbox when the agent runs shell tool calls.
  - Try the sandbox directly:
      - macOS: codex debug seatbelt --full-auto -- <your command and args>
      - Linux: codex debug landlock --full-auto -- <your command and args>

  “full-auto” uses a safe default: write access to your cwd and temp dirs, network disabled.

  Configure
  In ~/.codex/config.toml pick a mode and (optionally) tweak workspace-write:

  - sandbox_mode:
      - danger-full-access — no sandboxing (use sparingly)
      - read-only — everything readable, but no writes
      - workspace-write — read-only everywhere except selected writable roots
  - Workspace-write settings:
      - [sandbox_workspace_write]
          - writable_roots = ["/extra/path"] — add more writable folders
          - network_access = false — block (default) or allow outbound network
          - exclude_tmpdir_env_var = false — include $TMPDIR as writable by default
          - exclude_slash_tmp = false — include /tmp as writable on Unix by default

  Examples:

  - Strict, read-only:
      - sandbox_mode = "read-only"
  - Safe default, no network, can write to cwd + tmp:
      - sandbox_mode = "workspace-write"
  - Workspace write with extra root + network allowed:
      - sandbox_mode = "workspace-write"
      - [sandbox_workspace_write]
          - writable_roots = ["/path/to/project-data"]
          - network_access = true

  Note (Linux): packaged CLIs auto-wire codex-linux-sandbox. If you build from source, the CLI arranges this for you; dev setups that invoke components directly should ensure codex-linux-sandbox is built and provided to the CLI.

  How It Works

  - Policy selection:
      - read-only: read anywhere, write nowhere.
      - workspace-write: write only in cwd, /tmp and $TMPDIR (unless excluded), plus any writable_roots. Top-level .git directories remain read-only to protect repo metadata.
      - danger-full-access: unrestricted.
  - Network control:
      - When blocked, child processes get CODEX_SANDBOX_NETWORK_DISABLED=1. Scripts/tests can detect this.
  - Platform sandboxes:
      - macOS: Codex generates a Seatbelt policy and runs commands via /usr/bin/sandbox-exec. It sets CODEX_SANDBOX=seatbelt on the child.
      - Linux: Codex invokes codex-linux-sandbox with the JSON-encoded policy (Landlock + seccomp).
  - Timeouts: default 10s per command (configurable per call). On timeout, exit is reported back to the model; user escalation can be requested when appropriate.

  Approvals And Escalation

  - Approval policy controls when Codex asks you to run commands unsandboxed (e.g., when sandbox denies something or network is required):
      - on-request (default): model decides when to ask.
      - on-failure: auto-run in sandbox; if it fails, ask to retry without sandbox.
      - unless-trusted: ask for untrusted commands.
      - never: never ask (fail fast and report back to the model).
  - Known-safe commands and user-approved commands may run without sandboxing to reduce friction.

  Useful Commands

  - Run under Seatbelt (macOS): codex debug seatbelt --full-auto -- rg foo
  - Run under Landlock (Linux): codex debug landlock --full-auto -- rg foo
  - Non-interactive agent run (honors sandbox settings): codex exec -c sandbox_mode=workspace-write -- <prompt or plan>

  Troubleshooting

  - Command fails but shouldn’t be sandboxed:
      - Use on-failure approval policy; Codex will propose retrying without sandbox on denial.
  - Needs network:
      - Set [sandbox_workspace_write].network_access = true or approve escalation when prompted.
  - Linux helper not found during dev:
      - Build codex-linux-sandbox and run via codex CLI; the multitool wires the path automatically.