# claudez

Claude Code SDK for Zig - programmatic access to Claude's agentic capabilities.

## Overview

claudez wraps the Claude Code CLI, providing a native Zig interface for:

- **One-shot queries** - Simple fire-and-forget interactions
- **Streaming client** - Bidirectional conversations with control protocol
- **Hooks** - Intercept and control Claude's operations
- **MCP servers** - Define custom in-process tools

## Requirements

- Zig 0.15.0+
- Claude Code CLI (`claude`) installed and in PATH

## Installation

Add as a dependency in `build.zig.zon`:

```zig
.dependencies = .{
    .claudez = .{
        .url = "https://github.com/evil-mind-evil-sword/claudez/archive/main.tar.gz",
    },
},
```

Then in `build.zig`:

```zig
const claudez = b.dependency("claudez", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("claudez", claudez.module("claudez"));
```

## Quick Start

### One-shot Query

```zig
const claudez = @import("claudez");

var iter = try claudez.query(allocator, "What is 2+2?", null);
defer iter.deinit();

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
```

### Streaming Client

```zig
var client = try claudez.Client.init(allocator, .{
    .permission_mode = .accept_edits,
    .max_turns = 10,
});
defer client.deinit();

try client.connect();
try client.query("Hello!");

for (try client.receiveResponse()) |msg| {
    // Process messages
}
```

### Custom Options

```zig
const opts = claudez.Options{
    .model = "claude-sonnet-4-5",
    .max_turns = 5,
    .max_budget_usd = 1.0,
    .system_prompt = .{ .custom = "You are a helpful assistant." },
    .allowed_tools = &.{ "Read", "Write" },
    .permission_mode = .accept_edits,
};

var iter = try claudez.query(allocator, "Help me code", opts);
```

## API Reference

### Core Types

- `Options` - Configuration for Claude interactions
- `Message` - Discriminated union of message types
- `ContentBlock` - Text, thinking, tool_use, or tool_result

### Functions

- `query(allocator, prompt, options)` - One-shot query returning message iterator
- `queryText(allocator, prompt, options)` - One-shot query returning combined text

### Client

- `Client.init(allocator, options)` - Create streaming client
- `client.connect()` - Connect to Claude
- `client.query(prompt)` - Send a query
- `client.receiveMessages()` - Iterator over all messages
- `client.receiveResponse()` - Receive until ResultMessage
- `client.interrupt()` - Send interrupt signal
- `client.setPermissionMode(mode)` - Change permission mode
- `client.setModel(model)` - Change model
- `client.disconnect()` - Disconnect
- `client.deinit()` - Clean up

### Hooks

- `HookConfig.init(allocator)` - Create hook configuration
- `hookConfig.addHook(event, matcher)` - Register hook
- `hookConfig.invokeHooks(input)` - Invoke matching hooks

### MCP

- `createSdkMcpServer(allocator, name, version, tools)` - Create MCP server
- `server.addTool(tool)` - Register tool
- `server.invokeTool(name, args, context)` - Invoke tool

## Examples

See `examples/` directory:

- `simple_query.zig` - Basic one-shot query
- `streaming.zig` - Multi-turn streaming conversation

Build and run:

```bash
zig build
./zig-out/bin/simple_query
./zig-out/bin/streaming
```

## License

MIT
