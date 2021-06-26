const focus = @import("../focus.zig");
usingnamespace focus.common;
const meta = focus.meta;
const App = focus.App;
const Buffer = focus.Buffer;
const Editor = focus.Editor;
const SingleLineEditor = focus.SingleLineEditor;
const Selector = focus.Selector;
const Window = focus.Window;
const style = focus.style;

pub const BufferSearcher = struct {
    app: *App,
    target_editor: *Editor,
    preview_editor: *Editor,
    input: SingleLineEditor,
    selector: Selector,
    // The position of the currently selected item, or the start pos if nothing was selected yet.
    // This just helps preserve position in the editor when jumping in and out of the buffer searcher.
    selection_pos: usize,
    init_selection_pos: usize,

    pub fn init(app: *App, target_editor: *Editor) *BufferSearcher {
        const preview_editor = Editor.init(app, target_editor.buffer, false, false);
        preview_editor.getMainCursor().* = target_editor.getMainCursor().*;
        const input = SingleLineEditor.init(app, app.last_search_filter);
        input.editor.goRealLineStart(input.editor.getMainCursor());
        input.editor.setMark();
        input.editor.goRealLineEnd(input.editor.getMainCursor());
        const selector = Selector.init(app);
        const selection_pos = target_editor.getMainCursor().head.pos;
        var self = app.allocator.create(BufferSearcher) catch oom();
        self.* = BufferSearcher{
            .app = app,
            .target_editor = target_editor,
            .preview_editor = preview_editor,
            .input = input,
            .selector = selector,
            .selection_pos = selection_pos,
            .init_selection_pos = selection_pos,
        };
        return self;
    }

    pub fn deinit(self: *BufferSearcher) void {
        self.selector.deinit();
        self.input.deinit();
        self.preview_editor.deinit();
        // dont own target_editor
        self.app.allocator.destroy(self);
    }

    pub fn frame(self: *BufferSearcher, window: *Window, rect: Rect, events: []const c.SDL_Event) void {
        const layout = window.layoutSearcherWithPreview(rect);

        // run input frame
        const input_changed = self.input.frame(window, layout.input, events);
        if (input_changed == .Changed) self.selection_pos = self.init_selection_pos;

        // search buffer
        // TODO default to first result after target
        const filter = self.input.getText();
        var results = ArrayList([]const u8).init(self.app.frame_allocator);
        var result_poss = ArrayList(usize).init(self.app.frame_allocator);
        {
            const max_line_string = format(self.app.frame_allocator, "{}", .{self.preview_editor.buffer.countLines()});
            if (filter.len > 0) {
                var pos: usize = 0;
                var i: usize = 0;
                while (self.preview_editor.buffer.searchForwards(pos, filter)) |found_pos| {
                    const start = self.preview_editor.buffer.getLineStart(found_pos);
                    const end = self.preview_editor.buffer.getLineEnd(found_pos + filter.len);
                    const selection = self.preview_editor.buffer.dupe(self.app.frame_allocator, start, end);
                    assert(selection[0] != '\n' and selection[selection.len - 1] != '\n');

                    var result = ArrayList(u8).init(self.app.frame_allocator);
                    const line = self.preview_editor.buffer.getLineColForPos(found_pos)[0];
                    const line_string = format(self.app.frame_allocator, "{}", .{line});
                    result.appendSlice(line_string) catch oom();
                    result.appendNTimes(' ', max_line_string.len - line_string.len + 1) catch oom();
                    result.appendSlice(selection) catch oom();

                    results.append(result.toOwnedSlice()) catch oom();
                    result_poss.append(found_pos) catch oom();

                    pos = found_pos + filter.len;
                    i += 1;
                }
            }
        }

        // update selection
        self.selector.selected = max(result_poss.items.len, 1) - 1;
        for (result_poss.items) |result_pos, i| {
            if (self.selection_pos < result_pos + filter.len) {
                self.selector.selected = i;
                break;
            }
        }

        // run selector frame
        const old_selected = self.selector.selected;
        const action = self.selector.frame(window, layout.selector, events, results.items);
        if (self.selector.selected != old_selected and self.selector.selected < result_poss.items.len) {
            self.selection_pos = result_poss.items[self.selector.selected];
        }
        switch (action) {
            .None, .SelectRaw => {},
            .SelectOne, .SelectAll => {
                self.updateEditor(self.target_editor, rect, action, result_poss.items, filter);
                self.target_editor.top_pixel = self.preview_editor.top_pixel;
                window.popView();
            },
        }

        // set cached search text
        self.app.allocator.free(self.app.last_search_filter);
        self.app.last_search_filter = self.app.dupe(self.input.getText());

        // update preview
        self.updateEditor(self.preview_editor, layout.preview, action, result_poss.items, filter);

        // run preview frame
        self.preview_editor.frame(window, layout.preview, &[0]c.SDL_Event{});
    }

    fn updateEditor(self: *BufferSearcher, editor: *Editor, editor_rect: Rect, action: Selector.Action, result_poss: []usize, filter: []const u8) void {
        // TODO centre view on main cursor
        editor.collapseCursors();
        editor.setMark();
        switch (action) {
            .None, .SelectRaw, .SelectOne => {
                if (result_poss.len != 0) {
                    const pos = result_poss[self.selector.selected];
                    var cursor = editor.getMainCursor();
                    editor.goPos(cursor, pos + filter.len);
                    editor.updatePos(&cursor.tail, pos);
                    editor.setCenterAtPos(pos);
                }
            },
            .SelectAll => {
                for (result_poss) |pos, i| {
                    var cursor = if (i == 0) editor.getMainCursor() else editor.newCursor();
                    editor.goPos(cursor, pos + filter.len);
                    editor.updatePos(&cursor.tail, pos);
                    editor.setCenterAtPos(pos);
                }
            },
        }
    }
};
