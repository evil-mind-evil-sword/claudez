//! In-process MCP server support for custom tools.
//!
//! NOTE: These types are exported but not yet integrated into Client or QueryIterator.
//! See README.md "Planned Features" section.

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

    pub fn err(message: []const u8) ToolResult {
        return .{
            .content = &[_]ContentItem{ContentItem.textContent(message)},
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
                try std.json.stringify(schema, .{}, writer);
            }

            try writer.writeByte('}');
        }

        try writer.writeAll("]}");
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
