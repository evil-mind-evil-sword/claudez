//! claudez - Claude Code SDK for Zig
//!
//! Provides programmatic access to Claude's agentic capabilities by wrapping
//! the Claude Code CLI. Supports one-shot queries, streaming conversations,
//! hooks, and custom MCP tools.
//!
//! ## Quick Start
//!
//! ```zig
//! const claudez = @import("claudez");
//!
//! // One-shot query
//! var iter = try claudez.query(allocator, "What is 2+2?", null);
//! defer iter.deinit();
//!
//! while (try iter.next()) |msg| {
//!     if (msg == .assistant) {
//!         for (msg.assistant.content) |block| {
//!             if (block == .text) {
//!                 std.debug.print("{s}", .{block.text.text});
//!             }
//!         }
//!     }
//! }
//! ```
//!
//! ## Streaming Client
//!
//! ```zig
//! var client = try claudez.Client.init(allocator, null);
//! defer client.deinit();
//!
//! try client.connect();
//! try client.query("Hello!");
//!
//! for (try client.receiveResponse()) |msg| {
//!     // Process messages
//! }
//! ```

const std = @import("std");

// Re-export all public types and functions
pub const errors = @import("errors.zig");
pub const ClaudeError = errors.ClaudeError;
pub const Error = errors.Error;

pub const options = @import("options.zig");
pub const Options = options.Options;
pub const PermissionMode = options.PermissionMode;
pub const SystemPrompt = options.SystemPrompt;

pub const messages = @import("messages.zig");
pub const Message = messages.Message;
pub const ContentBlock = messages.ContentBlock;
pub const TextBlock = messages.TextBlock;
pub const ThinkingBlock = messages.ThinkingBlock;
pub const ToolUseBlock = messages.ToolUseBlock;
pub const ToolResultBlock = messages.ToolResultBlock;
pub const UserMessage = messages.UserMessage;
pub const AssistantMessage = messages.AssistantMessage;
pub const SystemMessage = messages.SystemMessage;
pub const ResultMessage = messages.ResultMessage;
pub const StreamEvent = messages.StreamEvent;
pub const getTextContent = messages.getTextContent;

pub const transport = @import("transport.zig");
pub const Transport = transport.Transport;
pub const MessageQueue = transport.MessageQueue;

pub const query_mod = @import("query.zig");
pub const query = query_mod.query;
pub const queryText = query_mod.queryText;
pub const QueryIterator = query_mod.QueryIterator;

pub const client = @import("client.zig");
pub const Client = client.Client;

pub const hooks = @import("hooks.zig");
pub const HookEvent = hooks.HookEvent;
pub const HookInput = hooks.HookInput;
pub const HookOutput = hooks.HookOutput;
pub const HookCallback = hooks.HookCallback;
pub const HookMatcher = hooks.HookMatcher;
pub const HookConfig = hooks.HookConfig;
pub const PermissionDecision = hooks.PermissionDecision;

pub const mcp = @import("mcp.zig");
pub const McpServer = mcp.McpServer;
pub const Tool = mcp.Tool;
pub const ToolHandler = mcp.ToolHandler;
pub const ToolResult = mcp.ToolResult;
pub const ToolContext = mcp.ToolContext;
pub const ContentItem = mcp.ContentItem;
pub const createSdkMcpServer = mcp.createSdkMcpServer;

test {
    // Run all module tests
    std.testing.refAllDecls(@This());
}
