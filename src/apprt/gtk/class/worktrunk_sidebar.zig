const std = @import("std");
const Allocator = std.mem.Allocator;

const adw = @import("adw");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const gio = @import("gio");
const gresource = @import("../build/gresource.zig");
const ext = @import("../ext.zig");
const Common = @import("../class.zig").Common;
const Application = @import("application.zig").Application;
const Window = @import("window.zig").Window;
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

        /// View mode: nested by repo (default) or flat worktrees.
        flat_view: bool = false,

        /// Whether the store has been initialized.
        store_initialized: bool = false,

        // Template bindings
        list_box: *gtk.ListBox,
        add_button: *gtk.Button,
        refresh_button: *gtk.Button,
        search_entry: *gtk.SearchEntry,
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

        // Register sidebar actions for the options menu
        self.initActionMap();

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
        tailer.on_status_change = &onAgentStatusChange;
        tailer.on_status_change_data = self;
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
    /// Called by the event tailer when agent session status changes.
    fn onAgentStatusChange(ud: ?*anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ud orelse return));
        self.rebuildList();
    }

    /// Called by the Window when tabs are attached/detached to refresh the active tabs section.
    pub fn refreshTabs(self: *Self) void {
        self.rebuildList();
    }

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

        // Active Tabs section
        if (ext.getAncestor(Window, self.as(gtk.Widget))) |window| {
            const tab_view = window.getTabView();
            const n_pages = tab_view.getNPages();
            if (n_pages > 0) {
                // Section header
                const tabs_header = self.createSectionHeader("Active Tabs");
                list_box.append(tabs_header.as(gtk.Widget));

                var i: c_int = 0;
                while (i < n_pages) : (i += 1) {
                    const page = tab_view.getNthPage(i);
                    const title = page.getTitle();
                    const tab_row = self.createTabRow(std.mem.span(title), i);
                    list_box.append(tab_row.as(gtk.Widget));
                }
            }
        }

        if (priv.flat_view) {
            // Flat view: show all worktrees without repo grouping
            const wt_header = self.createSectionHeader("Worktrees");
            list_box.append(wt_header.as(gtk.Widget));

            for (store.repositories.items, 0..) |repo, repo_idx| {
                for (repo.worktrees.items, 0..) |wt, wt_idx| {
                    const wt_row = self.createWorktreeRow(wt.branch, wt.path, wt.is_main, repo.path, repo_idx, wt_idx);
                    list_box.append(wt_row.as(gtk.Widget));

                    for (wt.sessions.items) |session| {
                        const session_row = self.createSessionRow(session);
                        list_box.append(session_row.as(gtk.Widget));
                    }
                }
            }
        } else {
            // Nested view: group worktrees under repos
            for (store.repositories.items, 0..) |repo, repo_idx| {
                const repo_row = self.createRepoRow(repo.name, repo_idx);
                list_box.append(repo_row.as(gtk.Widget));

                if (repo.expanded) {
                    for (repo.worktrees.items, 0..) |wt, wt_idx| {
                        const wt_row = self.createWorktreeRow(wt.branch, wt.path, wt.is_main, repo.path, repo_idx, wt_idx);
                        list_box.append(wt_row.as(gtk.Widget));

                        for (wt.sessions.items) |session| {
                            const session_row = self.createSessionRow(session);
                            list_box.append(session_row.as(gtk.Widget));
                        }
                    }
                }
            }
        }
    }

    fn createRepoRow(self: *Self, name: []const u8, repo_idx: usize) *gtk.ListBoxRow {
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

        // Worktree count badge
        const alloc = Application.default().allocator();
        const store_ptr = self.private().store;
        if (store_ptr) |store| {
            if (repo_idx < store.repositories.items.len) {
                const wt_count = store.repositories.items[repo_idx].worktrees.items.len;
                if (wt_count > 0) {
                    var count_buf: [16]u8 = undefined;
                    const count_str = std.fmt.bufPrintZ(&count_buf, "{d}", .{wt_count}) catch "0";
                    const badge = gtk.Label.new(count_str);
                    badge.as(gtk.Widget).addCssClass("dim-label");
                    badge.as(gtk.Widget).addCssClass("caption");
                    box.append(badge.as(gtk.Widget));
                }
            }
        }
        _ = alloc;

        const row = gtk.ListBoxRow.new();
        row.setChild(box.as(gtk.Widget));

        // Store indices in the row name for later retrieval
        var name_buf: [64]u8 = undefined;
        const row_name = std.fmt.bufPrintZ(&name_buf, "repo:{d}", .{repo_idx}) catch "repo:0";
        row.as(gtk.Widget).setName(row_name);

        return row;
    }

    fn createWorktreeRow(self: *Self, branch: []const u8, wt_path: []const u8, is_main: bool, repo_path: []const u8, repo_idx: usize, wt_idx: usize) *gtk.ListBoxRow {
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

        // Set tooltip to full worktree path
        const path_z = glib.ext.dupeZ(u8, wt_path);
        row.as(gtk.Widget).setTooltipText(path_z);

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

        // Session info (vertical: agent name + snippet)
        const info_box = gtk.Box.new(.vertical, 1);
        info_box.as(gtk.Widget).setHexpand(1);

        // Agent name + message count
        const alloc_tmp = Application.default().allocator();
        var header_buf: [128]u8 = undefined;
        const header_str = std.fmt.bufPrintZ(&header_buf, "{s} · {d} msgs", .{ session.source.displayName(), session.message_count }) catch "Session";
        const header_label = gtk.Label.new(header_str);
        header_label.setXalign(0);
        header_label.as(gtk.Widget).addCssClass("caption");
        info_box.append(header_label.as(gtk.Widget));

        // Snippet preview (if available)
        if (session.snippet) |snip| {
            const snippet_z = glib.ext.dupeZ(u8, snip);
            const snippet_label = gtk.Label.new(snippet_z);
            snippet_label.setXalign(0);
            snippet_label.as(gtk.Widget).addCssClass("dim-label");
            snippet_label.as(gtk.Widget).addCssClass("caption");
            info_box.append(snippet_label.as(gtk.Widget));
        }
        _ = alloc_tmp;

        box.append(info_box.as(gtk.Widget));

        const row = gtk.ListBoxRow.new();
        row.setChild(box.as(gtk.Widget));

        // Tooltip: agent type + cwd + session ID
        const alloc = Application.default().allocator();
        const tooltip = std.fmt.allocPrintSentinel(alloc, "{s} session in {s}", .{ session.source.displayName(), session.cwd }, 0) catch null;
        if (tooltip) |t| row.as(gtk.Widget).setTooltipText(t);

        // Store session info in row name: "session:<id>:<worktree_path>"
        const row_name = std.fmt.allocPrintSentinel(alloc, "session:{s}:{s}", .{ session.id, session.worktree_path }, 0) catch "session:unknown:unknown";
        row.as(gtk.Widget).setName(row_name);

        return row;
    }

    fn createSectionHeader(_: *Self, title: []const u8) *gtk.ListBoxRow {
        const label_z = glib.ext.dupeZ(u8, title);
        const label = gtk.Label.new(label_z);
        label.setXalign(0);
        label.as(gtk.Widget).setMarginStart(8);
        label.as(gtk.Widget).setMarginTop(8);
        label.as(gtk.Widget).setMarginBottom(2);
        label.as(gtk.Widget).addCssClass("dim-label");
        label.as(gtk.Widget).addCssClass("caption");

        const row = gtk.ListBoxRow.new();
        row.setChild(label.as(gtk.Widget));
        row.setActivatable(0);
        row.setSelectable(0);
        row.as(gtk.Widget).setName("section-header");
        return row;
    }

    fn createTabRow(_: *Self, title: []const u8, tab_index: c_int) *gtk.ListBoxRow {
        const box = gtk.Box.new(.horizontal, 8);
        box.as(gtk.Widget).setMarginStart(8);
        box.as(gtk.Widget).setMarginEnd(4);
        box.as(gtk.Widget).setMarginTop(2);
        box.as(gtk.Widget).setMarginBottom(2);

        const icon = gtk.Image.newFromIconName("tab-new-symbolic");
        box.append(icon.as(gtk.Widget));

        const display = if (title.len > 0) title else "Terminal";
        const title_z = glib.ext.dupeZ(u8, display);
        const label = gtk.Label.new(title_z);
        label.setXalign(0);
        label.as(gtk.Widget).setHexpand(1);
        box.append(label.as(gtk.Widget));

        const row = gtk.ListBoxRow.new();
        row.setChild(box.as(gtk.Widget));

        var name_buf: [32]u8 = undefined;
        const row_name = std.fmt.bufPrintZ(&name_buf, "tab:{d}", .{tab_index}) catch "tab:0";
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

        // Get the current working directory and walk up to find git root
        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        const cwd = std.posix.getcwd(&cwd_buf) catch "/";
        const repo_path = detectGitRoot(cwd) orelse cwd;

        _ = store.addRepository(repo_path) catch |err| switch (err) {
            error.AlreadyExists => {
                log.info("repository already added: {s}", .{repo_path});
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

    fn searchChanged(
        search_entry: *gtk.SearchEntry,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();
        const text = search_entry.as(gtk.Editable).getText();
        const filter_text = std.mem.span(text);

        if (filter_text.len == 0) {
            // Clear filter — show all rows
            priv.list_box.setFilterFunc(null, null, null);
        } else {
            // Apply filter
            priv.list_box.setFilterFunc(&filterRow, self, null);
        }
        priv.list_box.invalidateFilter();
    }

    fn filterRow(row: *gtk.ListBoxRow, ud: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(ud orelse return 1));
        const priv = self.private();

        // Get filter text
        const text = priv.search_entry.as(gtk.Editable).getText();
        const filter_text = std.mem.span(text);
        if (filter_text.len == 0) return 1;

        // Always show section headers
        const name = row.as(gtk.Widget).getName();
        const name_slice = std.mem.span(name);
        if (std.mem.eql(u8, name_slice, "section-header")) return 1;

        // Get the row's child widget tree and check if any label contains the filter text
        // Simple approach: check the row name which contains identifiers
        if (containsCaseInsensitive(name_slice, filter_text)) return 1;

        // Also check visible label text by looking at the child widget
        if (row.getChild()) |child| {
            if (checkWidgetForText(child, filter_text)) return 1;
        }

        return 0; // hide
    }

    fn checkWidgetForText(widget: *gtk.Widget, filter: []const u8) bool {
        // Check if this widget is a Label
        if (gobject.ext.cast(gtk.Label, widget)) |label| {
            const label_text = std.mem.span(label.getText());
            if (containsCaseInsensitive(label_text, filter)) return true;
        }

        // Check if this widget is a Box and recurse into children
        var child = widget.getFirstChild();
        while (child) |c| {
            if (checkWidgetForText(c, filter)) return true;
            child = c.getNextSibling();
        }
        return false;
    }

    fn containsCaseInsensitive(haystack: []const u8, needle: []const u8) bool {
        if (needle.len == 0) return true;
        if (haystack.len < needle.len) return false;
        var i: usize = 0;
        while (i <= haystack.len - needle.len) : (i += 1) {
            var match = true;
            for (0..needle.len) |j| {
                if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(needle[j])) {
                    match = false;
                    break;
                }
            }
            if (match) return true;
        }
        return false;
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
        } else if (std.mem.startsWith(u8, name_slice, "tab:")) {
            // Switch to the clicked tab
            const idx_str = name_slice["tab:".len..];
            const tab_idx = std.fmt.parseInt(c_int, idx_str, 10) catch return;
            if (ext.getAncestor(Window, self.as(gtk.Widget))) |window| {
                const tab_view = window.getTabView();
                const page = tab_view.getNthPage(tab_idx);
                tab_view.setSelectedPage(page);
            }
        }
    }

    //---------------------------------------------------------------
    // Action Map

    fn initActionMap(self: *Self) void {
        const actions = [_]ext.actions.Action(Self){
            .init("sort-alpha", actionSortAlpha, null),
            .init("sort-recent", actionSortRecent, null),
            .init("toggle-flat", actionToggleFlat, null),
            .init("remove-all", actionRemoveAll, null),
        };

        _ = ext.actions.addAsGroup(Self, self, "sidebar", &actions);
    }

    fn actionSortAlpha(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();
        const store = priv.store orelse return;

        // Sort worktrees alphabetically within each repo
        for (store.repositories.items) |*repo| {
            std.mem.sort(worktrunk_store.Worktree, repo.worktrees.items, {}, struct {
                fn lessThan(_: void, a: worktrunk_store.Worktree, b: worktrunk_store.Worktree) bool {
                    return std.mem.order(u8, a.branch, b.branch) == .lt;
                }
            }.lessThan);
        }
        self.rebuildList();
    }

    fn actionSortRecent(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();
        const store = priv.store orelse return;

        // Sort worktrees with main pinned first, then by session recency
        for (store.repositories.items) |*repo| {
            std.mem.sort(worktrunk_store.Worktree, repo.worktrees.items, {}, struct {
                fn lessThan(_: void, a: worktrunk_store.Worktree, b: worktrunk_store.Worktree) bool {
                    // Main always first
                    if (a.is_main and !b.is_main) return true;
                    if (!a.is_main and b.is_main) return false;
                    // Current second
                    if (a.is_current and !b.is_current) return true;
                    if (!a.is_current and b.is_current) return false;
                    // Then by most recent session
                    const a_ts = if (a.sessions.items.len > 0) a.sessions.items[a.sessions.items.len - 1].timestamp else 0;
                    const b_ts = if (b.sessions.items.len > 0) b.sessions.items[b.sessions.items.len - 1].timestamp else 0;
                    return a_ts > b_ts;
                }
            }.lessThan);
        }
        self.rebuildList();
    }

    fn actionToggleFlat(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();
        priv.flat_view = !priv.flat_view;
        self.rebuildList();
    }

    fn actionRemoveAll(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();
        const store = priv.store orelse return;

        // Remove all repos
        while (store.repositories.items.len > 0) {
            store.removeRepository(0);
        }
        store.persist() catch {};
        self.rebuildList();
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
            class.bindTemplateChildPrivate("search_entry", .{});
            class.bindTemplateChildPrivate("placeholder", .{});
            class.bindTemplateChildPrivate("header", .{});

            // Template Callbacks
            class.bindTemplateCallback("add_repository", &addRepository);
            class.bindTemplateCallback("refresh", &refresh);
            class.bindTemplateCallback("row_activated", &rowActivated);
            class.bindTemplateCallback("search_changed", &searchChanged);

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
