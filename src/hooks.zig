//! Hook system for intercepting Claude operations.
//!
//! NOTE: These types are exported but not yet integrated into Client or QueryIterator.
//! See README.md "Planned Features" section.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Hook event types.
pub const HookEvent = enum {
    pre_tool_use,
    post_tool_use,
    user_prompt_submit,
    stop,
    subagent_stop,
    pre_compact,

    pub fn toCliName(self: HookEvent) []const u8 {
        return switch (self) {
            .pre_tool_use => "PreToolUse",
            .post_tool_use => "PostToolUse",
            .user_prompt_submit => "UserPromptSubmit",
            .stop => "Stop",
            .subagent_stop => "SubagentStop",
            .pre_compact => "PreCompact",
        };
    }
};

/// Pre-tool-use hook input.
pub const PreToolUseInput = struct {
    session_id: []const u8,
    cwd: []const u8,
    tool_name: []const u8,
    tool_input: std.json.Value,
};

/// Post-tool-use hook input.
pub const PostToolUseInput = struct {
    session_id: []const u8,
    cwd: []const u8,
    tool_name: []const u8,
    tool_input: std.json.Value,
    tool_response: std.json.Value,
};

/// User prompt submit hook input.
pub const UserPromptSubmitInput = struct {
    session_id: []const u8,
    cwd: []const u8,
    prompt: []const u8,
};

/// Stop hook input.
pub const StopInput = struct {
    session_id: []const u8,
    cwd: []const u8,
    stop_hook_active: bool,
};

/// Hook input discriminated union.
pub const HookInput = union(HookEvent) {
    pre_tool_use: PreToolUseInput,
    post_tool_use: PostToolUseInput,
    user_prompt_submit: UserPromptSubmitInput,
    stop: StopInput,
    subagent_stop: StopInput,
    pre_compact: struct {
        session_id: []const u8,
        cwd: []const u8,
        trigger: []const u8,
    },
};

/// Permission decision for tool use.
pub const PermissionDecision = enum {
    allow,
    deny,
    ask,

    pub fn toJson(self: PermissionDecision) []const u8 {
        return @tagName(self);
    }
};

/// Hook output for controlling Claude's behavior.
pub const HookOutput = struct {
    /// Whether to continue execution.
    continue_execution: bool = true,
    /// Whether to suppress output.
    suppress_output: bool = false,
    /// Reason for stopping.
    stop_reason: ?[]const u8 = null,
    /// Block decision.
    decision: ?enum { block } = null,
    /// System message to inject.
    system_message: ?[]const u8 = null,
    /// Reason for the decision.
    reason: ?[]const u8 = null,
    /// Permission decision (for PreToolUse).
    permission_decision: ?PermissionDecision = null,
    /// Additional context (for PostToolUse).
    additional_context: ?[]const u8 = null,

    /// Create an approving output.
    pub fn approve() HookOutput {
        return .{};
    }

    /// Create a blocking output.
    pub fn block(reason: []const u8) HookOutput {
        return .{
            .continue_execution = false,
            .decision = .block,
            .reason = reason,
        };
    }

    /// Create a deny permission output.
    pub fn deny(reason: []const u8) HookOutput {
        return .{
            .permission_decision = .deny,
            .reason = reason,
        };
    }

    /// Write the output as JSON.
    pub fn writeJson(self: HookOutput, writer: anytype) !void {
        try writer.writeByte('{');
        var first = true;

        if (!self.continue_execution) {
            try writer.writeAll("\"continue\":false");
            first = false;
        }

        if (self.suppress_output) {
            if (!first) try writer.writeByte(',');
            try writer.writeAll("\"suppressOutput\":true");
            first = false;
        }

        if (self.stop_reason) |reason| {
            if (!first) try writer.writeByte(',');
            try writer.writeAll("\"stopReason\":\"");
            try writeEscapedJson(reason, writer);
            try writer.writeByte('"');
            first = false;
        }

        if (self.decision) |d| {
            if (!first) try writer.writeByte(',');
            try writer.writeAll("\"decision\":\"");
            try writer.writeAll(@tagName(d));
            try writer.writeByte('"');
            first = false;
        }

        if (self.system_message) |msg| {
            if (!first) try writer.writeByte(',');
            try writer.writeAll("\"systemMessage\":\"");
            try writeEscapedJson(msg, writer);
            try writer.writeByte('"');
            first = false;
        }

        if (self.reason) |reason| {
            if (!first) try writer.writeByte(',');
            try writer.writeAll("\"reason\":\"");
            try writeEscapedJson(reason, writer);
            try writer.writeByte('"');
            first = false;
        }

        // Hook-specific output
        if (self.permission_decision != null or self.additional_context != null) {
            if (!first) try writer.writeByte(',');
            try writer.writeAll("\"hookSpecificOutput\":{");

            var inner_first = true;
            if (self.permission_decision) |pd| {
                try writer.writeAll("\"permissionDecision\":\"");
                try writer.writeAll(pd.toJson());
                try writer.writeByte('"');
                inner_first = false;
            }

            if (self.additional_context) |ctx| {
                if (!inner_first) try writer.writeByte(',');
                try writer.writeAll("\"additionalContext\":\"");
                try writeEscapedJson(ctx, writer);
                try writer.writeByte('"');
            }

            try writer.writeByte('}');
        }

        try writer.writeByte('}');
    }
};

/// Hook callback function type.
pub const HookCallback = *const fn (input: HookInput, context: ?*anyopaque) HookOutput;

/// Hook matcher configuration.
pub const HookMatcher = struct {
    /// Tool name pattern to match (null matches all).
    matcher: ?[]const u8 = null,
    /// Callback function.
    callback: HookCallback,
    /// Optional timeout in milliseconds.
    timeout_ms: ?u32 = null,
    /// User context passed to callback.
    context: ?*anyopaque = null,
};

/// Hook configuration for a client.
pub const HookConfig = struct {
    allocator: Allocator,
    matchers: std.EnumArray(HookEvent, std.ArrayList(HookMatcher)),

    pub fn init(allocator: Allocator) HookConfig {
        // In Zig 0.15, ArrayList is unmanaged - use default initialization
        const matchers = std.EnumArray(HookEvent, std.ArrayList(HookMatcher)).initFill(.empty);
        return .{
            .allocator = allocator,
            .matchers = matchers,
        };
    }

    pub fn deinit(self: *HookConfig) void {
        inline for (std.meta.fields(HookEvent)) |field| {
            self.matchers.getPtr(@enumFromInt(field.value)).deinit(self.allocator);
        }
    }

    pub fn addHook(self: *HookConfig, event: HookEvent, matcher: HookMatcher) !void {
        try self.matchers.getPtr(event).append(self.allocator, matcher);
    }

    pub fn invokeHooks(self: *HookConfig, input: HookInput) HookOutput {
        const event = std.meta.activeTag(input);
        const matchers = self.matchers.get(event);

        for (matchers.items) |matcher| {
            // Check if matcher pattern applies
            if (matcher.matcher) |pattern| {
                const tool_name = switch (input) {
                    .pre_tool_use => |i| i.tool_name,
                    .post_tool_use => |i| i.tool_name,
                    else => continue,
                };

                if (!std.mem.eql(u8, pattern, tool_name)) {
                    continue;
                }
            }

            const output = matcher.callback(input, matcher.context);
            if (!output.continue_execution or output.decision != null) {
                return output;
            }
        }

        return HookOutput.approve();
    }
};

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

test "hook output approve" {
    var buf: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);

    const output = HookOutput.approve();
    try output.writeJson(stream.writer());

    try std.testing.expectEqualStrings("{}", stream.getWritten());
}

test "hook output block" {
    var buf: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);

    const output = HookOutput.block("not allowed");
    try output.writeJson(stream.writer());

    const expected =
        \\{"continue":false,"decision":"block","reason":"not allowed"}
    ;
    try std.testing.expectEqualStrings(expected, stream.getWritten());
}
