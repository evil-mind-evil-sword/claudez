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
pub const ContentBlock = union(enum) {
    text: TextBlock,
    thinking: ThinkingBlock,
    tool_use: ToolUseBlock,
    tool_result: ToolResultBlock,

    pub fn fromJson(allocator: Allocator, value: std.json.Value) !ContentBlock {
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
            return .{ .tool_result = .{
                .tool_use_id = tool_use_id.string,
                .content = if (content == .string) content.string else "",
                .is_error = is_error,
            } };
        }

        return error.MalformedMessage;
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

/// Stream event for partial updates.
pub const StreamEvent = struct {
    event_type: []const u8,
    data: std.json.Value,
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

            var blocks = std.ArrayList(ContentBlock).init(allocator);
            errdefer blocks.deinit();

            for (content_array.array.items) |item| {
                const block = try ContentBlock.fromJson(allocator, item);
                try blocks.append(block);
            }

            return .{ .assistant = .{
                .content = try blocks.toOwnedSlice(),
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
                .duration_ms = if (obj.get("duration_ms")) |d| @intCast(d.integer) else 0,
                .duration_api_ms = if (obj.get("duration_api_ms")) |d| @intCast(d.integer) else 0,
                .num_turns = if (obj.get("num_turns")) |n| @intCast(n.integer) else 0,
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

/// Extract text content from an assistant message.
pub fn getTextContent(msg: AssistantMessage) []const u8 {
    for (msg.content) |block| {
        switch (block) {
            .text => |t| return t.text,
            else => {},
        }
    }
    return "";
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
