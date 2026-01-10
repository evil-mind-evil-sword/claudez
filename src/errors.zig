//! Error types for the Claude SDK.

const std = @import("std");

/// Errors that can occur when interacting with the Claude CLI.
pub const ClaudeError = error{
    /// Claude CLI binary not found in PATH or standard locations.
    CliNotFound,
    /// Failed to start the CLI subprocess.
    ProcessSpawnFailed,
    /// Failed to communicate with the CLI process.
    ProcessCommunicationFailed,
    /// CLI process exited with non-zero status.
    ProcessFailed,
    /// Failed to parse JSON from CLI output.
    JsonParseError,
    /// Received malformed message from CLI.
    MalformedMessage,
    /// Operation timed out.
    Timeout,
    /// Transport is not connected.
    NotConnected,
    /// Transport is already connected.
    AlreadyConnected,
    /// Control protocol error.
    ControlProtocolError,
    /// Invalid configuration.
    InvalidConfiguration,
    /// CLI version is too old.
    UnsupportedCliVersion,
};

/// Combined error set including allocator errors.
pub const Error = ClaudeError || std.mem.Allocator.Error || std.posix.WriteError || std.posix.ReadError;

/// Represents an error response from the CLI.
pub const CliErrorResponse = struct {
    message: []const u8,
    code: ?[]const u8 = null,

    pub fn format(
        self: CliErrorResponse,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.print("CliError: {s}", .{self.message});
        if (self.code) |code| {
            try writer.print(" (code: {s})", .{code});
        }
    }
};
