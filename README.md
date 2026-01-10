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

// Save session for later
try client.saveSession(".session");
```

### Session Persistence

Resume conversations across process restarts:

```zig
// Later, in a new process
const session_id = try claudez.Client.loadSession(allocator, ".session");
defer allocator.free(session_id);

var client = try claudez.Client.init(allocator, .{
    .resume_session = session_id,
});
defer client.deinit();

try client.connect();
try client.query("Continue our conversation...");
```

### Structured Output

Use JSON schema to constrain Claude's response format:

```zig
const schema =
    \\{"type": "object", "properties": {"answer": {"type": "integer"}}, "required": ["answer"]}
;

var iter = try claudez.query(allocator, "What is 2+2?", .{
    .json_schema = schema,
});
defer iter.deinit();

while (try iter.next()) |msg| {
    if (msg == .assistant) {
        var parsed = try claudez.parseJsonContent(allocator, msg.assistant);
        defer parsed.deinit();

        const answer = claudez.getJsonInt(parsed.value, "answer");
        std.debug.print("Answer: {d}\n", .{answer.?});
    }
}
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
| `client.setHooks(config)` | Set hook config for tool interception |
| `client.setCwd(path)` | Set working directory for hook inputs |
| `client.getSessionId()` | Get current session ID for persistence |
| `client.saveSession(path)` | Save session ID to file |
| `Client.loadSession(alloc, path)` | Load session ID from file |
| `client.reconnect()` | Reconnect to existing session after disconnect |

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

### Streaming Events

Handle partial messages for real-time output:

```zig
// Enable partial messages
var iter = try claudez.query(allocator, "Write a poem", .{
    .include_partial_messages = true,
});
defer iter.deinit();

while (try iter.next()) |msg| {
    if (msg == .stream_event) {
        const event = msg.stream_event;

        switch (event.getType()) {
            .content_block_delta => {
                if (event.getTextDelta()) |text| {
                    std.debug.print("{s}", .{text}); // Print as it arrives
                }
            },
            else => {},
        }
    }
}
```

## Examples

Build and run the included examples:

```bash
zig build
./zig-out/bin/simple_query
./zig-out/bin/streaming
```

## Hooks

Intercept and control Claude's tool usage with hooks. Register callbacks that run before tool execution.

```zig
const claudez = @import("claudez");

// Define a hook callback
fn myHook(input: claudez.HookInput, context: ?*anyopaque) claudez.HookOutput {
    _ = context;
    if (input == .pre_tool_use) {
        const tool_name = input.pre_tool_use.tool_name;
        if (std.mem.eql(u8, tool_name, "Bash")) {
            // Block Bash tool
            return claudez.HookOutput.deny("Bash not allowed");
        }
    }
    return claudez.HookOutput.approve();
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    // Create hook config
    var hooks = claudez.HookConfig.init(allocator);
    defer hooks.deinit();

    try hooks.addHook(.pre_tool_use, .{
        .callback = myHook,
        .matcher = null, // Match all tools (or "Bash" for specific tool)
    });

    // Use with streaming client
    var client = try claudez.Client.init(allocator, null);
    defer client.deinit();

    client.setHooks(&hooks);
    try client.connect();
    // ... tool calls will now be intercepted
}
```

### Hook Events

| Event | Trigger |
|-------|---------|
| `pre_tool_use` | Before tool execution |
| `post_tool_use` | After tool execution |
| `user_prompt_submit` | When user submits a prompt |
| `stop` | When agent is about to stop |
| `subagent_stop` | When subagent is about to stop |
| `pre_compact` | Before context compaction |

### Hook Outputs

| Output | Effect |
|--------|--------|
| `HookOutput.approve()` | Allow the operation |
| `HookOutput.deny(reason)` | Block with permission denied |
| `HookOutput.block(reason)` | Block and stop execution |

## MCP Server

Create custom tools that Claude can invoke. The MCP server runs as a subprocess, communicating via JSON-RPC over stdio.

```zig
const std = @import("std");
const mcp = @import("claudez").mcp;

fn greetHandler(args: std.json.Value, ctx: *mcp.ToolContext) mcp.ToolResult {
    _ = ctx;
    const name = if (args.object.get("name")) |n| n.string else "World";

    // Return text content
    const content = [_]mcp.ContentItem{
        mcp.ContentItem.textContent("Hello, " ++ name ++ "!"),
    };
    return mcp.ToolResult.success(&content);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var server = mcp.McpServer.init(allocator, "my-tools", "1.0.0");
    defer server.deinit();

    try server.addTool(.{
        .name = "greet",
        .description = "Greet someone by name",
        .handler = greetHandler,
    });

    // Run the stdio loop (blocks until stdin closes)
    try server.run();
}
```

Configure Claude to use your MCP server via `--mcp-config`:

```json
{
  "mcpServers": {
    "my-tools": {
      "command": "./zig-out/bin/my-mcp-server"
    }
  }
}
```

## License

MIT
