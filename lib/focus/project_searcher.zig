const focus = @import("../focus.zig");
usingnamespace focus.common;
const meta = focus.meta;
const App = focus.App;
const Buffer = focus.Buffer;
const Editor = focus.Editor;
const SingleLineEditor = focus.SingleLineEditor;
const Window = focus.Window;
const style = focus.style;
const Selector = focus.Selector;

pub const ProjectSearcher = struct {
    app: *App,
    project_dir: []const u8,
    empty_buffer: *Buffer,
    preview_editor: *Editor,
    input: SingleLineEditor,
    selector: Selector,

    pub fn init(app: *App, project_dir: []const u8, init_filter: []const u8) ProjectSearcher {
        const empty_buffer = Buffer.initEmpty(app);
        const preview_editor = Editor.init(app, empty_buffer, false);
        const input = SingleLineEditor.init(app, init_filter);
        const selector = Selector.init(app);

        return ProjectSearcher{
            .app = app,
            .project_dir = project_dir,
            .empty_buffer = empty_buffer,
            .preview_editor = preview_editor,
            .input = input,
            .selector = selector,
        };
    }

    pub fn deinit(self: *ProjectSearcher) void {
        self.selector.deinit();
        self.input.deinit();
        self.preview_editor.deinit();
        self.empty_buffer.deinit();
        // TODO should this own project_dir?
    }

    pub fn frame(self: *ProjectSearcher, window: *Window, rect: Rect, events: []const c.SDL_Event) void {
        const layout = window.layoutSearcher(rect);

        // run input frame
        self.input.frame(window, layout.input, events);

        // get and filter results
        var results = ArrayList([]const u8).init(self.app.frame_allocator);
        {
            const filter = self.input.getText();
            if (filter.len > 0) {
                const result = std.ChildProcess.exec(.{
                    .allocator = self.app.frame_allocator,
                    // TODO would prefer null separated but tricky to parse
                    .argv = &[6][]const u8{ "rg", "--line-number", "--sort", "path", "--fixed-strings", filter },
                    .cwd = self.project_dir,
                    .max_output_bytes = 128 * 1024 * 1024,
                }) catch |err| panic("{} while calling rg", .{err});
                assert(result.term == .Exited); // exits with 1 if no search results
                var lines = std.mem.split(result.stdout, "\n");
                while (lines.next()) |line| {
                    if (line.len != 0) results.append(line) catch oom();
                }
            }
        }

        // run selector frame
        const action = self.selector.frame(window, layout.selector, events, results.items);

        // update preview
        self.preview_editor.deinit();
        if (results.items.len > 0) {
            const line = results.items[self.selector.selected];
            var parts = std.mem.split(line, ":");
            const path_suffix = parts.next().?;
            const line_number_string = parts.next().?;
            const line_number = std.fmt.parseInt(usize, line_number_string, 10) catch |err| panic("{} while parsing line number {s} from rg", .{ err, line_number_string });

            const path = std.fs.path.join(self.app.frame_allocator, &[2][]const u8{ self.project_dir, path_suffix }) catch oom();
            self.preview_editor = Editor.init(self.app, self.app.getBufferFromAbsoluteFilename(path), false);

            var cursor = self.preview_editor.getMainCursor();
            self.preview_editor.goRealLine(cursor, line_number - 1);
            self.preview_editor.setMark();
            self.preview_editor.goRealLineEnd(cursor);
            // TODO centre cursor

            if (action == .SelectOne) {
                const new_editor = Editor.init(self.app, self.preview_editor.buffer, true);
                new_editor.top_pixel = self.preview_editor.top_pixel;
                window.popView();
                window.pushView(new_editor);
            }
        }

        // run preview frame
        self.preview_editor.frame(window, layout.preview, &[0]c.SDL_Event{});
    }
};
