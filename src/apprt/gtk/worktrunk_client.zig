//! Wrapper around the `wt` (Worktrunk) CLI tool for git worktree management.
//! Provides functions to list, create, switch, and remove worktrees.

const std = @import("std");
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.worktrunk_client);

/// A single worktree entry returned from `wt list --format=json`.
pub const WtListItem = struct {
    branch: ?[]const u8 = null,
    path: ?[]const u8 = null,
    kind: []const u8,
    isMain: bool = false,
    isCurrent: bool = false,
};

/// Result of listing worktrees for a repository.
pub const ListResult = struct {
    items: []WtListItem,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *ListResult) void {
        self.arena.deinit();
    }
};

/// Find the `wt` binary. Checks GHOSTTY_WORKTRUNK_BIN env, then common paths,
/// then falls back to just "wt" (PATH lookup).
pub fn findWtBinary(alloc: Allocator) ![]const u8 {
    // Check env override
    if (std.posix.getenv("GHOSTTY_WORKTRUNK_BIN")) |bin| {
        return try alloc.dupe(u8, bin);
    }

    // Check common install locations
    const paths = [_][]const u8{
        "/usr/local/bin/wt",
        "/usr/bin/wt",
    };

    for (paths) |path| {
        std.fs.accessAbsolute(path, .{}) catch continue;
        return try alloc.dupe(u8, path);
    }

    // Fall back to PATH resolution
    return try alloc.dupe(u8, "wt");
}

/// List worktrees for a given repository path.
/// Returns a ListResult that owns its memory; caller must call deinit().
pub fn listWorktrees(alloc: Allocator, repo_path: []const u8) !ListResult {
    var arena: std.heap.ArenaAllocator = .init(alloc);
    errdefer arena.deinit();
    const arena_alloc = arena.allocator();

    const wt_bin = try findWtBinary(arena_alloc);

    var child = std.process.Child.init(
        &.{ wt_bin, "-C", repo_path, "list", "--format=json" },
        arena_alloc,
    );
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();

    var stdout: std.ArrayListUnmanaged(u8) = .{};
    var stderr: std.ArrayListUnmanaged(u8) = .{};
    const max_output = 1024 * 1024; // 1MB

    try child.collectOutput(arena_alloc, &stdout, &stderr, max_output);
    const term = try child.wait();

    switch (term) {
        .Exited => |rc| {
            if (rc != 0) {
                if (stderr.items.len > 0) {
                    log.warn("wt list failed (rc={d}): {s}", .{ rc, stderr.items });
                }
                return error.WtListFailed;
            }
        },
        else => return error.WtListFailed,
    }

    if (stdout.items.len == 0) {
        return ListResult{
            .items = &.{},
            .arena = arena,
        };
    }

    // Parse JSON array
    const parsed = try std.json.parseFromSlice(
        []WtListItem,
        arena_alloc,
        stdout.items,
        .{ .ignore_unknown_fields = true },
    );

    return ListResult{
        .items = parsed.value,
        .arena = arena,
    };
}

/// Create a new worktree in the given repository for the specified branch.
pub fn addWorktree(alloc: Allocator, repo_path: []const u8, branch: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const wt_bin = try findWtBinary(arena_alloc);

    var child = std.process.Child.init(
        &.{ wt_bin, "-C", repo_path, "add", branch },
        arena_alloc,
    );
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();

    var stdout: std.ArrayListUnmanaged(u8) = .{};
    var stderr: std.ArrayListUnmanaged(u8) = .{};
    try child.collectOutput(arena_alloc, &stdout, &stderr, 1024 * 1024);
    const term = try child.wait();

    switch (term) {
        .Exited => |rc| {
            if (rc != 0) {
                if (stderr.items.len > 0) {
                    log.warn("wt add failed (rc={d}): {s}", .{ rc, stderr.items });
                }
                return error.WtAddFailed;
            }
        },
        else => return error.WtAddFailed,
    }
}

/// Remove a worktree at the given path.
pub fn removeWorktree(alloc: Allocator, path: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const wt_bin = try findWtBinary(arena_alloc);

    var child = std.process.Child.init(
        &.{ wt_bin, "remove", path },
        arena_alloc,
    );
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();

    var stdout: std.ArrayListUnmanaged(u8) = .{};
    var stderr: std.ArrayListUnmanaged(u8) = .{};
    try child.collectOutput(arena_alloc, &stdout, &stderr, 1024 * 1024);
    const term = try child.wait();

    switch (term) {
        .Exited => |rc| {
            if (rc != 0) {
                if (stderr.items.len > 0) {
                    log.warn("wt remove failed (rc={d}): {s}", .{ rc, stderr.items });
                }
                return error.WtRemoveFailed;
            }
        },
        else => return error.WtRemoveFailed,
    }
}

/// Check if the `wt` binary is available on this system.
pub fn isAvailable(alloc: Allocator) bool {
    const wt_bin = findWtBinary(alloc) catch return false;
    defer alloc.free(wt_bin);

    // Try running `wt --version` to see if it works
    var child = std.process.Child.init(
        &.{ wt_bin, "--version" },
        alloc,
    );
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
