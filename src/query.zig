//! One-shot query interface for simple Claude interactions.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Transport = @import("transport.zig").Transport;
const Options = @import("options.zig").Options;
const messages = @import("messages.zig");
const Message = messages.Message;
const ClaudeError = @import("errors.zig").ClaudeError;

/// Iterator over messages from a one-shot query.
pub const QueryIterator = struct {
    transport: *Transport,
    allocator: Allocator,
    current_parsed: ?std.json.Parsed(std.json.Value) = null,
    done: bool = false,

    pub fn next(self: *QueryIterator) !?Message {
        if (self.done) return null;

        // Free previous parsed value
        if (self.current_parsed) |*p| {
            p.deinit();
            self.current_parsed = null;
        }

        const json_bytes = self.transport.readMessage() orelse {
            self.done = true;
            return null;
        };
        defer self.allocator.free(json_bytes);

        // Skip empty lines
        if (json_bytes.len == 0) {
            return self.next();
        }

        // Parse JSON
        self.current_parsed = Message.parse(self.allocator, json_bytes) catch {
            return ClaudeError.JsonParseError;
        };

        // Convert to Message
        const msg = Message.fromJson(self.allocator, self.current_parsed.?.value) catch {
            return ClaudeError.MalformedMessage;
        };

        // Check if this is the final message
        if (msg == .result) {
            self.done = true;
        }

        return msg;
    }

    pub fn deinit(self: *QueryIterator) void {
        if (self.current_parsed) |*p| {
            p.deinit();
        }
        self.transport.deinit();
        self.allocator.destroy(self.transport);
    }
};

/// Execute a one-shot query to Claude.
///
/// Returns an iterator over response messages. The iterator yields messages
/// until a ResultMessage is received, indicating the query is complete.
///
/// Example:
/// ```zig
/// var iter = try claudez.query(allocator, "What is 2+2?", null);
/// defer iter.deinit();
///
/// while (try iter.next()) |msg| {
///     switch (msg) {
///         .assistant => |m| {
///             for (m.content) |block| {
///                 if (block == .text) {
///                     std.debug.print("{s}", .{block.text.text});
///                 }
///             }
///         },
///         .result => |r| {
///             std.debug.print("\nCost: ${d:.4}\n", .{r.total_cost_usd});
///         },
///         else => {},
///     }
/// }
/// ```
pub fn query(allocator: Allocator, prompt: []const u8, opts: ?Options) !QueryIterator {
    const options = opts orelse Options{};

    const transport = try allocator.create(Transport);
    errdefer allocator.destroy(transport);

    transport.* = try Transport.init(allocator, options);
    errdefer transport.deinit();

    try transport.connectQuery(prompt);

    return .{
        .transport = transport,
        .allocator = allocator,
    };
}

/// Execute a query and collect all text responses into a single string.
pub fn queryText(allocator: Allocator, prompt: []const u8, opts: ?Options) ![]const u8 {
    var iter = try query(allocator, prompt, opts);
    defer iter.deinit();

    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    while (try iter.next()) |msg| {
        switch (msg) {
            .assistant => |m| {
                for (m.content) |block| {
                    switch (block) {
                        .text => |t| try result.appendSlice(allocator, t.text),
                        else => {},
                    }
                }
            },
            else => {},
        }
    }

    return result.toOwnedSlice(allocator);
}
