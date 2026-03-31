//! GitHub PR status integration for Ghostree sidebar.
//! Fetches PR state and CI check status per worktree branch using the `gh` CLI.

const std = @import("std");
const Allocator = std.mem.Allocator;
const glib = @import("glib");

const log = std.log.scoped(.worktrunk_github);

/// PR state from GitHub.
pub const PrState = enum {
    none, // No PR for this branch
    open,
    draft,
    merged,
    closed,
};

/// Aggregate CI check status.
pub const CiStatus = enum {
    none, // No checks
    pending,
    passing,
    failing,
};

/// Combined PR + CI status for a worktree branch.
pub const PrStatus = struct {
    state: PrState = .none,
    ci: CiStatus = .none,
    pr_number: ?u32 = null,
};

/// Manages GitHub PR status lookups, caching results per branch.
pub const GitHubStatusManager = struct {
    alloc: Allocator,
    /// Cached status per repo_path:branch key
    cache: std.StringHashMapUnmanaged(PrStatus),
    timer_id: ?c_uint = null,
    gh_available: bool,
    on_update: ?*const fn () void = null,

    /// Repo paths + branches to query
    queries: std.ArrayListUnmanaged(Query) = .{},

    const Query = struct {
        repo_path: []const u8,
        branch: []const u8,
        cache_key: []const u8,
    };

    pub fn init(alloc: Allocator) GitHubStatusManager {
        return .{
            .alloc = alloc,
            .cache = .{},
            .gh_available = checkGhAvailable(alloc),
        };
    }

    pub fn deinit(self: *GitHubStatusManager) void {
        if (self.timer_id) |id| {
            _ = glib.Source.remove(id);
            self.timer_id = null;
        }
        // Free cache keys
        var iter = self.cache.iterator();
        while (iter.next()) |entry| {
            self.alloc.free(entry.key_ptr.*);
        }
        self.cache.deinit(self.alloc);
        for (self.queries.items) |q| {
            self.alloc.free(q.cache_key);
        }
        self.queries.deinit(self.alloc);
    }

    /// Set which branches to query. Call this when worktrees change.
    pub fn setQueries(self: *GitHubStatusManager, repos: anytype) void {
        // Clear old queries
        for (self.queries.items) |q| {
            self.alloc.free(q.cache_key);
        }
        self.queries.clearRetainingCapacity();

        for (repos) |repo| {
            for (repo.worktrees.items) |wt| {
                if (wt.is_main) continue; // Skip main branch (usually no PR)
                const key = std.fmt.allocPrint(self.alloc, "{s}:{s}", .{ repo.path, wt.branch }) catch continue;
                self.queries.append(self.alloc, .{
                    .repo_path = repo.path,
                    .branch = wt.branch,
                    .cache_key = key,
                }) catch {
                    self.alloc.free(key);
                };
            }
        }
    }

    /// Start periodic polling (every 60 seconds).
    pub fn start(self: *GitHubStatusManager) void {
        if (!self.gh_available) return;
        if (self.timer_id != null) return;
        // Do first fetch immediately
        _ = glib.idleAdd(onFirstFetch, self);
        // Then every 60s
        self.timer_id = glib.timeoutAdd(60000, onPoll, self);
    }

    /// Get cached status for a branch.
    pub fn getStatus(self: *const GitHubStatusManager, repo_path: []const u8, branch: []const u8) PrStatus {
        var key_buf: [std.fs.max_path_bytes]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "{s}:{s}", .{ repo_path, branch }) catch return .{};
        return self.cache.get(key) orelse .{};
    }

    fn onFirstFetch(ud: ?*anyopaque) callconv(.c) c_int {
        const self: *GitHubStatusManager = @ptrCast(@alignCast(ud orelse return 0));
        self.fetchAll();
        return 0; // Don't repeat (timer handles it)
    }

    fn onPoll(ud: ?*anyopaque) callconv(.c) c_int {
        const self: *GitHubStatusManager = @ptrCast(@alignCast(ud orelse return 0));
        self.fetchAll();
        return 1; // Continue
    }

    fn fetchAll(self: *GitHubStatusManager) void {
        var changed = false;
        for (self.queries.items) |q| {
            const status = fetchPrStatus(self.alloc, q.repo_path, q.branch);
            const existing = self.cache.get(q.cache_key);
            if (existing == null or existing.?.state != status.state or existing.?.ci != status.ci) {
                // Update cache
                const owned_key = self.alloc.dupe(u8, q.cache_key) catch continue;
                if (self.cache.fetchPut(self.alloc, owned_key, status) catch null) |old| {
                    self.alloc.free(old.key);
                }
                changed = true;
            }
        }
        if (changed) {
            if (self.on_update) |cb| cb();
        }
    }
};

/// Fetch PR status for a single branch via `gh pr view`.
fn fetchPrStatus(alloc: Allocator, repo_path: []const u8, branch: []const u8) PrStatus {
    var child = std.process.Child.init(
        &.{ "gh", "pr", "view", branch, "--json", "state,isDraft,number,statusCheckRollup", "--jq", ".state + \" \" + (if .isDraft then \"draft\" else \"nodraft\") + \" \" + (.number | tostring) + \" \" + ([.statusCheckRollup[]?.conclusion // \"PENDING\"] | if length == 0 then \"NONE\" elif all(. == \"SUCCESS\") then \"SUCCESS\" elif any(. == \"FAILURE\") then \"FAILURE\" else \"PENDING\" end)" },
        alloc,
    );
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    child.cwd = repo_path;

    child.spawn() catch return .{};

    var stdout: std.ArrayListUnmanaged(u8) = .{};
    var stderr: std.ArrayListUnmanaged(u8) = .{};

    child.collectOutput(alloc, &stdout, &stderr, 4096) catch return .{};
    defer {
        stdout.deinit(alloc);
        stderr.deinit(alloc);
    }

    const term = child.wait() catch return .{};
    switch (term) {
        .Exited => |rc| if (rc != 0) return .{},
        else => return .{},
    }

    if (stdout.items.len == 0) return .{};

    // Parse: "OPEN nodraft 123 SUCCESS"
    const output = std.mem.trimRight(u8, stdout.items, "\n\r ");
    var parts = std.mem.splitScalar(u8, output, ' ');
    const state_str = parts.next() orelse return .{};
    const draft_str = parts.next() orelse "nodraft";
    const number_str = parts.next() orelse "0";
    const ci_str = parts.next() orelse "NONE";

    const state: PrState = blk: {
        if (std.mem.eql(u8, draft_str, "draft")) break :blk .draft;
        if (std.mem.eql(u8, state_str, "OPEN")) break :blk .open;
        if (std.mem.eql(u8, state_str, "MERGED")) break :blk .merged;
        if (std.mem.eql(u8, state_str, "CLOSED")) break :blk .closed;
        break :blk .none;
    };

    const ci: CiStatus = blk: {
        if (std.mem.eql(u8, ci_str, "SUCCESS")) break :blk .passing;
        if (std.mem.eql(u8, ci_str, "FAILURE")) break :blk .failing;
        if (std.mem.eql(u8, ci_str, "PENDING")) break :blk .pending;
        break :blk .none;
    };

    const pr_number = std.fmt.parseInt(u32, number_str, 10) catch null;

    return .{
        .state = state,
        .ci = ci,
        .pr_number = pr_number,
    };
}

fn checkGhAvailable(alloc: Allocator) bool {
    var child = std.process.Child.init(&.{ "gh", "--version" }, alloc);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    child.spawn() catch return false;
    var stdout: std.ArrayListUnmanaged(u8) = .{};
    var stderr: std.ArrayListUnmanaged(u8) = .{};
    child.collectOutput(alloc, &stdout, &stderr, 4096) catch return false;
    defer {
        stdout.deinit(alloc);
        stderr.deinit(alloc);
    }
    const term = child.wait() catch return false;
    return switch (term) {
        .Exited => |rc| rc == 0,
        else => false,
    };
}
