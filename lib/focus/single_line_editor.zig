const std = @import("std");
const focus = @import("../focus.zig");
const u = focus.util;
const c = focus.util.c;
const App = focus.App;
const Buffer = focus.Buffer;
const Editor = focus.Editor;
const Window = focus.Window;
const style = focus.style;
const Selector = focus.Selector;

pub const SingleLineEditor = struct {
    app: *App,
    buffer: *Buffer,
    editor: *Editor,

    pub fn init(app: *App, init_text: []const u8) SingleLineEditor {
        const buffer = Buffer.initEmpty(app, .{
            .enable_completions = false,
        });
        const editor = Editor.init(app, buffer, .{
            .show_status_bar = false,
            .show_completer = false,
        });
        editor.insert(editor.getMainCursor(), init_text);
        return SingleLineEditor{
            .app = app,
            .buffer = buffer,
            .editor = editor,
        };
    }

    pub fn deinit(self: *SingleLineEditor) void {
        self.editor.deinit();
        self.buffer.deinit();
    }

    pub fn frame(self: *SingleLineEditor, window: *Window, rect: u.Rect, events: []const c.SDL_Event) enum { Changed, Unchanged } {
        const prev_text = self.app.dupe(self.getText());

        // filter out multiline events
        var editor_events = u.ArrayList(c.SDL_Event).init(self.app.frame_allocator);
        for (events) |event| {
            if (event.type == c.SDL_KEYDOWN) {
                if (event.key.keysym.sym == c.SDLK_RETURN) continue;
                if ((event.key.keysym.mod == c.KMOD_LALT or event.key.keysym.mod == c.KMOD_RALT) and (event.key.keysym.sym == 'k' or event.key.keysym.sym == 'i')) continue;
            }
            editor_events.append(event) catch u.oom();
        }

        // run editor
        self.editor.frame(window, rect, editor_events.items);

        // remove any sneaky newlines from eg paste
        // TODO want to put this between event handling and render
        {
            var pos: usize = 0;
            while (self.buffer.searchForwards(pos, "\n")) |new_pos| {
                pos = new_pos;
                self.editor.delete(pos, pos + 1);
            }
        }

        return if (std.mem.eql(u8, prev_text, self.getText())) .Unchanged else .Changed;
    }

    pub fn getText(self: *SingleLineEditor) []const u8 {
        // TODO should this copy?
        return self.buffer.bytes.items;
    }

    pub fn setText(self: *SingleLineEditor, text: []const u8) void {
        self.buffer.replace(text);
        self.editor.clearMark();
        self.editor.collapseCursors();
        self.editor.goBufferEnd(self.editor.getMainCursor());
    }
};
