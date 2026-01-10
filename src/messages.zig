//! Message types for Claude SDK communication.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Text content block.
pub const TextBlock = struct {
    text: []const u8,
};

/// Thinking content block (extended thinking).
pub const ThinkingBlock = struct {
    thinking: []const u8,
    signature: ?[]const u8 = null,
};

/// Tool use request block.
pub const ToolUseBlock = struct {
    id: []const u8,
    name: []const u8,
    input: std.json.Value,
};

/// Tool result block.
pub const ToolResultBlock = struct {
    tool_use_id: []const u8,
    content: []const u8,
    is_error: bool = false,
};

/// Content block discriminated union.
/// Unknown content block for forward compatibility.
pub const UnknownBlock = struct {
    block_type: []const u8,
    data: std.json.Value,
};

pub const ContentBlock = union(enum) {
    text: TextBlock,
    thinking: ThinkingBlock,
    tool_use: ToolUseBlock,
    tool_result: ToolResultBlock,
    unknown: UnknownBlock,

    pub fn fromJson(_: Allocator, value: std.json.Value) !ContentBlock {
        const obj = value.object;
        const block_type = obj.get("type") orelse return error.MalformedMessage;

        const type_str = block_type.string;
        if (std.mem.eql(u8, type_str, "text")) {
            const text = obj.get("text") orelse return error.MalformedMessage;
            return .{ .text = .{ .text = text.string } };
        } else if (std.mem.eql(u8, type_str, "thinking")) {
            const thinking = obj.get("thinking") orelse return error.MalformedMessage;
            const signature = if (obj.get("signature")) |s| s.string else null;
            return .{ .thinking = .{
                .thinking = thinking.string,
                .signature = signature,
            } };
        } else if (std.mem.eql(u8, type_str, "tool_use")) {
            const id = obj.get("id") orelse return error.MalformedMessage;
            const name = obj.get("name") orelse return error.MalformedMessage;
            const input = obj.get("input") orelse return error.MalformedMessage;
            return .{ .tool_use = .{
                .id = id.string,
                .name = name.string,
                .input = input,
            } };
        } else if (std.mem.eql(u8, type_str, "tool_result")) {
            const tool_use_id = obj.get("tool_use_id") orelse return error.MalformedMessage;
            const content = obj.get("content") orelse return error.MalformedMessage;
            const is_error = if (obj.get("is_error")) |e| e.bool else false;
            // Content can be a string or an array of content blocks
            const content_str = switch (content) {
                .string => content.string,
                .array => blk: {
                    // Extract text from first text content block
                    for (content.array.items) |item| {
                        if (item == .object) {
                            if (item.object.get("type")) |t| {
                                if (t == .string and std.mem.eql(u8, t.string, "text")) {
                                    if (item.object.get("text")) |txt| {
                                        if (txt == .string) break :blk txt.string;
                                    }
                                }
                            }
                        }
                    }
                    break :blk "";
                },
                else => "",
            };
            return .{ .tool_result = .{
                .tool_use_id = tool_use_id.string,
                .content = content_str,
                .is_error = is_error,
            } };
        }

        // Unknown content block type - preserve for forward compatibility
        return .{ .unknown = .{
            .block_type = type_str,
            .data = value,
        } };
    }
};

/// User message from the conversation.
pub const UserMessage = struct {
    content: []const u8,
    uuid: ?[]const u8 = null,
    parent_tool_use_id: ?[]const u8 = null,
};

/// Assistant message with content blocks.
pub const AssistantMessage = struct {
    content: []ContentBlock,
    model: ?[]const u8 = null,
    is_error: bool = false,

    /// Free the content slice.
    pub fn deinit(self: AssistantMessage, allocator: Allocator) void {
        allocator.free(self.content);
    }
};

/// System message (e.g., init, error, etc.).
pub const SystemMessage = struct {
    subtype: []const u8,
    data: std.json.Value,
};

/// Result message indicating completion.
pub const ResultMessage = struct {
    total_cost_usd: f64 = 0,
    duration_ms: u64 = 0,
    duration_api_ms: u64 = 0,
    num_turns: u32 = 0,
    is_error: bool = false,
    session_id: ?[]const u8 = null,
};

/// Stream event types.
pub const StreamEventType = enum {
    content_block_start,
    content_block_delta,
    content_block_stop,
    message_start,
    message_delta,
    message_stop,
    input_json_delta,
    unknown,

    pub fn fromString(s: []const u8) StreamEventType {
        if (std.mem.eql(u8, s, "content_block_start")) return .content_block_start;
        if (std.mem.eql(u8, s, "content_block_delta")) return .content_block_delta;
        if (std.mem.eql(u8, s, "content_block_stop")) return .content_block_stop;
        if (std.mem.eql(u8, s, "message_start")) return .message_start;
        if (std.mem.eql(u8, s, "message_delta")) return .message_delta;
        if (std.mem.eql(u8, s, "message_stop")) return .message_stop;
        if (std.mem.eql(u8, s, "input_json_delta")) return .input_json_delta;
        return .unknown;
    }
};

/// Stream event for partial updates.
pub const StreamEvent = struct {
    event_type: []const u8,
    data: std.json.Value,

    /// Get the typed event kind.
    pub fn getType(self: StreamEvent) StreamEventType {
        return StreamEventType.fromString(self.event_type);
    }

    /// Get partial text from a content_block_delta event.
    /// Returns null if not a text delta.
    pub fn getTextDelta(self: StreamEvent) ?[]const u8 {
        if (!std.mem.eql(u8, self.event_type, "content_block_delta")) return null;

        const delta = self.data.object.get("delta") orelse return null;
        if (delta != .object) return null;

        const text = delta.object.get("text") orelse return null;
        return if (text == .string) text.string else null;
    }

    /// Get partial thinking from a content_block_delta event.
    /// Returns null if not a thinking delta.
    pub fn getThinkingDelta(self: StreamEvent) ?[]const u8 {
        if (!std.mem.eql(u8, self.event_type, "content_block_delta")) return null;

        const delta = self.data.object.get("delta") orelse return null;
        if (delta != .object) return null;

        const thinking = delta.object.get("thinking") orelse return null;
        return if (thinking == .string) thinking.string else null;
    }

    /// Get content block index from delta events.
    pub fn getIndex(self: StreamEvent) ?usize {
        const idx = self.data.object.get("index") orelse return null;
        return if (idx == .integer) @intCast(idx.integer) else null;
    }
};

/// Main message discriminated union.
pub const Message = union(enum) {
    user: UserMessage,
    assistant: AssistantMessage,
    system: SystemMessage,
    result: ResultMessage,
    stream_event: StreamEvent,

    /// Parse a message from JSON bytes.
    pub fn parse(allocator: Allocator, json_bytes: []const u8) !std.json.Parsed(std.json.Value) {
        return std.json.parseFromSlice(std.json.Value, allocator, json_bytes, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });
    }

    /// Free any allocations owned by this message.
    pub fn deinit(self: Message, allocator: Allocator) void {
        switch (self) {
            .assistant => |m| m.deinit(allocator),
            else => {},
        }
    }

    /// Convert parsed JSON value to a Message.
    pub fn fromJson(allocator: Allocator, value: std.json.Value) !Message {
        const obj = value.object;
        const msg_type = obj.get("type") orelse return error.MalformedMessage;

        const type_str = msg_type.string;

        if (std.mem.eql(u8, type_str, "user")) {
            const message = obj.get("message") orelse return error.MalformedMessage;
            const content = message.object.get("content") orelse return error.MalformedMessage;
            const uuid = if (obj.get("uuid")) |u| u.string else null;
            const parent = if (obj.get("parent_tool_use_id")) |p| if (p != .null) p.string else null else null;

            return .{ .user = .{
                .content = if (content == .string) content.string else "",
                .uuid = uuid,
                .parent_tool_use_id = parent,
            } };
        } else if (std.mem.eql(u8, type_str, "assistant")) {
            const message = obj.get("message") orelse return error.MalformedMessage;
            const content_array = message.object.get("content") orelse return error.MalformedMessage;
            const model = if (message.object.get("model")) |m| m.string else null;

            var blocks: std.ArrayList(ContentBlock) = .empty;
            errdefer blocks.deinit(allocator);

            for (content_array.array.items) |item| {
                const block = try ContentBlock.fromJson(allocator, item);
                try blocks.append(allocator, block);
            }

            return .{ .assistant = .{
                .content = try blocks.toOwnedSlice(allocator),
                .model = model,
                .is_error = if (obj.get("is_error")) |e| e.bool else false,
            } };
        } else if (std.mem.eql(u8, type_str, "system")) {
            const subtype = if (obj.get("subtype")) |s| s.string else "unknown";
            return .{ .system = .{
                .subtype = subtype,
                .data = value,
            } };
        } else if (std.mem.eql(u8, type_str, "result")) {
            return .{ .result = .{
                .total_cost_usd = if (obj.get("total_cost_usd")) |c| c.float else 0,
                .duration_ms = if (obj.get("duration_ms")) |d| std.math.cast(u64, d.integer) orelse 0 else 0,
                .duration_api_ms = if (obj.get("duration_api_ms")) |d| std.math.cast(u64, d.integer) orelse 0 else 0,
                .num_turns = if (obj.get("num_turns")) |n| std.math.cast(u32, n.integer) orelse 0 else 0,
                .is_error = if (obj.get("is_error")) |e| e.bool else false,
                .session_id = if (obj.get("session_id")) |s| s.string else null,
            } };
        } else if (std.mem.eql(u8, type_str, "stream_event")) {
            const subtype = if (obj.get("subtype")) |s| s.string else "unknown";
            return .{ .stream_event = .{
                .event_type = subtype,
                .data = value,
            } };
        }

        // Unknown message type - treat as system message
        return .{ .system = .{
            .subtype = type_str,
            .data = value,
        } };
    }
};

/// Extract the first text content block from an assistant message.
/// Returns an empty string if no text blocks are present.
/// For messages with multiple text blocks, iterate `msg.content` directly.
pub fn getTextContent(msg: AssistantMessage) []const u8 {
    for (msg.content) |block| {
        switch (block) {
            .text => |t| return t.text,
            else => {},
        }
    }
    return "";
}

/// Concatenate all text content blocks from an assistant message.
/// Caller owns the returned slice and must free it.
pub fn getAllTextContent(allocator: Allocator, msg: AssistantMessage) ![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    for (msg.content) |block| {
        switch (block) {
            .text => |t| try result.appendSlice(allocator, t.text),
            else => {},
        }
    }

    return result.toOwnedSlice(allocator);
}

/// Parse text content as JSON (for structured output).
/// Returns the parsed JSON value. Caller must call .deinit() when done.
pub fn parseJsonContent(allocator: Allocator, msg: AssistantMessage) !std.json.Parsed(std.json.Value) {
    const text = getTextContent(msg);
    if (text.len == 0) return error.MalformedMessage;

    return std.json.parseFromSlice(std.json.Value, allocator, text, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
}

/// Helper to get a string field from parsed JSON.
pub fn getJsonString(value: std.json.Value, field: []const u8) ?[]const u8 {
    if (value != .object) return null;
    const v = value.object.get(field) orelse return null;
    return if (v == .string) v.string else null;
}

/// Helper to get an integer field from parsed JSON.
pub fn getJsonInt(value: std.json.Value, field: []const u8) ?i64 {
    if (value != .object) return null;
    const v = value.object.get(field) orelse return null;
    return if (v == .integer) v.integer else null;
}

/// Helper to get a boolean field from parsed JSON.
pub fn getJsonBool(value: std.json.Value, field: []const u8) ?bool {
    if (value != .object) return null;
    const v = value.object.get(field) orelse return null;
    return if (v == .bool) v.bool else null;
}

test "parse text block" {
    const allocator = std.testing.allocator;
    const json =
        \\{"type": "text", "text": "Hello, world!"}
    ;

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();

    const block = try ContentBlock.fromJson(allocator, parsed.value);
    try std.testing.expectEqualStrings("Hello, world!", block.text.text);
}

test "json helpers" {
    const allocator = std.testing.allocator;
    const json =
        \\{"name": "test", "count": 42, "active": true}
    ;

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();

    try std.testing.expectEqualStrings("test", getJsonString(parsed.value, "name").?);
    try std.testing.expectEqual(@as(i64, 42), getJsonInt(parsed.value, "count").?);
    try std.testing.expect(getJsonBool(parsed.value, "active").?);
    try std.testing.expect(getJsonString(parsed.value, "missing") == null);
}
