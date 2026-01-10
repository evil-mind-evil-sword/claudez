//! Streaming client for bidirectional Claude interactions.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Transport = @import("transport.zig").Transport;
const Options = @import("options.zig").Options;
const PermissionMode = @import("options.zig").PermissionMode;
const messages = @import("messages.zig");
const Message = messages.Message;
const ContentBlock = messages.ContentBlock;
const ClaudeError = @import("errors.zig").ClaudeError;
const hooks = @import("hooks.zig");
const HookConfig = hooks.HookConfig;
const HookInput = hooks.HookInput;
const HookOutput = hooks.HookOutput;

/// Control request types.
pub const ControlRequestType = enum {
    initialize,
    can_use_tool,
    hook_callback,
    set_permission_mode,
    set_model,
    mcp_message,
    rewind_files,
    interrupt,
};

/// Control response handler callback.
pub const ControlCallback = *const fn (response: std.json.Value, context: ?*anyopaque) void;

/// Pending control request.
const PendingRequest = struct {
    callback: ?ControlCallback,
    context: ?*anyopaque,
};

/// Response from receiveResponse() - owns messages and their backing JSON data.
/// Call deinit() when done to free all resources.
pub const Response = struct {
    messages: []Message,
    allocator: Allocator,
    // Internal: parsed JSON values that back the messages
    parsed_values: []std.json.Parsed(std.json.Value),
    // Internal: allocated content blocks
    content_blocks: [][]ContentBlock,

    pub fn deinit(self: *Response) void {
        for (self.content_blocks) |blocks| {
            self.allocator.free(blocks);
        }
        self.allocator.free(self.content_blocks);
        for (self.parsed_values) |*p| {
            p.deinit();
        }
        self.allocator.free(self.parsed_values);
        self.allocator.free(self.messages);
    }
};

/// Streaming client for interactive conversations.
pub const Client = struct {
    allocator: Allocator,
    transport: Transport,
    options: Options,
    connected: bool = false,
    request_counter: u64 = 0,
    pending_requests: std.AutoHashMap(u64, PendingRequest),
    current_parsed: ?std.json.Parsed(std.json.Value) = null,
    session_id: ?[]const u8 = null,
    hook_config: ?*HookConfig = null,
    cwd: []const u8 = ".",

    /// Initialize a new client.
    pub fn init(allocator: Allocator, opts: ?Options) !Client {
        const options = opts orelse Options{};
        return .{
            .allocator = allocator,
            .transport = try Transport.init(allocator, options),
            .options = options,
            .pending_requests = std.AutoHashMap(u64, PendingRequest).init(allocator),
        };
    }

    /// Connect to Claude in streaming mode.
    pub fn connect(self: *Client) !void {
        if (self.connected) return ClaudeError.AlreadyConnected;

        try self.transport.connectStreaming();
        self.connected = true;

        // Send initialization handshake
        try self.sendControlRequest(.initialize, .{});
    }

    /// Send a query in the current session.
    pub fn query(self: *Client, prompt: []const u8) !void {
        if (!self.connected) return ClaudeError.NotConnected;

        const session = self.session_id orelse "default";

        // Build user message JSON
        var json_buf: [64 * 1024]u8 = undefined;
        var stream = std.io.fixedBufferStream(&json_buf);
        const writer = stream.writer();

        try writer.writeAll("{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"");
        try writeEscapedJson(prompt, writer);
        try writer.writeAll("\"},\"parent_tool_use_id\":null,\"session_id\":\"");
        try writeEscapedJson(session, writer);
        try writer.writeAll("\"}\n");

        try self.transport.write(stream.getWritten());
    }

    /// Iterator for receiving messages.
    pub const MessageIterator = struct {
        client: *Client,

        pub fn next(self: *MessageIterator) !?Message {
            return self.client.receiveMessage();
        }
    };

    /// Get an iterator over incoming messages.
    pub fn receiveMessages(self: *Client) MessageIterator {
        return .{ .client = self };
    }

    /// Receive a single message (blocks until available).
    pub fn receiveMessage(self: *Client) !?Message {
        // Free previous parsed value
        if (self.current_parsed) |*p| {
            p.deinit();
            self.current_parsed = null;
        }

        const json_bytes = self.transport.readMessage() orelse return null;
        defer self.allocator.free(json_bytes);

        if (json_bytes.len == 0) {
            return self.receiveMessage();
        }

        self.current_parsed = Message.parse(self.allocator, json_bytes) catch {
            return ClaudeError.JsonParseError;
        };

        const value = self.current_parsed.?.value;

        // Check for control messages
        if (value.object.get("type")) |t| {
            if (std.mem.eql(u8, t.string, "control_response")) {
                try self.handleControlResponse(value);
                return self.receiveMessage(); // Skip control messages
            } else if (std.mem.eql(u8, t.string, "control_request")) {
                try self.handleControlRequest(value);
                return self.receiveMessage(); // Skip control requests
            }
        }

        const msg = Message.fromJson(self.allocator, value) catch {
            return ClaudeError.MalformedMessage;
        };

        // Capture session_id from result messages for multi-turn continuity
        if (msg == .result) {
            if (msg.result.session_id) |sid| {
                // Free previous session_id if we allocated it
                if (self.session_id) |old_sid| {
                    self.allocator.free(old_sid);
                }
                self.session_id = self.allocator.dupe(u8, sid) catch null;
            }
        }

        return msg;
    }

    /// Receive messages until a ResultMessage.
    /// Returns a Response that owns all messages and their backing data.
    /// Caller must call response.deinit() when done.
    pub fn receiveResponse(self: *Client) !Response {
        var msg_list: std.ArrayList(Message) = .empty;
        errdefer msg_list.deinit(self.allocator);
        var parsed_list: std.ArrayList(std.json.Parsed(std.json.Value)) = .empty;
        errdefer {
            for (parsed_list.items) |*p| p.deinit();
            parsed_list.deinit(self.allocator);
        }
        var content_list: std.ArrayList([]ContentBlock) = .empty;
        errdefer {
            for (content_list.items) |blocks| self.allocator.free(blocks);
            content_list.deinit(self.allocator);
        }

        while (true) {
            const json_bytes = self.transport.readMessage() orelse break;
            defer self.allocator.free(json_bytes);

            if (json_bytes.len == 0) continue;

            var parsed = Message.parse(self.allocator, json_bytes) catch {
                return ClaudeError.JsonParseError;
            };
            // Don't defer deinit - we're keeping it alive

            const value = parsed.value;

            // Check for control messages
            if (value.object.get("type")) |t| {
                if (std.mem.eql(u8, t.string, "control_response")) {
                    try self.handleControlResponse(value);
                    parsed.deinit(); // Control messages not kept
                    continue;
                } else if (std.mem.eql(u8, t.string, "control_request")) {
                    try self.handleControlRequest(value);
                    parsed.deinit();
                    continue;
                }
            }

            const msg = Message.fromJson(self.allocator, value) catch {
                parsed.deinit();
                return ClaudeError.MalformedMessage;
            };

            // Track the parsed value to keep strings alive
            try parsed_list.append(self.allocator, parsed);

            // Track content blocks if this is an assistant message
            if (msg == .assistant) {
                try content_list.append(self.allocator, msg.assistant.content);
            }

            // Capture session_id from result messages for multi-turn continuity
            if (msg == .result) {
                if (msg.result.session_id) |sid| {
                    if (self.session_id) |old_sid| {
                        self.allocator.free(old_sid);
                    }
                    self.session_id = self.allocator.dupe(u8, sid) catch null;
                }
                try msg_list.append(self.allocator, msg);
                break;
            }

            try msg_list.append(self.allocator, msg);
        }

        return .{
            .messages = try msg_list.toOwnedSlice(self.allocator),
            .allocator = self.allocator,
            .parsed_values = try parsed_list.toOwnedSlice(self.allocator),
            .content_blocks = try content_list.toOwnedSlice(self.allocator),
        };
    }

    /// Send interrupt signal.
    pub fn interrupt(self: *Client) !void {
        try self.sendControlRequest(.interrupt, .{});
    }

    /// Change permission mode.
    pub fn setPermissionMode(self: *Client, mode: PermissionMode) !void {
        try self.sendControlRequest(.set_permission_mode, .{
            .mode = mode.toCliFlag(),
        });
    }

    /// Change the model.
    pub fn setModel(self: *Client, model: []const u8) !void {
        try self.sendControlRequest(.set_model, .{
            .model = model,
        });
    }

    /// Set hook configuration for intercepting tool calls.
    /// The HookConfig must outlive the Client.
    pub fn setHooks(self: *Client, config: *HookConfig) void {
        self.hook_config = config;
    }

    /// Set the working directory (used in hook inputs).
    pub fn setCwd(self: *Client, cwd: []const u8) void {
        self.cwd = cwd;
    }

    /// Get the current session ID for persistence.
    /// Returns null if no session has been established.
    pub fn getSessionId(self: *Client) ?[]const u8 {
        return self.session_id;
    }

    /// Save session state to a file for later resumption.
    /// The file contains the session ID in plain text.
    pub fn saveSession(self: *Client, path: []const u8) !void {
        const sid = self.session_id orelse return ClaudeError.NotConnected;

        var file = try std.fs.cwd().createFile(path, .{});
        defer file.close();
        try file.writeAll(sid);
    }

    /// Load session ID from a file.
    /// Returns a newly allocated string that the caller must free.
    pub fn loadSession(allocator: Allocator, path: []const u8) ![]const u8 {
        var file = std.fs.cwd().openFile(path, .{}) catch |err| {
            return switch (err) {
                error.FileNotFound => ClaudeError.InvalidConfiguration,
                else => err,
            };
        };
        defer file.close();

        const stat = try file.stat();
        if (stat.size > 1024) return ClaudeError.InvalidConfiguration;

        const content = try file.readToEndAlloc(allocator, 1024);
        // Trim trailing whitespace
        var end: usize = content.len;
        while (end > 0 and std.ascii.isWhitespace(content[end - 1])) {
            end -= 1;
        }
        if (end != content.len) {
            const trimmed = try allocator.dupe(u8, content[0..end]);
            allocator.free(content);
            return trimmed;
        }
        return content;
    }

    /// Reconnect to an existing session after disconnect.
    /// Uses the current session_id to resume the conversation.
    pub fn reconnect(self: *Client) !void {
        if (self.connected) return ClaudeError.AlreadyConnected;

        const sid = self.session_id orelse return ClaudeError.NotConnected;

        // Update options to resume the session
        self.options.resume_session = sid;

        // Close any existing transport state
        self.transport.deinit();

        // Reinitialize transport with updated options
        self.transport = try Transport.init(self.allocator, self.options);
        try self.transport.connectStreaming();
        self.connected = true;

        // Send initialization handshake
        try self.sendControlRequest(.initialize, .{});
    }

    /// Disconnect from Claude.
    pub fn disconnect(self: *Client) void {
        self.transport.close();
        self.connected = false;
    }

    /// Clean up resources.
    pub fn deinit(self: *Client) void {
        self.disconnect();
        if (self.current_parsed) |*p| {
            p.deinit();
        }
        if (self.session_id) |sid| {
            self.allocator.free(sid);
        }
        self.pending_requests.deinit();
        self.transport.deinit();
    }

    // Internal methods

    fn sendControlRequest(self: *Client, request_type: ControlRequestType, payload: anytype) !void {
        self.request_counter += 1;
        const request_id = self.request_counter;

        var json_buf: [16 * 1024]u8 = undefined;
        var stream = std.io.fixedBufferStream(&json_buf);
        const writer = stream.writer();

        try writer.writeAll("{\"type\":\"control_request\",\"request_id\":\"req_");
        try writer.print("{d}", .{request_id});
        try writer.writeAll("\",\"request\":{\"subtype\":\"");
        try writer.writeAll(@tagName(request_type));
        try writer.writeAll("\"");

        // Add payload fields (with proper JSON escaping)
        const PayloadType = @TypeOf(payload);
        if (@typeInfo(PayloadType) == .@"struct") {
            inline for (std.meta.fields(PayloadType)) |field| {
                const value = @field(payload, field.name);
                try writer.writeAll(",\"");
                try writer.writeAll(field.name);
                try writer.writeAll("\":\"");
                try writeEscapedJson(value, writer);
                try writer.writeAll("\"");
            }
        }

        try writer.writeAll("}}\n");

        try self.transport.write(stream.getWritten());
    }

    fn handleControlResponse(self: *Client, value: std.json.Value) !void {
        const response = value.object.get("response") orelse return;
        const request_id_str = response.object.get("request_id") orelse return;

        // Extract numeric part from "req_123"
        const id_str = request_id_str.string;
        if (std.mem.startsWith(u8, id_str, "req_")) {
            const num_str = id_str[4..];
            const request_id = std.fmt.parseInt(u64, num_str, 10) catch return;

            if (self.pending_requests.get(request_id)) |pending| {
                if (pending.callback) |callback| {
                    callback(response, pending.context);
                }
                _ = self.pending_requests.remove(request_id);
            }
        }
    }

    fn handleControlRequest(self: *Client, value: std.json.Value) !void {
        const request = value.object.get("request") orelse return;
        const subtype = request.object.get("subtype") orelse return;
        const request_id = value.object.get("request_id") orelse return;

        if (std.mem.eql(u8, subtype.string, "can_use_tool")) {
            // Extract tool info from request
            const tool_name = if (request.object.get("tool_name")) |t| t.string else "unknown";
            const tool_input = request.object.get("tool_input") orelse std.json.Value{ .null = {} };

            // Consult hooks if configured
            var behavior: []const u8 = "allow";
            var reason: ?[]const u8 = null;

            if (self.hook_config) |config| {
                const session = self.session_id orelse "default";
                const input = HookInput{
                    .pre_tool_use = .{
                        .session_id = session,
                        .cwd = self.cwd,
                        .tool_name = tool_name,
                        .tool_input = tool_input,
                    },
                };

                const output = config.invokeHooks(input);
                if (output.decision == .block) {
                    behavior = "deny";
                    reason = output.reason;
                } else if (output.permission_decision) |pd| {
                    behavior = switch (pd) {
                        .allow => "allow",
                        .deny => "deny",
                        .ask => "ask",
                    };
                    reason = output.reason;
                }
            }

            // Send response
            var json_buf: [8192]u8 = undefined;
            var stream = std.io.fixedBufferStream(&json_buf);
            const writer = stream.writer();

            try writer.writeAll("{\"type\":\"control_response\",\"response\":{");
            try writer.writeAll("\"subtype\":\"success\",\"request_id\":\"");
            try writeEscapedJson(request_id.string, writer);
            try writer.writeAll("\",\"response\":{\"behavior\":\"");
            try writer.writeAll(behavior);
            try writer.writeByte('"');
            if (reason) |r| {
                try writer.writeAll(",\"reason\":\"");
                try writeEscapedJson(r, writer);
                try writer.writeByte('"');
            }
            try writer.writeAll("}}}\n");

            try self.transport.write(stream.getWritten());
        }
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

test "client init" {
    const allocator = std.testing.allocator;
    var client = try Client.init(allocator, null);
    defer client.deinit();

    try std.testing.expect(!client.connected);
}
