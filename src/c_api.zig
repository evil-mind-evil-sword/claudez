//! C ABI for claudez Claude Code SDK.
//!
//! This module provides a C-compatible interface for FFI consumers (e.g., Erlang NIFs).
//! Each client handle is independent - no global state. Memory ownership follows C conventions:
//! callers must free returned strings using the provided free functions.

const std = @import("std");
const query_mod = @import("query.zig");
const client_mod = @import("client.zig");
const options_mod = @import("options.zig");
const messages = @import("messages.zig");
const errors = @import("errors.zig");

/// Error codes returned by C API functions.
pub const ClaudezError = enum(c_int) {
    ok = 0,
    cli_not_found = 1,
    already_connected = 2,
    not_connected = 3,
    process_spawn_failed = 4,
    process_communication_failed = 5,
    json_parse_error = 6,
    malformed_message = 7,
    timeout = 8,
    invalid_configuration = 9,
    out_of_memory = 10,
    unknown = 11,

    pub fn fromZigError(err: anyerror) ClaudezError {
        return switch (err) {
            error.CliNotFound => .cli_not_found,
            error.AlreadyConnected => .already_connected,
            error.NotConnected => .not_connected,
            error.ProcessSpawnFailed => .process_spawn_failed,
            error.ProcessCommunicationFailed => .process_communication_failed,
            error.JsonParseError => .json_parse_error,
            error.MalformedMessage => .malformed_message,
            error.Timeout => .timeout,
            error.InvalidConfiguration => .invalid_configuration,
            error.OutOfMemory => .out_of_memory,
            else => .unknown,
        };
    }
};

/// Opaque handle to a claudez streaming client.
pub const ClaudezClient = opaque {
    fn fromPtr(ptr: *ClaudezClient) *client_mod.Client {
        return @ptrCast(@alignCast(ptr));
    }

    fn toPtr(c: *client_mod.Client) *ClaudezClient {
        return @ptrCast(@alignCast(c));
    }
};

/// C-compatible options structure for configuring claudez.
pub const ClaudezOptions = extern struct {
    /// Path to the Claude CLI binary (null = auto-detect).
    cli_path: ?[*:0]const u8 = null,
    /// Working directory for the CLI process.
    cwd: ?[*:0]const u8 = null,
    /// Model to use (e.g., "claude-sonnet-4-5").
    model: ?[*:0]const u8 = null,
    /// Maximum conversation turns (0 = unlimited).
    max_turns: u32 = 0,
    /// Permission mode: 0=default, 1=accept_edits, 2=plan, 3=bypass.
    permission_mode: u32 = 0,
    /// Resume specific session by ID.
    resume_session: ?[*:0]const u8 = null,

    fn toZigOptions(self: ClaudezOptions) options_mod.Options {
        var opts = options_mod.Options{};

        if (self.cli_path) |p| {
            opts.cli_path = std.mem.span(p);
        }
        if (self.cwd) |c| {
            opts.cwd = std.mem.span(c);
        }
        if (self.model) |m| {
            opts.model = std.mem.span(m);
        }
        if (self.max_turns > 0) {
            opts.max_turns = self.max_turns;
        }
        opts.permission_mode = switch (self.permission_mode) {
            1 => .accept_edits,
            2 => .plan,
            3 => .bypass_permissions,
            else => .default,
        };
        if (self.resume_session) |s| {
            opts.resume_session = std.mem.span(s);
        }

        return opts;
    }
};

// =============================================================================
// One-Shot Query
// =============================================================================

/// Execute a one-shot query and return the text response.
/// Returns the response text that must be freed with claudez_free_string().
pub export fn claudez_query_text(
    prompt: [*:0]const u8,
    opts: ?*const ClaudezOptions,
    out_text: *?[*:0]u8,
) callconv(.c) ClaudezError {
    const allocator = std.heap.c_allocator;

    const zig_opts = if (opts) |o| o.toZigOptions() else options_mod.Options{};

    const result = query_mod.queryText(allocator, std.mem.span(prompt), zig_opts) catch |err| {
        return ClaudezError.fromZigError(err);
    };
    defer allocator.free(result);

    out_text.* = allocator.dupeZ(u8, result) catch return .out_of_memory;
    return .ok;
}

// =============================================================================
// Streaming Client
// =============================================================================

/// Create a new streaming client.
/// Returns a handle that must be freed with claudez_client_free().
pub export fn claudez_client_new(
    opts: ?*const ClaudezOptions,
    out_client: *?*ClaudezClient,
) callconv(.c) ClaudezError {
    const allocator = std.heap.c_allocator;

    const zig_opts = if (opts) |o| o.toZigOptions() else options_mod.Options{};

    const c = allocator.create(client_mod.Client) catch return .out_of_memory;
    c.* = client_mod.Client.init(allocator, zig_opts) catch |err| {
        allocator.destroy(c);
        return ClaudezError.fromZigError(err);
    };

    out_client.* = ClaudezClient.toPtr(c);
    return .ok;
}

/// Connect to Claude in streaming mode.
pub export fn claudez_client_connect(handle: *ClaudezClient) callconv(.c) ClaudezError {
    const c = ClaudezClient.fromPtr(handle);
    c.connect() catch |err| {
        return ClaudezError.fromZigError(err);
    };
    return .ok;
}

/// Send a query in the current session.
pub export fn claudez_client_query(
    handle: *ClaudezClient,
    prompt: [*:0]const u8,
) callconv(.c) ClaudezError {
    const c = ClaudezClient.fromPtr(handle);
    c.query(std.mem.span(prompt)) catch |err| {
        return ClaudezError.fromZigError(err);
    };
    return .ok;
}

/// Receive all text content until a result message.
/// Returns the concatenated text that must be freed with claudez_free_string().
pub export fn claudez_client_receive_text(
    handle: *ClaudezClient,
    out_text: *?[*:0]u8,
) callconv(.c) ClaudezError {
    const allocator = std.heap.c_allocator;
    const c = ClaudezClient.fromPtr(handle);

    var response = c.receiveResponse() catch |err| {
        return ClaudezError.fromZigError(err);
    };
    defer response.deinit();

    // Collect all text content
    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(allocator);

    for (response.messages) |msg| {
        if (msg == .assistant) {
            for (msg.assistant.content) |block| {
                if (block == .text) {
                    result.appendSlice(allocator, block.text.text) catch return .out_of_memory;
                }
            }
        }
    }

    const owned = result.toOwnedSlice(allocator) catch return .out_of_memory;
    defer allocator.free(owned);
    out_text.* = allocator.dupeZ(u8, owned) catch return .out_of_memory;
    return .ok;
}

/// Get the current session ID (for resumption).
/// Returns the session ID that must be freed with claudez_free_string().
pub export fn claudez_client_get_session_id(
    handle: *ClaudezClient,
    out_session_id: *?[*:0]u8,
) callconv(.c) ClaudezError {
    const allocator = std.heap.c_allocator;
    const c = ClaudezClient.fromPtr(handle);

    if (c.getSessionId()) |sid| {
        out_session_id.* = allocator.dupeZ(u8, sid) catch return .out_of_memory;
        return .ok;
    }
    out_session_id.* = null;
    return .not_connected;
}

/// Send interrupt signal.
pub export fn claudez_client_interrupt(handle: *ClaudezClient) callconv(.c) ClaudezError {
    const c = ClaudezClient.fromPtr(handle);
    c.interrupt() catch |err| {
        return ClaudezError.fromZigError(err);
    };
    return .ok;
}

/// Disconnect from Claude.
pub export fn claudez_client_disconnect(handle: *ClaudezClient) callconv(.c) void {
    const c = ClaudezClient.fromPtr(handle);
    c.disconnect();
}

/// Free a client and its resources.
pub export fn claudez_client_free(handle: *ClaudezClient) callconv(.c) void {
    const allocator = std.heap.c_allocator;
    const c = ClaudezClient.fromPtr(handle);
    c.deinit();
    allocator.destroy(c);
}

// =============================================================================
// Utility Functions
// =============================================================================

/// Free a string returned by any claudez function.
pub export fn claudez_free_string(str: [*:0]u8) callconv(.c) void {
    const allocator = std.heap.c_allocator;
    allocator.free(std.mem.span(str));
}
