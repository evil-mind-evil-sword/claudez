//! Streaming client example with multi-turn conversation.
//!
//! Run with: zig build && ./zig-out/bin/streaming

const std = @import("std");
const claudez = @import("claudez");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const stdout = std.io.getStdOut().writer();

    try stdout.writeAll("Initializing streaming client...\n\n");

    // Create client with custom options
    var client = try claudez.Client.init(allocator, .{
        .permission_mode = .accept_edits,
        .max_turns = 5,
    });
    defer client.deinit();

    // Connect to Claude
    try client.connect();
    try stdout.writeAll("Connected!\n\n");

    // First query
    try stdout.writeAll("User: What's your name?\n");
    try stdout.writeAll("Assistant: ");

    try client.query("What's your name? Keep it brief.");

    const response1 = try client.receiveResponse();
    defer allocator.free(response1);

    for (response1) |msg| {
        switch (msg) {
            .assistant => |m| {
                for (m.content) |block| {
                    if (block == .text) {
                        try stdout.print("{s}", .{block.text.text});
                    }
                }
            },
            .result => |r| {
                try stdout.print("\n(cost: ${d:.6})\n\n", .{r.total_cost_usd});
            },
            else => {},
        }
    }

    // Second query (continues conversation)
    try stdout.writeAll("User: What did I just ask you?\n");
    try stdout.writeAll("Assistant: ");

    try client.query("What did I just ask you?");

    const response2 = try client.receiveResponse();
    defer allocator.free(response2);

    for (response2) |msg| {
        switch (msg) {
            .assistant => |m| {
                for (m.content) |block| {
                    if (block == .text) {
                        try stdout.print("{s}", .{block.text.text});
                    }
                }
            },
            .result => |r| {
                try stdout.print("\n(cost: ${d:.6})\n\n", .{r.total_cost_usd});
            },
            else => {},
        }
    }

    try stdout.writeAll("Done!\n");
}
