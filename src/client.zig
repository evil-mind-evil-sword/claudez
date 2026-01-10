//! Streaming client for bidirectional Claude interactions.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Transport = @import("transport.zig").Transport;
const Options = @import("options.zig").Options;
const PermissionMode = @import("options.zig").PermissionMode;
const messages = @import("messages.zig");
const Message = messages.Message;
const ClaudeError = @import("errors.zig").ClaudeError;

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
        try writer.writeAll(session);
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

        return Message.fromJson(self.allocator, value) catch {
            return ClaudeError.MalformedMessage;
        };
    }

    /// Receive messages until a ResultMessage.
    pub fn receiveResponse(self: *Client) ![]Message {
        var result = std.ArrayList(Message).init(self.allocator);
        errdefer result.deinit();

        while (try self.receiveMessage()) |msg| {
            try result.append(msg);
            if (msg == .result) break;
        }

        return result.toOwnedSlice();
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

        // Add payload fields
        const PayloadType = @TypeOf(payload);
        if (@typeInfo(PayloadType) == .@"struct") {
            inline for (std.meta.fields(PayloadType)) |field| {
                const value = @field(payload, field.name);
                try writer.writeAll(",\"");
                try writer.writeAll(field.name);
                try writer.writeAll("\":\"");
                try writer.writeAll(value);
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

        // For now, auto-approve tool use requests
        if (std.mem.eql(u8, subtype.string, "can_use_tool")) {
            var json_buf: [4096]u8 = undefined;
            var stream = std.io.fixedBufferStream(&json_buf);
            const writer = stream.writer();

            try writer.writeAll("{\"type\":\"control_response\",\"response\":{");
            try writer.writeAll("\"subtype\":\"success\",\"request_id\":\"");
            try writer.writeAll(request_id.string);
            try writer.writeAll("\",\"response\":{\"behavior\":\"allow\"}}}\n");

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
