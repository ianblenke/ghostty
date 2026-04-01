//! State management for Ghostree worktrunk sidebar.
//! Manages repositories, worktrees, and AI agent sessions.

const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");

const internal_os = @import("../../os/main.zig");
const wt_client = @import("worktrunk_client.zig");

const log = std.log.scoped(.worktrunk_store);

/// Agent types that can have sessions.
pub const AgentType = enum {
    claude,
    codex,
    opencode,
    copilot,

    pub fn displayName(self: AgentType) []const u8 {
        return switch (self) {
            .claude => "Claude",
            .codex => "Codex",
            .opencode => "OpenCode",
            .copilot => "Copilot",
        };
    }
};

/// Status of an AI agent.
pub const AgentStatus = enum {
    idle,
    working,
    permission,
    review,
};

/// An AI agent session associated with a worktree.
pub const AgentSession = struct {
    id: []const u8,
    source: AgentType,
    worktree_path: []const u8,
    cwd: []const u8,
    timestamp: i64,
    snippet: ?[]const u8,
    message_count: u32,
    status: AgentStatus,
};

/// A git worktree within a repository.
pub const Worktree = struct {
    branch: []const u8,
    path: []const u8,
    is_main: bool,
    is_current: bool,
    sessions: std.ArrayListUnmanaged(AgentSession),

    pub fn deinit(self: *Worktree, alloc: Allocator) void {
        self.sessions.deinit(alloc);
    }
};

/// A tracked git repository.
pub const Repository = struct {
    path: []const u8,
    name: []const u8,
    worktrees: std.ArrayListUnmanaged(Worktree),
    expanded: bool,
    is_loading: bool,

    pub fn deinit(self: *Repository, alloc: Allocator) void {
        for (self.worktrees.items) |*wt| wt.deinit(alloc);
        self.worktrees.deinit(alloc);
    }
};

/// Serializable repository entry for persistence.
const PersistedRepo = struct {
    path: []const u8,
    name: ?[]const u8 = null,
};

/// The worktrunk store manages all sidebar state.
/// Cached session metadata to avoid re-parsing unchanged JSONL files.
const SessionCacheEntry = struct {
    mtime: i64,
    size: u64,
    message_count: u32,
    cwd: []const u8,
};

pub const WorktrunkStore = struct {
    alloc: Allocator,
    repositories: std.ArrayListUnmanaged(Repository),
    wt_available: bool,
    /// Session cache keyed by file path (project_name/session_filename)
    session_cache: std.StringHashMapUnmanaged(SessionCacheEntry),

    pub fn init(alloc: Allocator) WorktrunkStore {
        return .{
            .alloc = alloc,
            .repositories = .{},
            .wt_available = wt_client.isAvailable(alloc),
            .session_cache = .{},
        };
    }

    pub fn deinit(self: *WorktrunkStore) void {
        for (self.repositories.items) |*repo| repo.deinit(self.alloc);
        self.repositories.deinit(self.alloc);
        // Free cache
        var cache_iter = self.session_cache.iterator();
        while (cache_iter.next()) |entry| {
            self.alloc.free(entry.key_ptr.*);
            self.alloc.free(entry.value_ptr.cwd);
        }
        self.session_cache.deinit(self.alloc);
    }

    /// Add a repository by path. Returns the index of the new repo.
    pub fn addRepository(self: *WorktrunkStore, path: []const u8) !usize {
        // Check for duplicates
        for (self.repositories.items) |repo| {
            if (std.mem.eql(u8, repo.path, path)) return error.AlreadyExists;
        }

        const owned_path = try self.alloc.dupe(u8, path);
        errdefer self.alloc.free(owned_path);

        const name = std.fs.path.basename(path);
        const owned_name = try self.alloc.dupe(u8, name);

        try self.repositories.append(self.alloc, .{
            .path = owned_path,
            .name = owned_name,
            .worktrees = .{},
            .expanded = true,
            .is_loading = false,
        });

        return self.repositories.items.len - 1;
    }

    /// Remove a repository by index.
    pub fn removeRepository(self: *WorktrunkStore, index: usize) void {
        if (index >= self.repositories.items.len) return;
        var repo = self.repositories.orderedRemove(index);
        self.alloc.free(repo.path);
        self.alloc.free(repo.name);
        repo.deinit(self.alloc);
    }

    /// Refresh worktrees for a specific repository.
    pub fn refreshWorktrees(self: *WorktrunkStore, repo_index: usize) !void {
        if (repo_index >= self.repositories.items.len) return;
        var repo = &self.repositories.items[repo_index];

        // Clear existing worktrees
        for (repo.worktrees.items) |*wt| wt.deinit(self.alloc);
        repo.worktrees.clearRetainingCapacity();

        if (!self.wt_available) {
            // If wt is not available, just show the repo root as a single entry
            const owned_branch = try self.alloc.dupe(u8, "main");
            const owned_path = try self.alloc.dupe(u8, repo.path);
            try repo.worktrees.append(self.alloc, .{
                .branch = owned_branch,
                .path = owned_path,
                .is_main = true,
                .is_current = true,
                .sessions = .{},
            });
            return;
        }

        // Use wt CLI to list worktrees
        var result = wt_client.listWorktrees(self.alloc, repo.path) catch |err| {
            log.warn("failed to list worktrees for {s}: {}", .{ repo.path, err });
            return;
        };
        defer result.deinit();

        for (result.items) |item| {
            // Only include worktree kind entries
            if (!std.mem.eql(u8, item.kind, "worktree")) continue;
            const wt_path = item.path orelse continue;
            const branch = item.branch orelse "unknown";

            const owned_branch = try self.alloc.dupe(u8, branch);
            errdefer self.alloc.free(owned_branch);
            const owned_path = try self.alloc.dupe(u8, wt_path);

            try repo.worktrees.append(self.alloc, .{
                .branch = owned_branch,
                .path = owned_path,
                .is_main = item.isMain,
                .is_current = item.isCurrent,
                .sessions = .{},
            });
        }
    }

    /// Refresh all repositories' worktrees.
    pub fn refreshAll(self: *WorktrunkStore) void {
        for (0..self.repositories.items.len) |i| {
            self.refreshWorktrees(i) catch |err| {
                log.warn("failed to refresh repo {d}: {}", .{ i, err });
            };
        }
    }

    /// Scan for Claude sessions and map them to worktrees.
    pub fn scanClaudeSessions(self: *WorktrunkStore) !void {
        // Clear existing sessions from all worktrees
        for (self.repositories.items) |*repo| {
            for (repo.worktrees.items) |*wt| {
                wt.sessions.clearRetainingCapacity();
            }
        }

        // Scan ~/.claude/projects/
        const home = std.posix.getenv("HOME") orelse return;
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const claude_projects_path = std.fmt.bufPrint(
            &path_buf,
            "{s}/.claude/projects",
            .{home},
        ) catch return;

        var projects_dir = std.fs.openDirAbsolute(claude_projects_path, .{
            .iterate = true,
        }) catch return;
        defer projects_dir.close();

        var project_iter = projects_dir.iterate();
        while (project_iter.next() catch null) |project_entry| {
            if (project_entry.kind != .directory) continue;

            var project_dir = projects_dir.openDir(project_entry.name, .{
                .iterate = true,
            }) catch continue;
            defer project_dir.close();

            // Each file in the project dir is a session JSONL
            var session_iter = project_dir.iterate();
            while (session_iter.next() catch null) |session_entry| {
                if (session_entry.kind != .file) continue;
                if (!std.mem.endsWith(u8, session_entry.name, ".jsonl")) continue;

                self.processClaudeSession(
                    project_dir,
                    session_entry.name,
                    project_entry.name,
                ) catch |err| {
                    log.debug("failed to process session {s}: {}", .{ session_entry.name, err });
                };
            }
        }
    }

    fn processClaudeSession(
        self: *WorktrunkStore,
        project_dir: std.fs.Dir,
        session_filename: []const u8,
        project_name: []const u8,
    ) !void {
        const file = try project_dir.openFile(session_filename, .{});
        defer file.close();

        const stat = try file.stat();
        if (stat.size == 0) return;

        const file_mtime: i64 = @intCast(@divFloor(stat.mtime, std.time.ns_per_s));

        // Build cache key: project_name/session_filename
        var cache_key_buf: [std.fs.max_path_bytes]u8 = undefined;
        const cache_key = std.fmt.bufPrint(&cache_key_buf, "{s}/{s}", .{ project_name, session_filename }) catch return;

        // Check cache — skip if file hasn't changed
        if (self.session_cache.get(cache_key)) |cached| {
            if (cached.mtime == file_mtime and cached.size == stat.size) {
                // Use cached data
                const session_id = if (std.mem.endsWith(u8, session_filename, ".jsonl"))
                    session_filename[0 .. session_filename.len - 6]
                else
                    session_filename;

                for (self.repositories.items) |*repo| {
                    for (repo.worktrees.items) |*wt| {
                        if (std.mem.startsWith(u8, cached.cwd, wt.path)) {
                            const owned_id = try self.alloc.dupe(u8, session_id);
                            errdefer self.alloc.free(owned_id);
                            const owned_wt_path = try self.alloc.dupe(u8, wt.path);
                            errdefer self.alloc.free(owned_wt_path);
                            const owned_cwd = try self.alloc.dupe(u8, cached.cwd);

                            try wt.sessions.append(self.alloc, .{
                                .id = owned_id,
                                .source = .claude,
                                .worktree_path = owned_wt_path,
                                .cwd = owned_cwd,
                                .timestamp = file_mtime,
                                .snippet = null,
                                .message_count = cached.message_count,
                                .status = .idle,
                            });
                            return;
                        }
                    }
                }
                return;
            }
        }

        // Read last few KB to find recent data
        const read_size: u64 = @min(stat.size, 8192);
        const offset: u64 = stat.size - read_size;
        try file.seekTo(offset);

        var buf: [8192]u8 = undefined;
        const bytes_read = try file.read(&buf);
        if (bytes_read == 0) return;
        const content = buf[0..bytes_read];

        // Find the last complete JSON line
        var last_line: ?[]const u8 = null;
        var cwd: ?[]const u8 = null;
        var message_count: u32 = 0;

        var line_iter = std.mem.splitScalar(u8, content, '\n');
        while (line_iter.next()) |line| {
            if (line.len == 0) continue;
            // Skip incomplete lines if we started mid-file
            if (offset > 0 and last_line == null and line.ptr == content.ptr) continue;

            last_line = line;

            // Try to extract cwd from this line
            if (std.mem.indexOf(u8, line, "\"cwd\"")) |_| {
                if (extractJsonString(line, "cwd")) |found_cwd| {
                    cwd = found_cwd;
                }
            }
            // Count user messages
            if (std.mem.indexOf(u8, line, "\"type\":\"user\"") != null or
                std.mem.indexOf(u8, line, "\"type\": \"user\"") != null)
            {
                message_count += 1;
            }
        }

        const session_cwd = cwd orelse return;

        // Update cache
        {
            const owned_cache_key = try self.alloc.dupe(u8, cache_key);
            const owned_cache_cwd = try self.alloc.dupe(u8, session_cwd);
            if (self.session_cache.fetchPut(self.alloc, owned_cache_key, .{
                .mtime = file_mtime,
                .size = stat.size,
                .message_count = message_count,
                .cwd = owned_cache_cwd,
            }) catch null) |old| {
                self.alloc.free(old.key);
                self.alloc.free(old.value.cwd);
            }
        }

        // Extract session ID from filename (strip .jsonl)
        const session_id = if (std.mem.endsWith(u8, session_filename, ".jsonl"))
            session_filename[0 .. session_filename.len - 6]
        else
            session_filename;

        // Find matching worktree by cwd prefix
        for (self.repositories.items) |*repo| {
            for (repo.worktrees.items) |*wt| {
                if (std.mem.startsWith(u8, session_cwd, wt.path)) {
                    const owned_id = try self.alloc.dupe(u8, session_id);
                    errdefer self.alloc.free(owned_id);
                    const owned_wt_path = try self.alloc.dupe(u8, wt.path);
                    errdefer self.alloc.free(owned_wt_path);
                    const owned_cwd = try self.alloc.dupe(u8, session_cwd);

                    try wt.sessions.append(self.alloc, .{
                        .id = owned_id,
                        .source = .claude,
                        .worktree_path = owned_wt_path,
                        .cwd = owned_cwd,
                        .timestamp = file_mtime,
                        .snippet = null,
                        .message_count = message_count,
                        .status = .idle,
                    });
                    return;
                }
            }
        }
    }

    /// Persist the repository list to disk.
    pub fn persist(self: *WorktrunkStore) !void {
        const data_dir = try getConfigDir(self.alloc);
        defer self.alloc.free(data_dir);

        // Ensure directory exists
        std.fs.makeDirAbsolute(data_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const file_path = try std.fmt.bufPrint(&path_buf, "{s}/repositories.json", .{data_dir});

        var file = try std.fs.createFileAbsolute(file_path, .{});
        defer file.close();

        var repos_to_save: std.ArrayListUnmanaged(PersistedRepo) = .{};
        defer repos_to_save.deinit(self.alloc);

        for (self.repositories.items) |repo| {
            try repos_to_save.append(self.alloc, .{
                .path = repo.path,
                .name = repo.name,
            });
        }

        // Write JSON manually
        try file.writeAll("[");
        for (repos_to_save.items, 0..) |repo, i| {
            if (i > 0) try file.writeAll(",");
            try file.writeAll("{\"path\":\"");
            try file.writeAll(repo.path);
            try file.writeAll("\"");
            if (repo.name) |name| {
                try file.writeAll(",\"name\":\"");
                try file.writeAll(name);
                try file.writeAll("\"");
            }
            try file.writeAll("}");
        }
        try file.writeAll("]");
    }

    /// Load persisted repository list from disk.
    pub fn load(self: *WorktrunkStore) !void {
        const data_dir = try getConfigDir(self.alloc);
        defer self.alloc.free(data_dir);

        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const file_path = try std.fmt.bufPrint(&path_buf, "{s}/repositories.json", .{data_dir});

        const file = std.fs.openFileAbsolute(file_path, .{}) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer file.close();

        const content = try file.readToEndAlloc(self.alloc, 1024 * 1024);
        defer self.alloc.free(content);

        if (content.len == 0) return;

        const parsed = std.json.parseFromSlice(
            []PersistedRepo,
            self.alloc,
            content,
            .{ .ignore_unknown_fields = true },
        ) catch |err| {
            log.warn("failed to parse repositories.json: {}", .{err});
            return;
        };
        defer parsed.deinit();

        for (parsed.value) |repo| {
            _ = self.addRepository(repo.path) catch |err| {
                log.warn("failed to add persisted repo {s}: {}", .{ repo.path, err });
            };
        }
    }

    /// Get total number of items for display (repos + worktrees + sessions).
    pub fn totalDisplayItems(self: *const WorktrunkStore) usize {
        var count: usize = 0;
        for (self.repositories.items) |repo| {
            count += 1; // repo header
            if (repo.expanded) {
                count += repo.worktrees.items.len;
                for (repo.worktrees.items) |wt| {
                    count += wt.sessions.items.len;
                }
            }
        }
        return count;
    }

    /// Types of sidebar rows.
    pub const RowKind = enum { repo, worktree, session };

    /// Represents a single row in the sidebar display.
    pub const DisplayRow = struct {
        kind: RowKind,
        repo_index: usize,
        worktree_index: ?usize,
        session_index: ?usize,
    };

    /// Get the display row at a given flat index. Returns null if out of bounds.
    pub fn getDisplayRow(self: *const WorktrunkStore, flat_index: usize) ?DisplayRow {
        var current: usize = 0;
        for (self.repositories.items, 0..) |repo, ri| {
            if (current == flat_index) {
                return .{
                    .kind = .repo,
                    .repo_index = ri,
                    .worktree_index = null,
                    .session_index = null,
                };
            }
            current += 1;

            if (repo.expanded) {
                for (repo.worktrees.items, 0..) |wt, wi| {
                    if (current == flat_index) {
                        return .{
                            .kind = .worktree,
                            .repo_index = ri,
                            .worktree_index = wi,
                            .session_index = null,
                        };
                    }
                    current += 1;

                    for (0..wt.sessions.items.len) |si| {
                        if (current == flat_index) {
                            return .{
                                .kind = .session,
                                .repo_index = ri,
                                .worktree_index = wi,
                                .session_index = si,
                            };
                        }
                        current += 1;
                    }
                }
            }
        }
        return null;
    }
};

/// Extract a string value from a JSON line by key name (simple pattern match).
fn extractJsonString(line: []const u8, key: []const u8) ?[]const u8 {
    // Look for "key":"value" or "key": "value"
    var search_buf: [256]u8 = undefined;
    const search = std.fmt.bufPrint(&search_buf, "\"{s}\"", .{key}) catch return null;

    const key_pos = std.mem.indexOf(u8, line, search) orelse return null;
    const after_key = line[key_pos + search.len ..];

    // Skip : and whitespace
    var i: usize = 0;
    while (i < after_key.len and (after_key[i] == ':' or after_key[i] == ' ')) : (i += 1) {}
    if (i >= after_key.len or after_key[i] != '"') return null;
    i += 1; // skip opening quote

    const start = i;
    while (i < after_key.len and after_key[i] != '"') : (i += 1) {}
    if (i >= after_key.len) return null;

    return after_key[start..i];
}

/// Get the config directory for ghostree (XDG_CONFIG_HOME/ghostree).
fn getConfigDir(alloc: Allocator) ![]const u8 {
    return try internal_os.xdg.config(alloc, .{ .subdir = "ghostree" });
}

/// Get the XDG cache directory for ghostree.
pub fn getCacheDir(alloc: Allocator) ![]const u8 {
    return try internal_os.xdg.cache(alloc, .{ .subdir = "ghostree" });
}
