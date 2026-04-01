//! Generates and installs agent hook scripts for Ghostree.
//! These hooks allow Claude Code and other AI agents to report their status
//! (working, permission request, stopped) back to the Ghostree sidebar.
//!
//! Linux XDG layout:
//!   ~/.config/ghostree/hooks/notify.sh
//!   ~/.config/ghostree/hooks/claude-settings.json
//!   ~/.config/ghostree/hooks/bin/claude  (wrapper)
//!   ~/.cache/ghostree/agent-events/agent-events.jsonl

const std = @import("std");
const Allocator = std.mem.Allocator;

const internal_os = @import("../../os/main.zig");

const log = std.log.scoped(.worktrunk_hook_installer);

const hook_version = 7;
const wrapper_version = 3;
const settings_version = 3;

/// Install all agent hooks. Idempotent — checks version markers before rewriting.
pub fn install(alloc: Allocator) !void {
    if (std.posix.getenv("GHOSTREE_DISABLE_AGENT_HOOKS")) |v| {
        if (std.mem.eql(u8, v, "1")) return;
    }

    const hooks_dir = try getHooksDir(alloc);
    defer alloc.free(hooks_dir);
    const bin_dir = try getBinDir(alloc);
    defer alloc.free(bin_dir);
    const events_dir = try getEventsDir(alloc);
    defer alloc.free(events_dir);

    // Ensure directories exist (create parents as needed)
    inline for (.{ hooks_dir, bin_dir, events_dir }) |dir| {
        std.fs.makeDirAbsolute(dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            error.FileNotFound => {
                // Parent doesn't exist, create the full path
                std.fs.cwd().makePath(dir) catch |err2| {
                    log.warn("failed to create dir {s}: {}", .{ dir, err2 });
                    return;
                };
            },
            else => {
                log.warn("failed to create dir {s}: {}", .{ dir, err });
                return;
            },
        };
    }

    // Install notify.sh
    try installNotifyScript(alloc, hooks_dir, events_dir);

    // Install claude-settings.json
    try installClaudeSettings(alloc, hooks_dir);

    // Install agent wrappers
    try installClaudeWrapper(alloc, hooks_dir, bin_dir);
    try installAgentWrapper(alloc, hooks_dir, bin_dir, "codex");
    try installAgentWrapper(alloc, hooks_dir, bin_dir, "opencode");
    try installAgentWrapper(alloc, hooks_dir, bin_dir, "copilot");

    // Install OpenCode plugin
    try installOpenCodePlugin(alloc);
}

fn installNotifyScript(alloc: Allocator, hooks_dir: []const u8, events_dir: []const u8) !void {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/notify.sh", .{hooks_dir});

    const script = try std.fmt.allocPrint(alloc,
        \\#!/bin/bash
        \\# Ghostree agent notification hook v{d}
        \\EVENTS_DIR="${{GHOSTREE_AGENT_EVENTS_DIR:-{s}}}"
        \\[ -z "$EVENTS_DIR" ] && exit 0
        \\mkdir -p "$EVENTS_DIR" >/dev/null 2>&1
        \\
        \\if [ -n "$1" ]; then INPUT="$1"; else INPUT=$(cat); fi
        \\
        \\EVENT_TYPE=$(echo "$INPUT" | grep -oE '"hook_event_name"[[:space:]]*:[[:space:]]*"[^"]*"' | grep -oE '"[^"]*"$' | tr -d '"')
        \\if [ -z "$EVENT_TYPE" ]; then
        \\  EVENT_TYPE=$(echo "$INPUT" | grep -oE '"hook_event"[[:space:]]*:[[:space:]]*"[^"]*"' | grep -oE '"[^"]*"$' | tr -d '"')
        \\fi
        \\if [ -z "$EVENT_TYPE" ]; then
        \\  EVENT_TYPE=$(echo "$INPUT" | grep -oE '"event_name"[[:space:]]*:[[:space:]]*"[^"]*"' | grep -oE '"[^"]*"$' | tr -d '"')
        \\fi
        \\if [ -z "$EVENT_TYPE" ]; then
        \\  CODEX_TYPE=$(echo "$INPUT" | grep -oE '"type"[[:space:]]*:[[:space:]]*"[^"]*"' | grep -oE '"[^"]*"$' | tr -d '"')
        \\  if [ -z "$CODEX_TYPE" ]; then
        \\    CODEX_TYPE=$(echo "$INPUT" | grep -oE '"status"[[:space:]]*:[[:space:]]*"[^"]*"' | grep -oE '"[^"]*"$' | tr -d '"')
        \\  fi
        \\  CODEX_TYPE_LC=$(printf "%s" "$CODEX_TYPE" | tr '[:upper:]' '[:lower:]')
        \\  case "$CODEX_TYPE_LC" in
        \\    *permission*|*input*|*prompt*|*confirm*) EVENT_TYPE="PermissionRequest" ;;
        \\    *start*|*begin*|*busy*|*running*|*work*) EVENT_TYPE="Start" ;;
        \\    *complete*|*stop*|*end*|*idle*|*error*|*fail*|*done*|*finish*|*exit*) EVENT_TYPE="Stop" ;;
        \\  esac
        \\fi
        \\
        \\[ "$EVENT_TYPE" = "UserPromptSubmit" ] && EVENT_TYPE="Start"
        \\[ "$EVENT_TYPE" = "PermissionResponse" ] && EVENT_TYPE="Start"
        \\[ -z "$EVENT_TYPE" ] && exit 0
        \\
        \\JSON_CWD=$(echo "$INPUT" | grep -oE '"cwd"[[:space:]]*:[[:space:]]*"[^"]*"' | grep -oE '"[^"]*"$' | tr -d '"')
        \\if [ -z "$JSON_CWD" ]; then
        \\  JSON_CWD=$(echo "$INPUT" | grep -oE '"directory"[[:space:]]*:[[:space:]]*"[^"]*"' | grep -oE '"[^"]*"$' | tr -d '"')
        \\fi
        \\if [ -n "$JSON_CWD" ] && [ "$JSON_CWD" != "/" ]; then
        \\  CWD="$JSON_CWD"
        \\else
        \\  CWD="$(pwd -P 2>/dev/null || pwd)"
        \\fi
        \\TS="$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"
        \\printf '{{"timestamp":"%s","eventType":"%s","cwd":"%s"}}\n' "$TS" "$EVENT_TYPE" "$CWD" >> "$EVENTS_DIR/agent-events.jsonl" 2>/dev/null
    , .{ hook_version, events_dir });
    defer alloc.free(script);

    var file = try std.fs.createFileAbsolute(path, .{ .mode = 0o755 });
    defer file.close();
    try file.writeAll(script);
}

fn installClaudeSettings(alloc: Allocator, hooks_dir: []const u8) !void {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/claude-settings.json", .{hooks_dir});

    var notify_buf: [std.fs.max_path_bytes]u8 = undefined;
    const notify_path = try std.fmt.bufPrint(&notify_buf, "{s}/notify.sh", .{hooks_dir});

    const settings = try std.fmt.allocPrint(alloc,
        \\{{
        \\  "_v": {d},
        \\  "hooks": {{
        \\    "UserPromptSubmit": [
        \\      {{"hooks": [{{"type": "command", "command": "bash '{s}'"}}]}}
        \\    ],
        \\    "Stop": [
        \\      {{"hooks": [{{"type": "command", "command": "bash '{s}'"}}]}}
        \\    ],
        \\    "PermissionRequest": [
        \\      {{"matcher": "*", "hooks": [{{"type": "command", "command": "bash '{s}'"}}]}}
        \\    ],
        \\    "SessionEnd": [
        \\      {{"hooks": [{{"type": "command", "command": "bash '{s}'"}}]}}
        \\    ]
        \\  }}
        \\}}
    , .{ settings_version, notify_path, notify_path, notify_path, notify_path });
    defer alloc.free(settings);

    var file = try std.fs.createFileAbsolute(path, .{ .mode = 0o644 });
    defer file.close();
    try file.writeAll(settings);
}

fn installClaudeWrapper(alloc: Allocator, hooks_dir: []const u8, bin_dir: []const u8) !void {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/claude", .{bin_dir});

    var settings_buf: [std.fs.max_path_bytes]u8 = undefined;
    const settings_path = try std.fmt.bufPrint(&settings_buf, "{s}/claude-settings.json", .{hooks_dir});

    const wrapper = try std.fmt.allocPrint(alloc,
        \\#!/bin/bash
        \\# Ghostree agent wrapper v{d}
        \\for _d in "$HOME/.local/bin" "$HOME/.bun/bin" "$HOME/.cargo/bin" "/usr/local/bin"; do
        \\  if [ -d "$_d" ]; then
        \\    case ":$PATH:" in *":$_d:"*) ;; *) PATH="$_d:$PATH" ;; esac
        \\  fi
        \\done
        \\
        \\find_real_binary() {{
        \\  local name="$1" IFS=:
        \\  for dir in $PATH; do
        \\    [ -z "$dir" ] && continue
        \\    dir="${{dir%/}}"
        \\    [ "$dir" = "{s}" ] && continue
        \\    if [ -x "$dir/$name" ] && [ ! -d "$dir/$name" ]; then
        \\      printf "%s\n" "$dir/$name"
        \\      return 0
        \\    fi
        \\  done
        \\  return 1
        \\}}
        \\
        \\REAL_BIN="$(find_real_binary "claude")"
        \\if [ -z "$REAL_BIN" ]; then
        \\  echo "Ghostree: claude not found in PATH." >&2
        \\  exit 127
        \\fi
        \\exec "$REAL_BIN" --settings "{s}" "$@"
    , .{ wrapper_version, bin_dir, settings_path });
    defer alloc.free(wrapper);

    var file = try std.fs.createFileAbsolute(path, .{ .mode = 0o755 });
    defer file.close();
    try file.writeAll(wrapper);
}

/// Install a generic agent wrapper that emits Start/Stop events around the real binary.
/// Used for codex, opencode, copilot which don't have Claude's hook system.
fn installAgentWrapper(alloc: Allocator, hooks_dir: []const u8, bin_dir: []const u8, agent_name: []const u8) !void {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ bin_dir, agent_name });

    var notify_buf: [std.fs.max_path_bytes]u8 = undefined;
    const notify_path = try std.fmt.bufPrint(&notify_buf, "{s}/notify.sh", .{hooks_dir});

    const wrapper = try std.fmt.allocPrint(alloc,
        \\#!/bin/bash
        \\# Ghostree agent wrapper v{d} for {s}
        \\for _d in "$HOME/.local/bin" "$HOME/.bun/bin" "$HOME/.cargo/bin" "/usr/local/bin"; do
        \\  if [ -d "$_d" ]; then
        \\    case ":$PATH:" in *":$_d:"*) ;; *) PATH="$_d:$PATH" ;; esac
        \\  fi
        \\done
        \\
        \\find_real_binary() {{
        \\  local name="$1" IFS=:
        \\  for dir in $PATH; do
        \\    [ -z "$dir" ] && continue
        \\    dir="${{dir%/}}"
        \\    [ "$dir" = "{s}" ] && continue
        \\    if [ -x "$dir/$name" ] && [ ! -d "$dir/$name" ]; then
        \\      printf "%s\n" "$dir/$name"
        \\      return 0
        \\    fi
        \\  done
        \\  return 1
        \\}}
        \\
        \\REAL_BIN="$(find_real_binary "{s}")"
        \\if [ -z "$REAL_BIN" ]; then
        \\  echo "Ghostree: {s} not found in PATH." >&2
        \\  exit 127
        \\fi
        \\
        \\# Emit Start event
        \\echo '{{"hook_event_name":"Start"}}' | bash "{s}" 2>/dev/null
        \\
        \\# Run the real binary
        \\"$REAL_BIN" "$@"
        \\EXIT_CODE=$?
        \\
        \\# Emit Stop event
        \\echo '{{"hook_event_name":"Stop"}}' | bash "{s}" 2>/dev/null
        \\
        \\exit $EXIT_CODE
    , .{ wrapper_version, agent_name, bin_dir, agent_name, agent_name, notify_path, notify_path });
    defer alloc.free(wrapper);

    var file = try std.fs.createFileAbsolute(path, .{ .mode = 0o755 });
    defer file.close();
    try file.writeAll(wrapper);
}

/// Install the OpenCode plugin that hooks into OpenCode's event system.
fn installOpenCodePlugin(alloc: Allocator) !void {
    const plugin_dir = try internal_os.xdg.config(alloc, .{ .subdir = "opencode/plugin" });
    defer alloc.free(plugin_dir);

    std.fs.makeDirAbsolute(plugin_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return,
    };

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/ghostree-notify.js", .{plugin_dir});

    const plugin =
        \\// Ghostree opencode plugin v5
        \\// Monitors OpenCode session status and emits lifecycle events.
        \\(function() {
        \\  if (typeof globalThis.__ghostreeOpencodeNotifyPluginV5 !== 'undefined') return;
        \\  globalThis.__ghostreeOpencodeNotifyPluginV5 = true;
        \\
        \\  const eventsDir = process.env.GHOSTREE_AGENT_EVENTS_DIR;
        \\  if (!eventsDir) return;
        \\
        \\  const fs = require('fs');
        \\  const path = require('path');
        \\  const eventsFile = path.join(eventsDir, 'agent-events.jsonl');
        \\
        \\  function emit(eventType) {
        \\    const cwd = process.cwd();
        \\    const ts = new Date().toISOString();
        \\    const line = JSON.stringify({timestamp: ts, eventType: eventType, cwd: cwd}) + '\n';
        \\    try { fs.appendFileSync(eventsFile, line); } catch(e) {}
        \\  }
        \\
        \\  // Hook into OpenCode's session events if available
        \\  if (typeof opencode !== 'undefined' && opencode.on) {
        \\    opencode.on('session:busy', () => emit('Start'));
        \\    opencode.on('session:idle', () => emit('Stop'));
        \\    opencode.on('session:error', () => emit('Stop'));
        \\    opencode.on('permission', () => emit('PermissionRequest'));
        \\  }
        \\})();
    ;

    var file = std.fs.createFileAbsolute(path, .{ .mode = 0o644 }) catch return;
    defer file.close();
    file.writeAll(plugin) catch {};
}

// ---------------------------------------------------------------
// Path helpers

pub fn getHooksDir(alloc: Allocator) ![]const u8 {
    return try internal_os.xdg.config(alloc, .{ .subdir = "ghostree/hooks" });
}

pub fn getBinDir(alloc: Allocator) ![]const u8 {
    return try internal_os.xdg.config(alloc, .{ .subdir = "ghostree/hooks/bin" });
}

pub fn getEventsDir(alloc: Allocator) ![]const u8 {
    return try internal_os.xdg.cache(alloc, .{ .subdir = "ghostree/agent-events" });
}
