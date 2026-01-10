const std = @import("std");
const claudez = @import("claudez");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    const stdout = std.io.getStdOut().writer();
    try stdout.writeAll("Starting query...\n");
    
    var iter = claudez.query(allocator, "What is 2 + 2?", .{
        .max_turns = 1,
    }) catch |e| {
        try stdout.print("Error creating query: {any}\n", .{e});
        return;
    };
    defer iter.deinit();
    
    try stdout.writeAll("Query created, starting iteration...\n");
    
    while (true) {
        try stdout.writeAll("Calling next()...\n");
        const msg = iter.next() catch |e| {
            try stdout.print("Error in next: {any}\n", .{e});
            break;
        };
        if (msg) |m| {
            try stdout.print("Got message: {s}\n", .{@tagName(m)});
        } else {
            try stdout.writeAll("Got null (done)\n");
            break;
        }
    }
    
    try stdout.writeAll("Done\n");
}
