# Contract: Provider Interface (`provider/provider.zig`)

All model backends sit behind one interface so the executor (high-level policy)
depends only on the abstraction (DIP, Principle II) and all five providers are
interchangeable (LSP, Principle I.3).

## Interface (vtable / function-pointer struct)

```
Provider = struct {
    ctx: *anyopaque,
    vtable: *const VTable,
};
VTable = struct {
    complete: fn (ctx: *anyopaque, alloc: Allocator, req: CompletionRequest) anyerror!ChatResponse,
    name: fn (ctx: *anyopaque) []const u8,
};
```

## CompletionRequest

```
CompletionRequest = struct {
    messages: []const ChatMessage,
    tools: []const ToolSpec,        // schemas exposed to the model
    budget_tokens: ?u64,
};
ToolSpec = struct { name: []const u8, description: []const u8, parameters_json_schema: []const u8 };
```

## ChatMessage / ChatResponse

```
ChatMessage = struct {
    role: enum { system, user, assistant, tool },
    content: []const u8,
    tool_calls: ?[]const ToolCall,
    tool_call_id: ?[]const u8,
};
ToolCall = struct { id: []const u8, name: []const u8, arguments_json: []const u8 };
ChatResponse = struct { message: ChatMessage, finish_reason: enum { stop, tool_calls, length } };
```

## Implementations

- `OpenAIProvider` (`provider/openai.zig`): real client over `transport.Transport`
  (OpenAI-compatible Chat Completions). This is the reference client (spec 004).
- Five **presets** (`provider/presets.zig`): opencode, kilo, z.ai, kimi,
  openai_custom — each constructs an `OpenAIProvider` with its endpoint/model
  defaults (FR-004). No branching; OCP (Principle III).
- `FakeProvider` (`provider/fake.zig`): scripted responses for tests/e2e
  (Principle V). Returns deterministic `ChatResponse` sequences so the executor
  loop is verified without network.

## Behavioral guarantees (LSP)

Every implementation MUST return a well-formed `ChatResponse` for the same
`CompletionRequest`; a provider that throws "unsupported" for a method others
implement is a violation. `GoalExecutor` MUST behave identically regardless of
which provider is active.
