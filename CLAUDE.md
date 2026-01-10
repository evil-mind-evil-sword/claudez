# claudez Development

Claude Code SDK for Zig. Wraps the `claude` CLI for programmatic access.

## Architecture

```
src/
├── root.zig        # Public API exports
├── transport.zig   # Subprocess management, threaded I/O
├── messages.zig    # Message types and JSON parsing
├── query.zig       # One-shot query interface
├── client.zig      # Streaming client with control protocol
├── hooks.zig       # Hook types (not yet integrated)
├── mcp.zig         # MCP server types (not yet integrated)
├── options.zig     # Configuration struct
└── errors.zig      # Error types

examples/
├── simple_query.zig  # One-shot query demo
└── streaming.zig     # Multi-turn conversation demo
```

## Key Patterns

### Memory Management

The codebase uses Zig 0.15's unmanaged ArrayList API:

```zig
// Correct pattern
var list: std.ArrayList(T) = .empty;
try list.append(allocator, item);
defer list.deinit(allocator);

// NOT the old managed pattern
var list = std.ArrayList(T).init(allocator);  // Wrong for 0.15
```

### JSON String Lifetimes

Message contents borrow from the JSON parser. The pattern:

1. Parse JSON into `std.json.Parsed(std.json.Value)`
2. Extract fields as borrowed slices
3. Keep parsed value alive while slices are in use
4. Free with `parsed.deinit()`

See `client.zig:Response` for proper lifetime management across multiple messages.

### Arena Allocators for Command Building

Transport uses an arena for CLI arguments (see `transport.zig:cmd_arena`). This handles the internal allocations from `Options.buildQueryCommand` which uses `std.mem.join` and `std.fmt.allocPrint`.

### Thread Safety

- `write_mutex` protects stdin writes
- `stderr_mutex` protects stderr buffer access
- `MessageQueue` is thread-safe for stdout reading

## Common Tasks

### Build and Test

```bash
zig build           # Build library and examples
zig build test      # Run all tests
```

### Add a New Option

1. Add field to `Options` struct in `options.zig`
2. Add CLI flag mapping in `appendCommonArgs`
3. Use `std.fmt.allocPrint` for numbers (arena handles cleanup)
4. Use `std.mem.join` for arrays

### Add a New Message Type

1. Define struct in `messages.zig`
2. Add variant to `Message` union
3. Add parsing case in `Message.fromJson`

### Modify Transport

Watch for:
- Arena lifetime (freed in `freeProcessArgs`)
- Thread join order (wait process before joining threads)
- Mutex usage for shared state

## Testing

Unit tests are in each source file. Integration tests require the Claude CLI.

```bash
# Run unit tests only (no CLI required)
zig build test

# Manual integration test
zig build && ./zig-out/bin/simple_query
```

## Error Handling

Errors bubble up as `ClaudeError` variants. Transport errors include:
- `CliNotFound` - claude binary not in PATH
- `ProcessCommunicationFailed` - pipe issues
- `JsonParseError` - malformed response
- `MalformedMessage` - unexpected message structure
