//! Simple one-shot query example.
//!
//! Run with: zig build && ./zig-out/bin/simple_query

const std = @import("std");
const claudez = @import("claudez");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const stdout = std.io.getStdOut().writer();

    // Simple query with default options
    try stdout.writeAll("Querying Claude...\n\n");

    var iter = try claudez.query(allocator, "What is 2 + 2? Reply briefly.", .{
        .max_turns = 1,
    });
    defer iter.deinit();

    while (try iter.next()) |msg| {
        switch (msg) {
            .assistant => |m| {
                for (m.content) |block| {
                    switch (block) {
                        .text => |t| try stdout.print("{s}", .{t.text}),
                        .thinking => |t| try stdout.print("[thinking: {s}]\n", .{t.thinking}),
                        else => {},
                    }
                }
            },
            .result => |r| {
                try stdout.print("\n\n--- Result ---\n", .{});
                try stdout.print("Cost: ${d:.6}\n", .{r.total_cost_usd});
                try stdout.print("Duration: {d}ms\n", .{r.duration_ms});
                try stdout.print("Turns: {d}\n", .{r.num_turns});
            },
            else => {},
        }
    }
}
