# claudez

Zig SDK for Claude Code. Embed Claude's agentic capabilities in Zig applications.

## What It Does

claudez wraps the Claude Code CLI to provide programmatic access from Zig. The SDK spawns `claude` as a subprocess and communicates via NDJSON streaming, giving you:

- **One-shot queries** — Send a prompt, iterate over responses
- **Streaming client** — Multi-turn conversations with session continuity

## Requirements

- Zig 0.15.0 or later
- Claude Code CLI installed (`claude` in PATH)

## Installation

Add to `build.zig.zon`:

```zig
.dependencies = .{
    .claudez = .{
        .url = "https://github.com/evil-mind-evil-sword/claudez/archive/main.tar.gz",
        // Run `zig fetch <url>` to get the hash, then add:
        // .hash = "...",
    },
},
```

Then in `build.zig`:

```zig
const claudez_dep = b.dependency("claudez", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("claudez", claudez_dep.module("claudez"));
```

## Usage

### One-Shot Query

The simplest way to interact with Claude. Send a prompt, receive messages until completion.

```zig
const std = @import("std");
const claudez = @import("claudez");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Query with options
    var iter = try claudez.query(allocator, "What is 2+2?", .{
        .max_turns = 1,
    });
    defer iter.deinit();

    // Process response messages
    while (try iter.next()) |msg| {
        switch (msg) {
            .assistant => |m| {
                for (m.content) |block| {
                    if (block == .text) {
                        std.debug.print("{s}", .{block.text.text});
                    }
                }
            },
            .result => |r| {
                std.debug.print("\nCost: ${d:.4}\n", .{r.total_cost_usd});
            },
            else => {},
        }
    }
}
```

For simple text extraction:

```zig
const response = try claudez.queryText(allocator, "What is 2+2?", null);
defer allocator.free(response);
std.debug.print("{s}\n", .{response});
```

### Streaming Client

For multi-turn conversations, the streaming client maintains session state between queries.

```zig
var client = try claudez.Client.init(allocator, .{
    .permission_mode = .accept_edits,
    .max_turns = 10,
});
defer client.deinit();

try client.connect();

// First turn
try client.query("Hello, my name is Alice.");
var response1 = try client.receiveResponse();
defer response1.deinit();

for (response1.messages) |msg| {
    // Process messages...
}

// Second turn (Claude remembers the conversation)
try client.query("What's my name?");
var response2 = try client.receiveResponse();
defer response2.deinit();
```

### Configuration Options

The `Options` struct controls Claude's behavior:

```zig
const opts = claudez.Options{
    // Model selection
    .model = "claude-sonnet-4-5",
    .fallback_model = "claude-haiku-4",

    // Limits
    .max_turns = 10,
    .max_budget_usd = 1.0,

    // System prompt
    .system_prompt = .{ .custom = "You are a helpful coding assistant." },
    // Or: .system_prompt = .{ .append = "Additional context..." },
    // Or: .system_prompt = .empty,

    // Tool control
    .tools = &.{ "Read", "Write", "Bash" },
    .allowed_tools = &.{ "Read" },      // Whitelist
    .disallowed_tools = &.{ "Bash" },   // Blacklist

    // Permissions
    .permission_mode = .accept_edits,   // .default, .plan, .bypass_permissions

    // Session management
    .continue_conversation = true,
    .resume_session = "session-id",

    // Advanced
    .max_thinking_tokens = 10000,
    .mcp_config = "/path/to/mcp.json",
    .add_dirs = &.{ "/allowed/path" },
};
```

## Memory Ownership

Message contents are borrowed from the JSON parser. Their lifetime depends on how you obtain them:

| Method | Content Valid Until |
|--------|---------------------|
| `QueryIterator.next()` | Next `next()` call |
| `Client.receiveMessage()` | Next `receiveMessage()` call |
| `Client.receiveResponse()` | `response.deinit()` |

Copy strings with `allocator.dupe(u8, text)` if you need them longer.

## API Reference

### Core Functions

| Function | Description |
|----------|-------------|
| `query(allocator, prompt, options)` | One-shot query, returns message iterator |
| `queryText(allocator, prompt, options)` | One-shot query, returns combined text |

### Client Methods

| Method | Description |
|--------|-------------|
| `Client.init(allocator, options)` | Create streaming client |
| `client.connect()` | Connect to Claude |
| `client.query(prompt)` | Send query in current session |
| `client.receiveMessage()` | Receive single message (blocks) |
| `client.receiveResponse()` | Receive all messages until result |
| `client.interrupt()` | Send interrupt signal |
| `client.setPermissionMode(mode)` | Change permission mode |
| `client.setModel(model)` | Switch model mid-session |
| `client.disconnect()` | Disconnect from Claude |
| `client.deinit()` | Clean up resources |

### Message Types

```zig
const Message = union(enum) {
    user: UserMessage,
    assistant: AssistantMessage,
    system: SystemMessage,
    result: ResultMessage,
    stream_event: StreamEvent,
};

const ContentBlock = union(enum) {
    text: TextBlock,
    thinking: ThinkingBlock,
    tool_use: ToolUseBlock,
    tool_result: ToolResultBlock,
};
```

## Examples

Build and run the included examples:

```bash
zig build
./zig-out/bin/simple_query
./zig-out/bin/streaming
```

## Planned Features

The following types are exported but not yet integrated into the Client/Query interfaces:

- **Hooks** — `HookConfig`, `HookEvent` for intercepting tool operations
- **MCP Tools** — `McpServer`, `Tool` for custom in-process tools

## License

MIT
