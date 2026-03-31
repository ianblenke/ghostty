//! Monitors the agent-events.jsonl file for new lifecycle events from AI agents.
//! Uses GLib timer polling to check for new lines appended to the JSONL file.
//! Events update the AgentStatus in the WorktrunkStore.

const std = @import("std");
const Allocator = std.mem.Allocator;
const glib = @import("glib");

const worktrunk_store = @import("worktrunk_store.zig");
const hook_installer = @import("worktrunk_hook_installer.zig");

const log = std.log.scoped(.worktrunk_event_tailer);

/// Event types from agent lifecycle.
pub const EventType = enum {
    start,
    stop,
    permission_request,
    session_end,

    pub fn fromString(s: []const u8) ?EventType {
        const lower_buf = blk: {
            var buf: [64]u8 = undefined;
            const len = @min(s.len, buf.len);
            for (0..len) |i| {
                buf[i] = std.ascii.toLower(s[i]);
            }
            break :blk buf[0..len];
        };

        if (std.mem.eql(u8, lower_buf, "start")) return .start;
        if (std.mem.eql(u8, lower_buf, "stop")) return .stop;
        if (std.mem.eql(u8, lower_buf, "permissionrequest")) return .permission_request;
        if (std.mem.eql(u8, lower_buf, "permission_request")) return .permission_request;
        if (std.mem.eql(u8, lower_buf, "sessionend")) return .session_end;
        if (std.mem.eql(u8, lower_buf, "session_end")) return .session_end;
        return null;
    }

    pub fn toAgentStatus(self: EventType) worktrunk_store.AgentStatus {
        return switch (self) {
            .start => .working,
            .stop => .review,
            .permission_request => .permission,
            .session_end => .review,
        };
    }
};

/// A parsed agent lifecycle event.
pub const AgentEvent = struct {
    event_type: EventType,
    cwd: []const u8,
    timestamp: []const u8,
};

/// The event tailer watches a JSONL file and reports new events via callback.
pub const EventTailer = struct {
    alloc: Allocator,
    events_path: []const u8,
    last_offset: u64,
    timer_id: ?c_uint,
    store: *worktrunk_store.WorktrunkStore,
    on_status_change: ?*const fn () void,

    pub fn init(alloc: Allocator, store: *worktrunk_store.WorktrunkStore) !EventTailer {
        const events_dir = try hook_installer.getEventsDir(alloc);
        defer alloc.free(events_dir);

        const events_path = try std.fmt.allocPrint(alloc, "{s}/agent-events.jsonl", .{events_dir});

        // Get current file size as starting offset (don't process old events)
        const initial_offset = blk: {
            const file = std.fs.openFileAbsolute(events_path, .{}) catch break :blk @as(u64, 0);
            defer file.close();
            const stat = file.stat() catch break :blk @as(u64, 0);
            break :blk stat.size;
        };

        return .{
            .alloc = alloc,
            .events_path = events_path,
            .last_offset = initial_offset,
            .timer_id = null,
            .store = store,
            .on_status_change = null,
        };
    }

    pub fn deinit(self: *EventTailer) void {
        if (self.timer_id) |id| {
            _ = glib.Source.remove(id);
            self.timer_id = null;
        }
        self.alloc.free(self.events_path);
    }

    /// Start polling for new events every 2 seconds.
    pub fn start(self: *EventTailer) void {
        if (self.timer_id != null) return;
        self.timer_id = glib.timeoutAdd(2000, onPoll, self);
    }

    /// Stop polling.
    pub fn stop(self: *EventTailer) void {
        if (self.timer_id) |id| {
            _ = glib.Source.remove(id);
            self.timer_id = null;
        }
    }

    fn onPoll(ud: ?*anyopaque) callconv(.c) c_int {
        const self: *EventTailer = @ptrCast(@alignCast(ud orelse return 0));
        self.pollNewEvents();
        return 1; // Continue polling
    }

    fn pollNewEvents(self: *EventTailer) void {
        const file = std.fs.openFileAbsolute(self.events_path, .{}) catch return;
        defer file.close();

        const stat = file.stat() catch return;
        if (stat.size <= self.last_offset) return;

        // Read new content
        file.seekTo(self.last_offset) catch return;
        const new_size = stat.size - self.last_offset;
        const read_size: usize = @min(@as(usize, @intCast(new_size)), 65536);

        var buf: [65536]u8 = undefined;
        const bytes_read = file.read(buf[0..read_size]) catch return;
        if (bytes_read == 0) return;

        self.last_offset += bytes_read;

        // Parse each line
        var changed = false;
        var line_iter = std.mem.splitScalar(u8, buf[0..bytes_read], '\n');
        while (line_iter.next()) |line| {
            if (line.len == 0) continue;
            if (self.processLine(line)) changed = true;
        }

        if (changed) {
            if (self.on_status_change) |cb| cb();
        }
    }

    fn processLine(self: *EventTailer, line: []const u8) bool {
        // Extract eventType
        const event_type_str = extractJsonString(line, "eventType") orelse return false;
        const event_type = EventType.fromString(event_type_str) orelse return false;
        const cwd = extractJsonString(line, "cwd") orelse return false;

        // Update agent status in store for matching worktrees
        const new_status = event_type.toAgentStatus();
        var updated = false;

        for (self.store.repositories.items) |*repo| {
            for (repo.worktrees.items) |*wt| {
                if (std.mem.startsWith(u8, cwd, wt.path)) {
                    for (wt.sessions.items) |*session| {
                        if (session.status != new_status) {
                            session.status = new_status;
                            updated = true;
                        }
                    }
                }
            }
        }

        if (updated) {
            log.info("agent status update: {s} -> {s} for cwd {s}", .{
                event_type_str,
                @tagName(new_status),
                cwd,
            });
        }

        return updated;
    }
};

/// Extract a string value from a JSON line by key name (simple pattern match).
fn extractJsonString(line: []const u8, key: []const u8) ?[]const u8 {
    var search_buf: [256]u8 = undefined;
    const search = std.fmt.bufPrint(&search_buf, "\"{s}\"", .{key}) catch return null;

    const key_pos = std.mem.indexOf(u8, line, search) orelse return null;
    const after_key = line[key_pos + search.len ..];

    var i: usize = 0;
    while (i < after_key.len and (after_key[i] == ':' or after_key[i] == ' ')) : (i += 1) {}
    if (i >= after_key.len or after_key[i] != '"') return null;
    i += 1;

    const start = i;
    while (i < after_key.len and after_key[i] != '"') : (i += 1) {}
    if (i >= after_key.len) return null;

    return after_key[start..i];
}
