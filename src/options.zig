//! Configuration options for the Claude SDK.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Permission modes for tool execution.
pub const PermissionMode = enum {
    /// CLI prompts for dangerous tools (default).
    default,
    /// Auto-accept file edits.
    accept_edits,
    /// Planning mode - no edits allowed.
    plan,
    /// Allow all tools without prompting.
    bypass_permissions,

    pub fn toCliFlag(self: PermissionMode) []const u8 {
        return switch (self) {
            .default => "default",
            .accept_edits => "acceptEdits",
            .plan => "plan",
            .bypass_permissions => "bypassPermissions",
        };
    }
};

/// System prompt configuration.
pub const SystemPrompt = union(enum) {
    /// Custom system prompt string.
    custom: []const u8,
    /// Empty system prompt.
    empty,
    /// Append to default system prompt.
    append: []const u8,
};

/// Configuration options matching the Python SDK's ClaudeAgentOptions.
pub const Options = struct {
    /// Path to the Claude CLI binary. If null, searches standard locations.
    cli_path: ?[]const u8 = null,

    /// Working directory for the CLI process.
    cwd: ?[]const u8 = null,

    /// System prompt configuration.
    system_prompt: ?SystemPrompt = null,

    /// Base set of tools. Empty slice means no tools.
    tools: ?[]const []const u8 = null,

    /// Subset of allowed tools (whitelist).
    allowed_tools: ?[]const []const u8 = null,

    /// Tools to block (blacklist).
    disallowed_tools: ?[]const []const u8 = null,

    /// Model to use (e.g., "claude-sonnet-4-5").
    model: ?[]const u8 = null,

    /// Fallback model if primary unavailable.
    fallback_model: ?[]const u8 = null,

    /// Maximum conversation turns.
    max_turns: ?u32 = null,

    /// Maximum budget in USD.
    max_budget_usd: ?f64 = null,

    /// Permission mode for tool execution.
    permission_mode: PermissionMode = .default,

    /// Continue previous session.
    continue_conversation: bool = false,

    /// Resume specific session by ID.
    resume_session: ?[]const u8 = null,

    /// Beta features to enable.
    betas: ?[]const []const u8 = null,

    /// Maximum thinking tokens.
    max_thinking_tokens: ?u32 = null,

    /// JSON schema for structured output.
    json_schema: ?[]const u8 = null,

    /// Additional directories to allow access.
    add_dirs: ?[]const []const u8 = null,

    /// Include partial messages in stream.
    include_partial_messages: bool = false,

    /// Fork session on resume.
    fork_session: bool = false,

    /// MCP server configuration (JSON string).
    mcp_config: ?[]const u8 = null,

    /// Settings (JSON string or file path).
    settings: ?[]const u8 = null,

    /// Environment variables for the CLI process.
    env: ?std.process.EnvMap = null,

    /// Build CLI command arguments for one-shot query mode.
    pub fn buildQueryCommand(self: Options, allocator: Allocator, prompt: []const u8) ![]const []const u8 {
        var args = std.ArrayList([]const u8).init(allocator);
        errdefer args.deinit();

        // Base command
        try args.append("claude");
        try args.append("--output-format");
        try args.append("stream-json");
        try args.append("--verbose");

        // Add all options
        try self.appendCommonArgs(&args);

        // One-shot mode
        try args.append("--print");
        try args.append("--");
        try args.append(prompt);

        return args.toOwnedSlice();
    }

    /// Build CLI command arguments for streaming mode.
    pub fn buildStreamingCommand(self: Options, allocator: Allocator) ![]const []const u8 {
        var args = std.ArrayList([]const u8).init(allocator);
        errdefer args.deinit();

        // Base command
        try args.append("claude");
        try args.append("--output-format");
        try args.append("stream-json");
        try args.append("--verbose");
        try args.append("--input-format");
        try args.append("stream-json");

        // Add all options
        try self.appendCommonArgs(&args);

        return args.toOwnedSlice();
    }

    fn appendCommonArgs(self: Options, args: *std.ArrayList([]const u8)) !void {
        // System prompt
        if (self.system_prompt) |sp| {
            switch (sp) {
                .custom => |s| {
                    try args.append("--system-prompt");
                    try args.append(s);
                },
                .empty => {
                    try args.append("--system-prompt");
                    try args.append("");
                },
                .append => |s| {
                    try args.append("--append-system-prompt");
                    try args.append(s);
                },
            }
        }

        // Tools
        if (self.tools) |tools| {
            try args.append("--tools");
            if (tools.len == 0) {
                try args.append("");
            } else {
                // Join with commas - caller must ensure this is allocated
                try args.append(tools[0]); // Simplified for now
            }
        }

        if (self.allowed_tools) |tools| {
            try args.append("--allowedTools");
            try args.append(tools[0]); // Simplified
        }

        if (self.disallowed_tools) |tools| {
            try args.append("--disallowedTools");
            try args.append(tools[0]); // Simplified
        }

        // Model
        if (self.model) |model| {
            try args.append("--model");
            try args.append(model);
        }

        if (self.fallback_model) |model| {
            try args.append("--fallback-model");
            try args.append(model);
        }

        // Limits
        if (self.max_turns) |turns| {
            try args.append("--max-turns");
            var buf: [16]u8 = undefined;
            const slice = std.fmt.bufPrint(&buf, "{d}", .{turns}) catch "1";
            try args.append(slice);
        }

        if (self.max_budget_usd) |budget| {
            try args.append("--max-budget-usd");
            var buf: [32]u8 = undefined;
            const slice = std.fmt.bufPrint(&buf, "{d:.2}", .{budget}) catch "1.00";
            try args.append(slice);
        }

        // Permission mode
        if (self.permission_mode != .default) {
            try args.append("--permission-mode");
            try args.append(self.permission_mode.toCliFlag());
        }

        // Session management
        if (self.continue_conversation) {
            try args.append("--continue");
        }

        if (self.resume_session) |session| {
            try args.append("--resume");
            try args.append(session);
        }

        // Advanced options
        if (self.betas) |betas| {
            try args.append("--betas");
            try args.append(betas[0]); // Simplified
        }

        if (self.max_thinking_tokens) |tokens| {
            try args.append("--max-thinking-tokens");
            var buf: [16]u8 = undefined;
            const slice = std.fmt.bufPrint(&buf, "{d}", .{tokens}) catch "1024";
            try args.append(slice);
        }

        if (self.json_schema) |schema| {
            try args.append("--json-schema");
            try args.append(schema);
        }

        if (self.add_dirs) |dirs| {
            for (dirs) |dir| {
                try args.append("--add-dir");
                try args.append(dir);
            }
        }

        if (self.include_partial_messages) {
            try args.append("--include-partial-messages");
        }

        if (self.fork_session) {
            try args.append("--fork-session");
        }

        if (self.mcp_config) |config| {
            try args.append("--mcp-config");
            try args.append(config);
        }

        if (self.settings) |s| {
            try args.append("--settings");
            try args.append(s);
        }
    }
};

test "options builds query command" {
    const allocator = std.testing.allocator;
    const opts = Options{
        .model = "claude-sonnet-4-5",
        .max_turns = 5,
    };

    const args = try opts.buildQueryCommand(allocator, "Hello");
    defer allocator.free(args);

    try std.testing.expect(args.len > 0);
    try std.testing.expectEqualStrings("claude", args[0]);
}
