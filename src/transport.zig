//! Transport layer for subprocess communication with the Claude CLI.

const std = @import("std");
const Allocator = std.mem.Allocator;
const options_mod = @import("options.zig");
const Options = options_mod.Options;
const errors = @import("errors.zig");
const ClaudeError = errors.ClaudeError;
const messages = @import("messages.zig");
const Message = messages.Message;

const MINIMUM_CLI_VERSION = "2.0.0";
const DEFAULT_MAX_BUFFER_SIZE: usize = 1024 * 1024; // 1MB

/// Thread-safe message queue for passing messages between reader thread and main thread.
pub const MessageQueue = struct {
    const Node = struct {
        data: []const u8,
        next: ?*Node = null,
    };

    head: ?*Node = null,
    tail: ?*Node = null,
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    closed: bool = false,
    allocator: Allocator,

    pub fn init(allocator: Allocator) MessageQueue {
        return .{ .allocator = allocator };
    }

    pub fn push(self: *MessageQueue, data: []const u8) !void {
        const node = try self.allocator.create(Node);
        node.* = .{ .data = data };

        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.tail) |tail| {
            tail.next = node;
            self.tail = node;
        } else {
            self.head = node;
            self.tail = node;
        }

        self.cond.signal();
    }

    pub fn pop(self: *MessageQueue) ?[]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        while (self.head == null and !self.closed) {
            self.cond.wait(&self.mutex);
        }

        if (self.head) |head| {
            const data = head.data;
            self.head = head.next;
            if (self.head == null) {
                self.tail = null;
            }
            self.allocator.destroy(head);
            return data;
        }

        return null;
    }

    pub fn close(self: *MessageQueue) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.closed = true;
        self.cond.broadcast();
    }

    pub fn deinit(self: *MessageQueue) void {
        self.close();
        // Free any remaining nodes
        while (self.head) |head| {
            const next = head.next;
            self.allocator.free(head.data);
            self.allocator.destroy(head);
            self.head = next;
        }
    }
};

/// Transport manages subprocess lifecycle and threaded I/O.
pub const Transport = struct {
    allocator: Allocator,
    process: ?std.process.Child = null,
    stdout_thread: ?std.Thread = null,
    stderr_thread: ?std.Thread = null,
    message_queue: MessageQueue,
    stderr_buffer: std.ArrayList(u8) = .empty,
    stderr_mutex: std.Thread.Mutex = .{},
    write_mutex: std.Thread.Mutex = .{},
    connected: bool = false,
    cli_path: []const u8,
    options: Options,
    // Arena for command arguments - keeps all strings alive for process lifetime
    // (std.process.Child stores argv by reference, and Options.build*Command
    // allocates strings internally for joins and number formatting)
    cmd_arena: ?std.heap.ArenaAllocator = null,
    current_argv: ?[]const []const u8 = null,

    pub fn init(allocator: Allocator, opts: Options) !Transport {
        const cli = try findCli(allocator, opts.cli_path);

        return .{
            .allocator = allocator,
            .message_queue = MessageQueue.init(allocator),
            .cli_path = cli,
            .options = opts,
        };
    }

    pub fn deinit(self: *Transport) void {
        self.close();
        self.message_queue.deinit();
        self.stderr_buffer.deinit(self.allocator);
        if (self.options.cli_path == null) {
            self.allocator.free(self.cli_path);
        }
        self.freeProcessArgs();
    }

    fn freeProcessArgs(self: *Transport) void {
        // Free the arena which contains all command strings
        if (self.cmd_arena) |*arena| {
            arena.deinit();
            self.cmd_arena = null;
        }
        self.current_argv = null;
    }

    /// Connect with a one-shot query.
    pub fn connectQuery(self: *Transport, prompt: []const u8) !void {
        if (self.connected) return ClaudeError.AlreadyConnected;

        // Free any previous args (shouldn't happen, but defensive)
        self.freeProcessArgs();

        // Create arena for all command-related allocations
        self.cmd_arena = std.heap.ArenaAllocator.init(self.allocator);
        // Use freeProcessArgs on error to clean both arena AND current_argv
        errdefer self.freeProcessArgs();
        const arena_alloc = self.cmd_arena.?.allocator();

        const args = try self.options.buildQueryCommand(arena_alloc, prompt);

        // Replace "claude" with actual cli path
        const argv = try arena_alloc.alloc([]const u8, args.len);
        argv[0] = self.cli_path;
        for (args[1..], 1..) |arg, i| {
            argv[i] = arg;
        }

        // Store argv - it must stay alive while Child process exists
        // (std.process.Child stores argv by reference)
        self.current_argv = argv;

        try self.spawnProcess(argv);

        // Close stdin immediately for one-shot queries - claude CLI needs EOF to process
        if (self.process) |*proc| {
            if (proc.stdin) |stdin| {
                stdin.close();
                proc.stdin = null;
            }
        }
    }

    /// Connect with streaming mode (bidirectional).
    pub fn connectStreaming(self: *Transport) !void {
        if (self.connected) return ClaudeError.AlreadyConnected;

        // Free any previous args (shouldn't happen, but defensive)
        self.freeProcessArgs();

        // Create arena for all command-related allocations
        self.cmd_arena = std.heap.ArenaAllocator.init(self.allocator);
        // Use freeProcessArgs on error to clean both arena AND current_argv
        errdefer self.freeProcessArgs();
        const arena_alloc = self.cmd_arena.?.allocator();

        const args = try self.options.buildStreamingCommand(arena_alloc);

        const argv = try arena_alloc.alloc([]const u8, args.len);
        argv[0] = self.cli_path;
        for (args[1..], 1..) |arg, i| {
            argv[i] = arg;
        }

        // Store argv - it must stay alive while Child process exists
        self.current_argv = argv;

        try self.spawnProcess(argv);
    }

    fn spawnProcess(self: *Transport, argv: []const []const u8) !void {
        var child = std.process.Child.init(argv, self.allocator);
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;

        if (self.options.cwd) |cwd| {
            child.cwd = cwd;
        }

        try child.spawn();
        self.process = child;
        self.connected = true;

        // Spawn stdout reader thread
        self.stdout_thread = try std.Thread.spawn(.{}, readStdoutThread, .{ self, child.stdout.? });

        // Spawn stderr reader thread
        self.stderr_thread = try std.Thread.spawn(.{}, readStderrThread, .{ self, child.stderr.? });
    }

    fn readStdoutThread(self: *Transport, stdout: std.fs.File) void {
        var buffer: [64 * 1024]u8 = undefined;
        var line_buffer: std.ArrayList(u8) = .empty;
        defer line_buffer.deinit(self.allocator);

        while (true) {
            const bytes_read = stdout.read(&buffer) catch break;
            if (bytes_read == 0) break;

            // Process line by line (NDJSON)
            for (buffer[0..bytes_read]) |byte| {
                if (byte == '\n') {
                    if (line_buffer.items.len > 0) {
                        // Copy and queue the message
                        const msg = self.allocator.dupe(u8, line_buffer.items) catch break;
                        self.message_queue.push(msg) catch {
                            self.allocator.free(msg);
                            break;
                        };
                        line_buffer.clearRetainingCapacity();
                    }
                } else {
                    line_buffer.append(self.allocator, byte) catch break;
                }
            }
        }

        self.message_queue.close();
    }

    fn readStderrThread(self: *Transport, stderr: std.fs.File) void {
        var buffer: [4096]u8 = undefined;

        while (true) {
            const bytes_read = stderr.read(&buffer) catch break;
            if (bytes_read == 0) break;

            self.stderr_mutex.lock();
            defer self.stderr_mutex.unlock();
            self.stderr_buffer.appendSlice(self.allocator, buffer[0..bytes_read]) catch break;
        }
    }

    /// Write data to stdin (thread-safe).
    pub fn write(self: *Transport, data: []const u8) !void {
        if (!self.connected) return ClaudeError.NotConnected;

        self.write_mutex.lock();
        defer self.write_mutex.unlock();

        if (self.process) |*proc| {
            if (proc.stdin) |stdin| {
                try stdin.writeAll(data);
            } else {
                return ClaudeError.ProcessCommunicationFailed;
            }
        } else {
            return ClaudeError.NotConnected;
        }
    }

    /// Read the next message (blocks until available).
    pub fn readMessage(self: *Transport) ?[]const u8 {
        return self.message_queue.pop();
    }

    /// Close the transport and clean up.
    pub fn close(self: *Transport) void {
        if (!self.connected) return;

        self.message_queue.close();

        // Close stdin to signal EOF to the child process
        if (self.process) |*proc| {
            if (proc.stdin) |stdin| {
                stdin.close();
                proc.stdin = null;
            }
        }

        // Wait for process to exit BEFORE joining threads.
        // This ensures stdout/stderr pipes are closed, allowing
        // the reader threads to see EOF and exit naturally.
        // (Joining threads first could hang if the process doesn't exit)
        if (self.process) |*proc| {
            _ = proc.wait() catch {};
            self.process = null;
        }

        // Now safe to join threads - process has exited, pipes are closed
        if (self.stdout_thread) |thread| {
            thread.join();
            self.stdout_thread = null;
        }

        if (self.stderr_thread) |thread| {
            thread.join();
            self.stderr_thread = null;
        }

        self.connected = false;
    }

    /// Get stderr output (for debugging).
    /// Note: Only call after close() to avoid data races.
    pub fn getStderr(self: *Transport) []const u8 {
        self.stderr_mutex.lock();
        defer self.stderr_mutex.unlock();
        return self.stderr_buffer.items;
    }
};

/// Validate that the CLI version meets minimum requirements.
/// Returns the version string on success, or error if version is too old.
pub fn validateCliVersion(allocator: Allocator, cli_path: []const u8) ![]const u8 {
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ cli_path, "--version" },
    }) catch {
        return ClaudeError.CliNotFound;
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Parse version from output (format: "claude 1.0.50" or similar)
    const version = parseVersion(result.stdout) orelse return ClaudeError.UnsupportedCliVersion;

    // Compare versions
    if (compareVersions(version, MINIMUM_CLI_VERSION) == .lt) {
        return ClaudeError.UnsupportedCliVersion;
    }

    return allocator.dupe(u8, version);
}

fn parseVersion(output: []const u8) ?[]const u8 {
    // Look for version pattern: digits.digits.digits
    var i: usize = 0;
    while (i < output.len) : (i += 1) {
        if (std.ascii.isDigit(output[i])) {
            const start = i;
            var dots: usize = 0;
            while (i < output.len and (std.ascii.isDigit(output[i]) or output[i] == '.')) {
                if (output[i] == '.') dots += 1;
                i += 1;
            }
            if (dots >= 1) {
                return output[start..i];
            }
        }
    }
    return null;
}

fn compareVersions(a: []const u8, b: []const u8) std.math.Order {
    var a_iter = std.mem.splitScalar(u8, a, '.');
    var b_iter = std.mem.splitScalar(u8, b, '.');

    while (true) {
        const a_part = a_iter.next();
        const b_part = b_iter.next();

        if (a_part == null and b_part == null) return .eq;
        const a_num = if (a_part) |p| std.fmt.parseInt(u32, p, 10) catch 0 else 0;
        const b_num = if (b_part) |p| std.fmt.parseInt(u32, p, 10) catch 0 else 0;

        if (a_num < b_num) return .lt;
        if (a_num > b_num) return .gt;
    }
}

/// Find the Claude CLI binary.
fn findCli(allocator: Allocator, cli_path: ?[]const u8) ![]const u8 {
    if (cli_path) |path| {
        return path;
    }

    // Check PATH first
    if (std.process.getEnvVarOwned(allocator, "PATH")) |path_env| {
        defer allocator.free(path_env);

        var iter = std.mem.splitScalar(u8, path_env, ':');
        while (iter.next()) |dir| {
            const full_path = try std.fs.path.join(allocator, &.{ dir, "claude" });
            defer allocator.free(full_path);

            if (std.fs.accessAbsolute(full_path, .{})) {
                return try allocator.dupe(u8, full_path);
            } else |_| {}
        }
    } else |_| {}

    // Check standard locations
    const home = std.process.getEnvVarOwned(allocator, "HOME") catch return ClaudeError.CliNotFound;
    defer allocator.free(home);

    const locations = [_][]const u8{
        ".local/bin/claude",
        ".npm-global/bin/claude",
        "node_modules/.bin/claude",
        ".yarn/bin/claude",
        ".claude/local/claude",
    };

    for (locations) |loc| {
        const full_path = try std.fs.path.join(allocator, &.{ home, loc });
        defer allocator.free(full_path);

        if (std.fs.accessAbsolute(full_path, .{})) {
            return try allocator.dupe(u8, full_path);
        } else |_| {}
    }

    // Also check /usr/local/bin
    if (std.fs.accessAbsolute("/usr/local/bin/claude", .{})) {
        return try allocator.dupe(u8, "/usr/local/bin/claude");
    } else |_| {}

    return ClaudeError.CliNotFound;
}

test "message queue" {
    const allocator = std.testing.allocator;
    var queue = MessageQueue.init(allocator);
    defer queue.deinit();

    const msg1 = try allocator.dupe(u8, "hello");
    try queue.push(msg1);

    const msg2 = try allocator.dupe(u8, "world");
    try queue.push(msg2);

    const r1 = queue.pop();
    try std.testing.expect(r1 != null);
    try std.testing.expectEqualStrings("hello", r1.?);
    allocator.free(r1.?);

    const r2 = queue.pop();
    try std.testing.expect(r2 != null);
    try std.testing.expectEqualStrings("world", r2.?);
    allocator.free(r2.?);
}

test "parseVersion" {
    try std.testing.expectEqualStrings("1.0.50", parseVersion("claude 1.0.50\n").?);
    try std.testing.expectEqualStrings("2.0.0", parseVersion("Claude Code v2.0.0\n").?);
    try std.testing.expectEqualStrings("1.2", parseVersion("version 1.2").?);
    try std.testing.expect(parseVersion("no version here") == null);
    try std.testing.expect(parseVersion("") == null);
}

test "compareVersions" {
    try std.testing.expect(compareVersions("1.0.0", "1.0.0") == .eq);
    try std.testing.expect(compareVersions("2.0.0", "1.0.0") == .gt);
    try std.testing.expect(compareVersions("1.0.0", "2.0.0") == .lt);
    try std.testing.expect(compareVersions("1.0.50", "1.0.49") == .gt);
    try std.testing.expect(compareVersions("1.1.0", "1.0.99") == .gt);
    try std.testing.expect(compareVersions("2.0", "1.9.9") == .gt);
}
