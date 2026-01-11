//! In-process MCP server support for custom tools.
//!
//! Provides an MCP server that can be run as a subprocess, communicating via
//! JSON-RPC over stdio. Use `McpServer.run()` to start the server loop.
//!
//! ## Example
//!
//! ```zig
//! const mcp = @import("claudez").mcp;
//!
//! fn myToolHandler(args: std.json.Value, ctx: *mcp.ToolContext) mcp.ToolResult {
//!     // Success: content array on stack is fine since it's used before function returns
//!     const content = [_]mcp.ContentItem{mcp.ContentItem.textContent("Hello!")};
//!     return mcp.ToolResult.success(&content);
//! }
//!
//! fn myToolWithError(args: std.json.Value, ctx: *mcp.ToolContext) mcp.ToolResult {
//!     // Error: use ctx.makeError() which stores content in the context (safe lifetime)
//!     return ctx.makeError("Something went wrong");
//! }
//!
//! pub fn main() !void {
//!     var server = mcp.McpServer.init(allocator, "my-server", "1.0.0");
//!     try server.addTool(.{
//!         .name = "greet",
//!         .description = "Say hello",
//!         .handler = myToolHandler,
//!     });
//!     try server.run();
//! }
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Tool result content type.
pub const ContentType = enum {
    text,
    image,
    resource,
};

/// Tool result content item.
pub const ContentItem = union(ContentType) {
    text: struct {
        text: []const u8,
    },
    image: struct {
        data: []const u8,
        mime_type: []const u8,
    },
    resource: struct {
        uri: []const u8,
        mime_type: ?[]const u8,
        text: ?[]const u8,
    },

    pub fn textContent(text: []const u8) ContentItem {
        return .{ .text = .{ .text = text } };
    }

    pub fn imageContent(data: []const u8, mime_type: []const u8) ContentItem {
        return .{ .image = .{ .data = data, .mime_type = mime_type } };
    }
};

/// Result from a tool invocation.
pub const ToolResult = struct {
    content: []const ContentItem,
    is_error: bool = false,

    pub fn success(content: []const ContentItem) ToolResult {
        return .{ .content = content };
    }

    /// Create an error result from caller-provided content.
    /// The content slice must outlive the ToolResult.
    /// For convenience in handlers, use `ToolContext.makeError()` instead.
    pub fn errFrom(content: []const ContentItem) ToolResult {
        return .{
            .content = content,
            .is_error = true,
        };
    }

    /// Write the result as JSON.
    pub fn writeJson(self: ToolResult, writer: anytype) !void {
        try writer.writeAll("{\"content\":[");

        for (self.content, 0..) |item, i| {
            if (i > 0) try writer.writeByte(',');

            switch (item) {
                .text => |t| {
                    try writer.writeAll("{\"type\":\"text\",\"text\":\"");
                    try writeEscapedJson(t.text, writer);
                    try writer.writeAll("\"}");
                },
                .image => |img| {
                    // Note: img.data should be base64 encoded by the caller
                    try writer.writeAll("{\"type\":\"image\",\"data\":\"");
                    try writeEscapedJson(img.data, writer);
                    try writer.writeAll("\",\"mimeType\":\"");
                    try writeEscapedJson(img.mime_type, writer);
                    try writer.writeAll("\"}");
                },
                .resource => |r| {
                    try writer.writeAll("{\"type\":\"resource\",\"uri\":\"");
                    try writeEscapedJson(r.uri, writer);
                    try writer.writeAll("\"");
                    if (r.mime_type) |mt| {
                        try writer.writeAll(",\"mimeType\":\"");
                        try writeEscapedJson(mt, writer);
                        try writer.writeAll("\"");
                    }
                    if (r.text) |t| {
                        try writer.writeAll(",\"text\":\"");
                        try writeEscapedJson(t, writer);
                        try writer.writeAll("\"");
                    }
                    try writer.writeByte('}');
                },
            }
        }

        try writer.writeByte(']');

        if (self.is_error) {
            try writer.writeAll(",\"is_error\":true");
        }

        try writer.writeByte('}');
    }
};

/// Context passed to tool handlers.
pub const ToolContext = struct {
    allocator: Allocator,
    session_id: ?[]const u8 = null,
    cwd: ?[]const u8 = null,

    /// Storage for error content. Handlers should use `makeError()` instead of
    /// constructing ToolResult directly to avoid dangling pointer issues.
    error_content: [1]ContentItem = undefined,

    /// Create an error ToolResult safely. The error content array is stored in
    /// the context, which outlives the returned ToolResult.
    ///
    /// IMPORTANT: The `message` slice must outlive the ToolResult. This is satisfied
    /// when using string literals (recommended) or strings from longer-lived sources.
    /// Do NOT use stack-allocated buffers (e.g., from `bufPrint`) for the message.
    pub fn makeError(self: *ToolContext, message: []const u8) ToolResult {
        self.error_content[0] = ContentItem.textContent(message);
        return .{
            .content = &self.error_content,
            .is_error = true,
        };
    }
};

/// Tool handler function type.
pub const ToolHandler = *const fn (args: std.json.Value, context: *ToolContext) ToolResult;

/// Tool definition.
pub const Tool = struct {
    name: []const u8,
    description: []const u8,
    input_schema: ?std.json.Value = null,
    handler: ToolHandler,
};

/// SDK MCP Server for hosting custom tools.
pub const McpServer = struct {
    allocator: Allocator,
    name: []const u8,
    version: []const u8,
    tools: std.StringHashMap(Tool),

    pub fn init(allocator: Allocator, name: []const u8, version: []const u8) McpServer {
        return .{
            .allocator = allocator,
            .name = name,
            .version = version,
            .tools = std.StringHashMap(Tool).init(allocator),
        };
    }

    pub fn deinit(self: *McpServer) void {
        self.tools.deinit();
    }

    /// Register a tool with the server.
    pub fn addTool(self: *McpServer, tool: Tool) !void {
        try self.tools.put(tool.name, tool);
    }

    /// Invoke a tool by name.
    pub fn invokeTool(self: *McpServer, name: []const u8, args: std.json.Value, context: *ToolContext) ?ToolResult {
        if (self.tools.get(name)) |tool| {
            return tool.handler(args, context);
        }
        return null;
    }

    /// Get list of tool names.
    pub fn listTools(self: *McpServer, allocator: Allocator) ![]const []const u8 {
        // In Zig 0.15, ArrayList is unmanaged
        var list: std.ArrayList([]const u8) = .empty;
        var iter = self.tools.iterator();
        while (iter.next()) |entry| {
            try list.append(allocator, entry.key_ptr.*);
        }
        return list.toOwnedSlice(allocator);
    }

    /// Generate MCP tool list JSON.
    pub fn writeToolsJson(self: *McpServer, writer: anytype) !void {
        try writer.writeAll("{\"tools\":[");

        var first = true;
        var iter = self.tools.iterator();
        while (iter.next()) |entry| {
            if (!first) try writer.writeByte(',');
            first = false;

            const tool = entry.value_ptr.*;
            try writer.writeAll("{\"name\":\"");
            try writeEscapedJson(tool.name, writer);
            try writer.writeAll("\",\"description\":\"");
            try writeEscapedJson(tool.description, writer);
            try writer.writeAll("\"");

            if (tool.input_schema) |schema| {
                try writer.writeAll(",\"inputSchema\":");
                try std.json.fmt(schema, .{}).format(writer);
            }

            try writer.writeByte('}');
        }

        try writer.writeAll("]}");
    }

    /// Run the MCP server, reading JSON-RPC requests from stdin and writing responses to stdout.
    /// This blocks until stdin is closed or an error occurs.
    ///
    /// Note: Individual JSON-RPC messages are limited to 64KB. For tools with larger
    /// inputs/outputs, consider streaming or chunking the data.
    pub fn run(self: *McpServer) !void {
        return self.runWithFds(std.posix.STDIN_FILENO, std.posix.STDOUT_FILENO);
    }

    /// Run the MCP server with custom file descriptors.
    /// This allows embedding the MCP server in-process using pipes or socketpair.
    ///
    /// For embedded use with socketpair:
    /// ```zig
    /// const fds = try std.posix.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0);
    /// // fds[0] -> MCP server (pass to runWithFds)
    /// // fds[1] -> client side
    /// const thread = try std.Thread.spawn(.{}, runMcpServer, .{server, fds[0], fds[0]});
    /// ```
    pub fn runWithFds(self: *McpServer, read_fd: std.posix.fd_t, write_fd: std.posix.fd_t) !void {
        const read_file = std.fs.File{ .handle = read_fd };
        const write_file = std.fs.File{ .handle = write_fd };

        var write_buf: [64 * 1024]u8 = undefined;
        var file_writer = write_file.writer(&write_buf);
        const writer = &file_writer.interface;

        var line_buf: [64 * 1024]u8 = undefined;
        var line_len: usize = 0;

        while (true) {
            // Read bytes until we get a newline or EOF
            const maybe_line = readLine(read_file, &line_buf, &line_len) catch |err| {
                if (err == error.EndOfStream) break;
                return err;
            };

            const line = maybe_line orelse break; // EOF
            if (line.len == 0) continue;

            self.handleRequest(line, writer) catch |err| {
                // Write error response for parse/internal errors
                self.writeError(writer, null, -32700, "Parse error", @errorName(err)) catch {};
            };
            writer.flush() catch {};
        }
    }

    /// Read a line from the file, returning the line without the newline.
    /// Returns null on EOF, error on read failure.
    fn readLine(file: std.fs.File, buf: []u8, len: *usize) !?[]const u8 {
        while (len.* < buf.len) {
            var byte_buf: [1]u8 = undefined;
            const bytes_read = file.read(&byte_buf) catch |err| {
                return err;
            };

            if (bytes_read == 0) {
                // EOF
                if (len.* > 0) {
                    const result = buf[0..len.*];
                    len.* = 0;
                    return result;
                }
                return null;
            }

            if (byte_buf[0] == '\n') {
                const result = buf[0..len.*];
                len.* = 0;
                return result;
            }

            buf[len.*] = byte_buf[0];
            len.* += 1;
        }

        // Line too long - return what we have
        const result = buf[0..len.*];
        len.* = 0;
        return result;
    }

    fn handleRequest(self: *McpServer, line: []const u8, writer: anytype) !void {
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, line, .{}) catch {
            return self.writeError(writer, null, -32700, "Parse error", null);
        };
        defer parsed.deinit();

        const obj = parsed.value.object;
        const id = obj.get("id");
        const method = obj.get("method") orelse {
            return self.writeError(writer, id, -32600, "Invalid Request", "Missing method");
        };

        if (method != .string) {
            return self.writeError(writer, id, -32600, "Invalid Request", "Method must be string");
        }

        // Use null for missing params instead of allocating an ObjectMap that would leak
        const params = obj.get("params") orelse std.json.Value{ .null = {} };

        if (std.mem.eql(u8, method.string, "initialize")) {
            try self.handleInitialize(writer, id);
        } else if (std.mem.eql(u8, method.string, "tools/list")) {
            try self.handleToolsList(writer, id);
        } else if (std.mem.eql(u8, method.string, "tools/call")) {
            try self.handleToolsCall(writer, id, params);
        } else if (std.mem.eql(u8, method.string, "notifications/initialized")) {
            // Notification, no response needed
        } else {
            try self.writeError(writer, id, -32601, "Method not found", method.string);
        }
    }

    fn handleInitialize(self: *McpServer, writer: anytype, id: ?std.json.Value) !void {
        try writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
        try self.writeJsonValue(writer, id);
        try writer.writeAll(",\"result\":{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{\"tools\":{}},\"serverInfo\":{\"name\":\"");
        try writeEscapedJson(self.name, writer);
        try writer.writeAll("\",\"version\":\"");
        try writeEscapedJson(self.version, writer);
        try writer.writeAll("\"}}}\n");
    }

    fn handleToolsList(self: *McpServer, writer: anytype, id: ?std.json.Value) !void {
        try writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
        try self.writeJsonValue(writer, id);
        try writer.writeAll(",\"result\":");
        try self.writeToolsJson(writer);
        try writer.writeAll("}\n");
    }

    fn handleToolsCall(self: *McpServer, writer: anytype, id: ?std.json.Value, params: std.json.Value) !void {
        const params_obj = if (params == .object) params.object else {
            return self.writeError(writer, id, -32602, "Invalid params", "Expected object");
        };

        const name_val = params_obj.get("name") orelse {
            return self.writeError(writer, id, -32602, "Invalid params", "Missing tool name");
        };
        if (name_val != .string) {
            return self.writeError(writer, id, -32602, "Invalid params", "Tool name must be string");
        }

        // Use null for missing arguments instead of allocating an ObjectMap that would leak
        const args = params_obj.get("arguments") orelse std.json.Value{ .null = {} };

        var context = ToolContext{
            .allocator = self.allocator,
        };

        if (self.invokeTool(name_val.string, args, &context)) |result| {
            try writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
            try self.writeJsonValue(writer, id);
            try writer.writeAll(",\"result\":");
            try result.writeJson(writer);
            try writer.writeAll("}\n");
        } else {
            try self.writeError(writer, id, -32602, "Unknown tool", name_val.string);
        }
    }

    fn writeError(self: *McpServer, writer: anytype, id: ?std.json.Value, code: i32, message: []const u8, data: ?[]const u8) !void {
        _ = self;
        try writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
        if (id) |i| {
            try std.json.fmt(i, .{}).format(writer);
        } else {
            try writer.writeAll("null");
        }
        try writer.print(",\"error\":{{\"code\":{d},\"message\":\"", .{code});
        try writeEscapedJson(message, writer);
        try writer.writeAll("\"");
        if (data) |d| {
            try writer.writeAll(",\"data\":\"");
            try writeEscapedJson(d, writer);
            try writer.writeAll("\"");
        }
        try writer.writeAll("}}\n");
    }

    fn writeJsonValue(self: *McpServer, writer: anytype, value: ?std.json.Value) !void {
        _ = self;
        if (value) |v| {
            try std.json.fmt(v, .{}).format(writer);
        } else {
            try writer.writeAll("null");
        }
    }
};

/// Create an SDK MCP server with tools.
pub fn createSdkMcpServer(
    allocator: Allocator,
    name: []const u8,
    version: []const u8,
    tools: []const Tool,
) !McpServer {
    var server = McpServer.init(allocator, name, version);
    errdefer server.deinit();

    for (tools) |tool| {
        try server.addTool(tool);
    }

    return server;
}

fn writeEscapedJson(s: []const u8, writer: anytype) !void {
    for (s) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => if (c < 0x20) {
                try writer.print("\\u{x:0>4}", .{c});
            } else {
                try writer.writeByte(c);
            },
        }
    }
}

test "tool result json" {
    var buf: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);

    const content = [_]ContentItem{ContentItem.textContent("Hello!")};
    const result = ToolResult.success(&content);
    try result.writeJson(stream.writer());

    const expected =
        \\{"content":[{"type":"text","text":"Hello!"}]}
    ;
    try std.testing.expectEqualStrings(expected, stream.getWritten());
}
