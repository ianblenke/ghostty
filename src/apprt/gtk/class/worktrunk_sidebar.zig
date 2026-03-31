const std = @import("std");
const Allocator = std.mem.Allocator;

const adw = @import("adw");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const gresource = @import("../build/gresource.zig");
const Common = @import("../class.zig").Common;
const Application = @import("application.zig").Application;
const Config = @import("config.zig").Config;
const worktrunk_store = @import("../worktrunk_store.zig");
const WorktrunkStore = worktrunk_store.WorktrunkStore;
const AgentSession = worktrunk_store.AgentSession;
const hook_installer = @import("../worktrunk_hook_installer.zig");
const EventTailer = @import("../worktrunk_event_tailer.zig").EventTailer;
const github = @import("../worktrunk_github.zig");
const GitHubStatusManager = github.GitHubStatusManager;

const log = std.log.scoped(.gtk_ghostty_worktrunk_sidebar);

/// The Ghostree worktrunk sidebar widget. Provides a left panel for navigating
/// git repositories, worktrees, and AI agent sessions.
pub const WorktrunkSidebar = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = adw.Bin;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttyWorktrunkSidebar",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    pub const properties = struct {
        pub const config = struct {
            pub const name = "config";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?*Config,
                .{
                    .accessor = C.privateObjFieldAccessor("config"),
                },
            );
        };
    };

    pub const signals = struct {
        /// Emitted when the user wants to open a directory in a new tab.
        pub const @"open-directory" = struct {
            pub const name = "open-directory";
            pub const connect = impl.connect;
            pub const impl = gobject.ext.defineSignal(
                name,
                Self,
                &.{?[*:0]const u8},
                void,
            );
        };

        /// Emitted when the user wants to resume an AI session.
        /// Parameters: session-id, working-directory
        pub const @"open-session" = struct {
            pub const name = "open-session";
            pub const connect = impl.connect;
            pub const impl = gobject.ext.defineSignal(
                name,
                Self,
                &.{ ?[*:0]const u8, ?[*:0]const u8 },
                void,
            );
        };
    };

    const Private = struct {
        /// The configuration for this sidebar.
        config: ?*Config = null,

        /// The worktrunk store managing all sidebar data.
        store: ?*WorktrunkStore = null,

        /// The event tailer watching agent-events.jsonl.
        event_tailer: ?*EventTailer = null,

        /// GitHub PR status manager.
        github_mgr: ?*GitHubStatusManager = null,

        /// Whether the store has been initialized.
        store_initialized: bool = false,

        // Template bindings
        list_box: *gtk.ListBox,
        add_button: *gtk.Button,
        refresh_button: *gtk.Button,
        placeholder: *gtk.Box,
        header: *gtk.Box,

        pub var offset: c_int = 0;
    };

    fn init(self: *Self, _: *Class) callconv(.c) void {
        gtk.Widget.initTemplate(self.as(gtk.Widget));

        const priv = self.private();

        // Show the placeholder by default since we have no repos
        priv.list_box.as(gtk.Widget).setVisible(0);
        priv.placeholder.as(gtk.Widget).setVisible(1);

        // Initialize store on the next idle tick to avoid blocking init
        _ = glib.idleAdd(onInitStore, self);
    }

    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();

        if (priv.github_mgr) |mgr| {
            mgr.deinit();
            Application.default().allocator().destroy(mgr);
            priv.github_mgr = null;
        }

        if (priv.event_tailer) |tailer| {
            tailer.deinit();
            Application.default().allocator().destroy(tailer);
            priv.event_tailer = null;
        }

        if (priv.store) |store| {
            store.persist() catch |err| {
                log.warn("failed to persist store on dispose: {}", .{err});
            };
            store.deinit();
            Application.default().allocator().destroy(store);
            priv.store = null;
        }

        if (priv.config) |config| {
            config.unref();
            priv.config = null;
        }

        gtk.Widget.disposeTemplate(
            self.as(gtk.Widget),
            getGObjectType(),
        );

        gobject.Object.virtual_methods.dispose.call(
            Class.parent,
            self.as(Parent),
        );
    }

    //---------------------------------------------------------------
    // Store Management

    fn onInitStore(ud: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(ud orelse return 0));
        const priv = self.private();

        if (priv.store_initialized) return 0;
        priv.store_initialized = true;

        const alloc = Application.default().allocator();
        const store = alloc.create(WorktrunkStore) catch {
            log.warn("failed to create worktrunk store", .{});
            return 0;
        };
        store.* = WorktrunkStore.init(alloc);
        priv.store = store;

        // Load persisted repos
        store.load() catch |err| {
            log.warn("failed to load persisted repos: {}", .{err});
        };

        // Refresh worktrees for all repos
        store.refreshAll();

        // Scan for Claude sessions
        store.scanClaudeSessions() catch |err| {
            log.warn("failed to scan claude sessions: {}", .{err});
        };

        // Install agent hooks
        hook_installer.install(alloc) catch |err| {
            log.warn("failed to install agent hooks: {}", .{err});
        };

        // Start event tailer
        const tailer = alloc.create(EventTailer) catch {
            log.warn("failed to create event tailer", .{});
            self.rebuildList();
            return 0;
        };
        tailer.* = EventTailer.init(alloc, store) catch {
            log.warn("failed to init event tailer", .{});
            alloc.destroy(tailer);
            self.rebuildList();
            return 0;
        };
        tailer.start();
        priv.event_tailer = tailer;

        // Start GitHub PR status manager
        const gh_mgr = alloc.create(GitHubStatusManager) catch {
            self.rebuildList();
            return 0;
        };
        gh_mgr.* = GitHubStatusManager.init(alloc);
        gh_mgr.setQueries(store.repositories.items);
        gh_mgr.start();
        priv.github_mgr = gh_mgr;

        self.rebuildList();
        return 0; // Don't repeat
    }

    /// Rebuild the ListBox contents from the store data.
    fn rebuildList(self: *Self) void {
        const priv = self.private();
        const store = priv.store orelse return;
        const list_box = priv.list_box;

        // Remove all existing rows
        while (list_box.as(gtk.Widget).getFirstChild()) |child| {
            list_box.remove(child);
        }

        const has_items = store.repositories.items.len > 0;
        list_box.as(gtk.Widget).setVisible(@intFromBool(has_items));
        priv.placeholder.as(gtk.Widget).setVisible(@intFromBool(!has_items));

        for (store.repositories.items, 0..) |repo, repo_idx| {
            // Add repo header row
            const repo_row = self.createRepoRow(repo.name, repo_idx);
            list_box.append(repo_row.as(gtk.Widget));

            if (repo.expanded) {
                for (repo.worktrees.items, 0..) |wt, wt_idx| {
                    // Add worktree row
                    const wt_row = self.createWorktreeRow(wt.branch, wt.path, wt.is_main, repo.path, repo_idx, wt_idx);
                    list_box.append(wt_row.as(gtk.Widget));

                    // Add session rows
                    for (wt.sessions.items) |session| {
                        const session_row = self.createSessionRow(session);
                        list_box.append(session_row.as(gtk.Widget));
                    }
                }
            }
        }
    }

    fn createRepoRow(_: *Self, name: []const u8, repo_idx: usize) *gtk.ListBoxRow {
        const box = gtk.Box.new(.horizontal, 8);
        box.as(gtk.Widget).setMarginStart(4);
        box.as(gtk.Widget).setMarginEnd(4);
        box.as(gtk.Widget).setMarginTop(4);
        box.as(gtk.Widget).setMarginBottom(4);

        // Folder icon
        const icon = gtk.Image.newFromIconName("folder-symbolic");
        box.append(icon.as(gtk.Widget));

        // Repo name label
        const name_z = glib.ext.dupeZ(u8, name);
        const label = gtk.Label.new(name_z);
        label.setXalign(0);
        label.as(gtk.Widget).setHexpand(1);
        label.as(gtk.Widget).addCssClass("heading");
        box.append(label.as(gtk.Widget));

        const row = gtk.ListBoxRow.new();
        row.setChild(box.as(gtk.Widget));

        // Store indices in the row name for later retrieval
        var name_buf: [64]u8 = undefined;
        const row_name = std.fmt.bufPrintZ(&name_buf, "repo:{d}", .{repo_idx}) catch "repo:0";
        row.as(gtk.Widget).setName(row_name);

        return row;
    }

    fn createWorktreeRow(self: *Self, branch: []const u8, _: []const u8, is_main: bool, repo_path: []const u8, repo_idx: usize, wt_idx: usize) *gtk.ListBoxRow {
        const box = gtk.Box.new(.horizontal, 8);
        box.as(gtk.Widget).setMarginStart(20);
        box.as(gtk.Widget).setMarginEnd(4);
        box.as(gtk.Widget).setMarginTop(2);
        box.as(gtk.Widget).setMarginBottom(2);

        // Branch icon
        const icon_name: [*:0]const u8 = if (is_main) "starred-symbolic" else "media-record-symbolic";
        const icon = gtk.Image.newFromIconName(icon_name);
        box.append(icon.as(gtk.Widget));

        // Branch name label
        const branch_z = glib.ext.dupeZ(u8, branch);
        const label = gtk.Label.new(branch_z);
        label.setXalign(0);
        label.as(gtk.Widget).setHexpand(1);
        box.append(label.as(gtk.Widget));

        // PR status indicator
        const priv = self.private();
        if (priv.github_mgr) |gh_mgr| {
            const pr_status = gh_mgr.getStatus(repo_path, branch);
            if (pr_status.state != .none) {
                // CI status dot
                const ci_dot = gtk.Box.new(.horizontal, 0);
                ci_dot.as(gtk.Widget).addCssClass("ci-indicator");
                ci_dot.as(gtk.Widget).addCssClass(switch (pr_status.ci) {
                    .none => "ci-none",
                    .pending => "ci-pending",
                    .passing => "ci-passing",
                    .failing => "ci-failing",
                });
                box.append(ci_dot.as(gtk.Widget));

                // PR state label
                const pr_label_text: [*:0]const u8 = switch (pr_status.state) {
                    .none => "",
                    .open => "PR",
                    .draft => "Draft",
                    .merged => "Merged",
                    .closed => "Closed",
                };
                if (pr_status.state != .none) {
                    const pr_label = gtk.Label.new(pr_label_text);
                    pr_label.as(gtk.Widget).addCssClass("pr-badge");
                    pr_label.as(gtk.Widget).addCssClass(switch (pr_status.state) {
                        .none => "pr-none",
                        .open => "pr-open",
                        .draft => "pr-draft",
                        .merged => "pr-merged",
                        .closed => "pr-closed",
                    });
                    box.append(pr_label.as(gtk.Widget));
                }
            }
        }

        const row = gtk.ListBoxRow.new();
        row.setChild(box.as(gtk.Widget));

        var name_buf: [64]u8 = undefined;
        const row_name = std.fmt.bufPrintZ(&name_buf, "wt:{d}:{d}", .{ repo_idx, wt_idx }) catch "wt:0:0";
        row.as(gtk.Widget).setName(row_name);

        return row;
    }

    fn createSessionRow(_: *Self, session: AgentSession) *gtk.ListBoxRow {
        const box = gtk.Box.new(.horizontal, 8);
        box.as(gtk.Widget).setMarginStart(36);
        box.as(gtk.Widget).setMarginEnd(4);
        box.as(gtk.Widget).setMarginTop(1);
        box.as(gtk.Widget).setMarginBottom(1);

        // Status indicator dot
        const status_dot = gtk.Box.new(.horizontal, 0);
        status_dot.as(gtk.Widget).addCssClass("status-indicator");
        status_dot.as(gtk.Widget).addCssClass(switch (session.status) {
            .idle => "idle",
            .working => "working",
            .permission => "permission",
            .review => "review",
        });
        box.append(status_dot.as(gtk.Widget));

        // Agent icon
        const icon = gtk.Image.newFromIconName("utilities-terminal-symbolic");
        box.append(icon.as(gtk.Widget));

        // Session label
        const display = session.source.displayName();
        const display_z = glib.ext.dupeZ(u8, display);
        const label = gtk.Label.new(display_z);
        label.setXalign(0);
        label.as(gtk.Widget).setHexpand(1);
        label.as(gtk.Widget).addCssClass("dim-label");
        label.as(gtk.Widget).addCssClass("caption");
        box.append(label.as(gtk.Widget));

        // Message count
        var count_buf: [32]u8 = undefined;
        const count_str = std.fmt.bufPrintZ(&count_buf, "{d} msgs", .{session.message_count}) catch "0 msgs";
        const count_label = gtk.Label.new(count_str);
        count_label.as(gtk.Widget).addCssClass("dim-label");
        count_label.as(gtk.Widget).addCssClass("caption");
        box.append(count_label.as(gtk.Widget));

        const row = gtk.ListBoxRow.new();
        row.setChild(box.as(gtk.Widget));

        // Store session info in row name: "session:<id>:<worktree_path>"
        const alloc = Application.default().allocator();
        const row_name = std.fmt.allocPrintSentinel(alloc, "session:{s}:{s}", .{ session.id, session.worktree_path }, 0) catch "session:unknown:unknown";
        row.as(gtk.Widget).setName(row_name);

        return row;
    }

    //---------------------------------------------------------------
    // Template Callbacks

    fn addRepository(
        _: *gtk.Button,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();
        const store = priv.store orelse return;
        const alloc = Application.default().allocator();

        // Get the current working directory as a default
        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        const cwd = std.posix.getcwd(&cwd_buf) catch "/";

        // Try to detect if cwd is a git repo by checking for .git
        var git_root = detectGitRoot(cwd) orelse cwd;
        _ = &git_root;

        _ = store.addRepository(cwd) catch |err| switch (err) {
            error.AlreadyExists => {
                log.info("repository already added: {s}", .{cwd});
                return;
            },
            else => {
                log.warn("failed to add repository: {}", .{err});
                return;
            },
        };

        const repo_idx = store.repositories.items.len - 1;
        store.refreshWorktrees(repo_idx) catch |err| {
            log.warn("failed to refresh worktrees: {}", .{err});
        };

        store.scanClaudeSessions() catch |err| {
            log.warn("failed to scan sessions: {}", .{err});
        };

        store.persist() catch |err| {
            log.warn("failed to persist: {}", .{err});
        };

        self.rebuildList();
        _ = alloc;
    }

    fn refresh(
        _: *gtk.Button,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();
        const store = priv.store orelse return;

        store.refreshAll();
        store.scanClaudeSessions() catch |err| {
            log.warn("failed to scan sessions on refresh: {}", .{err});
        };

        self.rebuildList();
    }

    fn rowActivated(
        _: *gtk.ListBox,
        row: *gtk.ListBoxRow,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();
        const store = priv.store orelse return;

        const name = row.as(gtk.Widget).getName();
        const name_slice = std.mem.span(name);

        // Parse the row name to determine what was clicked
        if (std.mem.startsWith(u8, name_slice, "repo:")) {
            // Toggle repo expansion
            const idx_str = name_slice["repo:".len..];
            const repo_idx = std.fmt.parseInt(usize, idx_str, 10) catch return;
            if (repo_idx >= store.repositories.items.len) return;
            store.repositories.items[repo_idx].expanded = !store.repositories.items[repo_idx].expanded;
            self.rebuildList();
        } else if (std.mem.startsWith(u8, name_slice, "wt:")) {
            // Open worktree directory
            const rest = name_slice["wt:".len..];
            var iter = std.mem.splitScalar(u8, rest, ':');
            const repo_idx_str = iter.next() orelse return;
            const wt_idx_str = iter.next() orelse return;
            const repo_idx = std.fmt.parseInt(usize, repo_idx_str, 10) catch return;
            const wt_idx = std.fmt.parseInt(usize, wt_idx_str, 10) catch return;

            if (repo_idx >= store.repositories.items.len) return;
            const repo = &store.repositories.items[repo_idx];
            if (wt_idx >= repo.worktrees.items.len) return;
            const wt = &repo.worktrees.items[wt_idx];

            // Emit open-directory signal
            const path_z = glib.ext.dupeZ(u8, wt.path);
            signals.@"open-directory".impl.emit(self, null, .{path_z}, null);
        } else if (std.mem.startsWith(u8, name_slice, "session:")) {
            // Resume AI session
            const rest = name_slice["session:".len..];
            // Format: session:<id>:<worktree_path>
            const first_colon = std.mem.indexOf(u8, rest, ":") orelse return;
            const session_id = rest[0..first_colon];
            const wt_path = rest[first_colon + 1 ..];

            const id_z = glib.ext.dupeZ(u8, session_id);
            const path_z = glib.ext.dupeZ(u8, wt_path);
            signals.@"open-session".impl.emit(self, null, .{ id_z, path_z }, null);
        }
    }

    //---------------------------------------------------------------
    // Helpers

    fn detectGitRoot(path: []const u8) ?[]const u8 {
        var current = path;
        while (true) {
            var git_path_buf: [std.fs.max_path_bytes]u8 = undefined;
            const git_path = std.fmt.bufPrint(&git_path_buf, "{s}/.git", .{current}) catch return null;
            std.fs.accessAbsolute(git_path, .{}) catch {
                // Go up one directory
                const parent = std.fs.path.dirname(current) orelse return null;
                if (std.mem.eql(u8, parent, current)) return null;
                current = parent;
                continue;
            };
            return current;
        }
    }

    //---------------------------------------------------------------
    // Common and Class

    const C = Common(Self, Private);
    pub const as = C.as;
    pub const ref = C.ref;
    pub const refSink = C.refSink;
    pub const unref = C.unref;
    const private = C.private;

    pub const Class = extern struct {
        parent_class: Parent.Class,
        var parent: *Parent.Class = undefined;
        pub const Instance = Self;

        fn init(class: *Class) callconv(.c) void {
            gtk.Widget.Class.setTemplateFromResource(
                class.as(gtk.Widget.Class),
                comptime gresource.blueprint(.{
                    .major = 1,
                    .minor = 5,
                    .name = "worktrunk-sidebar",
                }),
            );

            // Bindings
            class.bindTemplateChildPrivate("list_box", .{});
            class.bindTemplateChildPrivate("add_button", .{});
            class.bindTemplateChildPrivate("refresh_button", .{});
            class.bindTemplateChildPrivate("placeholder", .{});
            class.bindTemplateChildPrivate("header", .{});

            // Template Callbacks
            class.bindTemplateCallback("add_repository", &addRepository);
            class.bindTemplateCallback("refresh", &refresh);
            class.bindTemplateCallback("row_activated", &rowActivated);

            // Properties
            gobject.ext.registerProperties(class, &.{
                properties.config.impl,
            });

            // Signals
            signals.@"open-directory".impl.register(.{});
            signals.@"open-session".impl.register(.{});

            // Virtual methods
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
        }

        pub const as = C.Class.as;
        pub const bindTemplateChildPrivate = C.Class.bindTemplateChildPrivate;
        pub const bindTemplateCallback = C.Class.bindTemplateCallback;
    };
};
