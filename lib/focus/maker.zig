const focus = @import("../focus.zig");
usingnamespace focus.common;
const App = focus.App;
const Buffer = focus.Buffer;
const Editor = focus.Editor;
const Window = focus.Window;
const style = focus.style;
const SingleLineEditor = focus.SingleLineEditor;
const Selector = focus.Selector;

pub const Maker = struct {
    app: *App,
    input: SingleLineEditor,
    selector: Selector,
    result_editor: *Editor,
    history_string: []const u8,
    history: []const []const u8,
    state: union(enum) {
        ChoosingDir,
        ChoosingCommand: struct {
            dirname: []const u8,
        },
        Running: struct {
            dirname: []const u8,
            command: []const u8,
            child_process: *std.ChildProcess,
        },
        Finished: struct {
            dirname: []const u8,
            command: []const u8,
            error_locations: []const ErrorLocation,

            const Self = @This();
            fn deinit(self: Self, allocator: *Allocator) void {
                for (self.error_locations) |error_location|
                    error_location.deinit(allocator);
                allocator.free(self.command);
                allocator.free(self.dirname);
            }
        },
    },

    pub const ErrorLocation = struct {
        source_location: [2]usize,
        path: []const u8,
        line: usize,
        col: usize,

        fn deinit(self: ErrorLocation, allocator: *Allocator) void {
            allocator.free(self.path);
        }
    };

    pub fn init(app: *App) *Maker {
        const empty_buffer = Buffer.initEmpty(app, .Real);
        const result_editor = Editor.init(app, empty_buffer, false, false);
        const input = SingleLineEditor.init(app, "/home/jamie/");
        const selector = Selector.init(app);
        const history_file = std.fs.cwd().openFile("/home/jamie/.bash_history", .{}) catch |err|
            panic("Failed to open bash history: {}", .{err});
        const history_string = history_file.reader().readAllAlloc(app.allocator, std.math.maxInt(usize)) catch |err|
            panic("Failed to read bash history: {}", .{err});
        var history_lines = std.mem.split(history_string, "\n");
        var history = ArrayList([]const u8).init(app.allocator);
        while (history_lines.next()) |line|
            if (line.len != 0)
                history.append(line) catch oom();
        std.mem.reverse([]const u8, history.items);
        const self = app.allocator.create(Maker) catch oom();
        self.* = Maker{
            .app = app,
            .input = input,
            .selector = selector,
            .result_editor = result_editor,
            .history_string = history_string,
            .history = history.toOwnedSlice(),
            .state = .ChoosingDir,
        };
        return self;
    }

    pub fn deinit(self: *Maker) void {
        switch (self.state) {
            .ChoosingDir => return,
            .ChoosingCommand => |choosing_command| {
                self.app.allocator.free(choosing_command.dirname);
            },
            .Running => |running| {
                running.child_process.stdout.?.close();
                running.child_process.stderr.?.close();
                running.child_process.deinit();
                self.app.allocator.free(running.command);
                self.app.allocator.free(running.dirname);
            },
            .Finished => |finished| finished.deinit(self.app.allocator),
        }
        self.app.allocator.free(self.history_string);
        self.selector.deinit();
        self.input.deinit();
        const buffer = self.result_editor.buffer;
        self.result_editor.deinit();
        buffer.deinit();
        self.app.allocator.destroy(self);
    }

    pub fn frame(self: *Maker, window: *Window, rect: Rect, events: []const c.SDL_Event) void {
        switch (self.state) {
            .ChoosingDir => {
                const layout = window.layoutSearcher(rect);

                // run input frame
                const input_changed = self.input.frame(window, layout.input, events);
                if (input_changed == .Changed) self.selector.selected = 0;

                // get and filter completions
                const results_or_err = fuzzy_search_paths(self.app.frame_allocator, self.input.getText());
                const results = results_or_err catch &[_][]const u8{};

                // run selector frame
                var action: Selector.Action = .None;
                if (results_or_err) |_| {
                    action = self.selector.frame(window, layout.selector, events, results);
                } else |results_err| {
                    const error_text = format(self.app.frame_allocator, "Error opening directory: {}", .{results_err});
                    window.queueText(layout.selector, style.error_text_color, error_text);
                }

                const path = self.input.getText();
                const dirname = if (path.len > 0 and std.fs.path.isSep(path[path.len - 1]))
                    path[0 .. path.len - 1]
                else
                    std.fs.path.dirname(path) orelse "";

                // maybe pick dir
                if (action == .SelectRaw or action == .SelectOne) {
                    const chosen_dirname: []const u8 = if (action == .SelectRaw)
                        self.input.getText()
                    else
                        std.fs.path.join(self.app.frame_allocator, &[_][]const u8{ dirname, results[self.selector.selected] }) catch oom();
                    if (chosen_dirname.len > 0 and std.fs.path.isSep(chosen_dirname[chosen_dirname.len - 1])) {
                        self.input.buffer.replace("");
                        self.state = .{ .ChoosingCommand = .{
                            .dirname = self.app.dupe(chosen_dirname),
                        } };
                    }
                }
            },
            .ChoosingCommand => |choosing_command| {
                const layout = window.layoutSearcher(rect);

                // run input frame
                const input_changed = self.input.frame(window, layout.input, events);
                if (input_changed == .Changed) self.selector.selected = 0;

                // filter lines
                const filtered_history = fuzzy_search(self.app.frame_allocator, self.history, self.input.getText());

                // run selector frame
                var action: Selector.Action = .None;
                action = self.selector.frame(window, layout.selector, events, filtered_history);

                // maybe run command
                var command_o: ?[]const u8 = null;
                if (action == .SelectOne and filtered_history.len > 0) {
                    command_o = self.app.dupe(filtered_history[self.selector.selected]);
                }
                if (action == .SelectRaw) {
                    command_o = self.app.dupe(self.input.getText());
                }

                if (command_o) |command| {
                    // add command to history
                    const history_file = std.fs.cwd().openFile("/home/jamie/.bash_history", .{ .write = true }) catch |err|
                        panic("Failed to open bash history: {}", .{err});
                    history_file.seekFromEnd(0) catch |err|
                        panic("Failed to seek to end of bash history: {}", .{err});
                    std.fmt.format(history_file.writer(), "{s}\n", .{command}) catch |err|
                        panic("Failed to write to bash history: {}", .{err});

                    // start running
                    self.state = .{ .Running = .{
                        .dirname = choosing_command.dirname,
                        .command = command,
                        .child_process = spawn(self.app.allocator, choosing_command.dirname, command),
                    } };
                }
            },
            .Running => |running| {
                // check if we've finished running yet
                const wait = std.os.waitpid(running.child_process.pid, std.os.linux.WNOHANG);
                if (wait.pid == running.child_process.pid) {
                    // finished, read results
                    for (&[_]std.fs.File{ running.child_process.stdout.?, running.child_process.stderr.? }) |file| {
                        const contents = file.reader().readAllAlloc(self.app.frame_allocator, std.math.maxInt(usize)) catch |err|
                            panic("{} while reading from command: {s}", .{ err, running.command });
                        file.close();
                        self.result_editor.buffer.insert(self.result_editor.buffer.bytes.items.len, contents);
                    }
                    running.child_process.deinit();

                    // parse results
                    var error_locations = ArrayList(ErrorLocation).init(self.app.allocator);
                    defer error_locations.deinit();
                    const text = self.result_editor.buffer.bytes.items;
                    for (regex_search(
                        self.app.frame_allocator,
                        text,
                        \\([\S^:]+):(\d+):(\d+)
                        ,
                    )) |match| {
                        const path = text[match.captures[0][0]..match.captures[0][1]];
                        const line = std.fmt.parseInt(
                            usize,
                            text[match.captures[1][0]..match.captures[1][1]],
                            10,
                        ) catch continue;
                        const col = std.fmt.parseInt(
                            usize,
                            text[match.captures[2][0]..match.captures[2][1]],
                            10,
                        ) catch continue;
                        const full_path = if (std.fs.path.isAbsolute(path))
                            self.app.dupe(path)
                        else
                            std.fs.path.join(self.app.allocator, &.{
                                running.dirname,
                                path,
                            }) catch oom();
                        error_locations.append(.{
                            .source_location = match.matched,
                            .path = full_path,
                            .line = line,
                            .col = col,
                        }) catch oom();
                    }

                    self.state = .{ .Finished = .{
                        .dirname = running.dirname,
                        .command = running.command,
                        .error_locations = error_locations.toOwnedSlice(),
                    } };
                }

                // show results in editor
                self.result_editor.frame(window, rect, events);
            },
            .Finished => {
                // show results in editor
                self.result_editor.frame(window, rect, events);
            },
        }
    }

    pub fn handleAfterSave(self: *Maker) void {
        switch (self.state) {
            .ChoosingDir, .ChoosingCommand => return,
            .Running => |running| {
                running.child_process.stdout.?.close();
                running.child_process.stderr.?.close();
                running.child_process.deinit();
                self.result_editor.buffer.replace("");
                self.state = .{ .Running = .{
                    .dirname = running.dirname,
                    .command = running.command,
                    .child_process = spawn(self.app.allocator, running.dirname, running.command),
                } };
            },
            .Finished => |finished| {
                self.result_editor.buffer.replace("");
                for (finished.error_locations) |error_location|
                    error_location.deinit(self.app.allocator);
                self.state = .{ .Running = .{
                    .dirname = finished.dirname,
                    .command = finished.command,
                    .child_process = spawn(self.app.allocator, finished.dirname, finished.command),
                } };
            },
        }
    }
};

fn spawn(allocator: *Allocator, dirname: []const u8, command: []const u8) *std.ChildProcess {
    var child_process = std.ChildProcess.init(
        &.{ "bash", "-c", command },
        allocator,
    ) catch |err|
        panic("{} while running command: {s}", .{ err, command });
    child_process.stdin_behavior = .Ignore;
    child_process.stdout_behavior = .Pipe;
    child_process.stderr_behavior = .Pipe;
    child_process.cwd = dirname;
    child_process.spawn() catch |err|
        panic("{} while running command: {s}", .{ err, command });
    return child_process;
}
