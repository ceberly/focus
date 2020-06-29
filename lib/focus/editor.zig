const focus = @import("../focus.zig");
usingnamespace focus.common;
const atlas = focus.atlas;
const UI = focus.UI;

pub const Buffer = struct {
    allocator: *Allocator,
    text: ArrayList(u8),

    pub fn init(allocator: *Allocator) Buffer {
        return Buffer{
            .allocator = allocator,
            .text = ArrayList(u8).init(allocator),
        };
    }

    pub fn deinit(self: *Buffer) void {
        self.text.deinit();
    }

    pub fn getBufferEnd(self: *Buffer) usize {
        return self.text.items.len;
    }

    pub fn getPosForLine(self: *Buffer, line: usize) usize {
        var pos: usize = 0;
        var lines_remaining = line;
        while (lines_remaining > 0) : (lines_remaining -= 1) {
            pos = if (self.searchForwards(pos, "\n")) |next_pos| next_pos + 1 else self.text.items.len;
        }
        return pos;
    }

    pub fn getPosForLineCol(self: *Buffer, line: usize, col: usize) usize {
        var pos = self.getPosForLine(line);
        const end = if (self.searchForwards(pos, "\n")) |line_end| line_end + 1 else self.text.items.len;
        pos += min(col, end - pos);
        return pos;
    }

    pub fn getLineColForPos(self: *Buffer, pos: usize) [2]usize {
        var line: usize = 0;
        const col = pos - self.lineStart();
        var pos_remaining = pos;
        while (self.searchBackwards(pos_remaining, "\n")) |line_start| {
            pos_remaining = line_start - 1;
            line += 1;
        }
        return .{line, col};
    }

    pub fn searchBackwards(self: *Buffer, pos: usize, needle: []const u8) ?usize {
        const text = self.text.items[0..pos];
        return if (std.mem.lastIndexOf(u8, text, needle)) |result_pos| result_pos + needle.len else null;
    }

    pub fn searchForwards(self: *Buffer, pos: usize, needle: []const u8) ?usize {
        const text = self.text.items[pos..];
        return if (std.mem.indexOf(u8, text, needle)) |result_pos| result_pos + pos else null;
    }

    pub fn dupe(self: *Buffer, allocator: *Allocator, start: usize, end: usize) ! []const u8 {
        assert(start <= end);
        assert(end <= self.text.items.len);
        return std.mem.dupe(allocator, u8, self.text.items[start..end]);
    }

    pub fn insert(self: *Buffer, pos: usize, chars: []const u8) ! void {
        try self.text.resize(self.text.items.len + chars.len);
        std.mem.copyBackwards(u8, self.text.items[pos+chars.len..], self.text.items[pos..self.text.items.len-chars.len]);
        std.mem.copy(u8, self.text.items[pos..], chars);
    }

    pub fn delete(self: *Buffer, start: usize, end: usize) void {
        assert(start <= end);
        assert(end <= self.text.items.len);
        std.mem.copy(u8, self.text.items[start..], self.text.items[end..]);
        self.text.shrink(self.text.items.len - (end - start));
    }
};

pub const Point = struct {
    // what char we're at
    // 0 <= pos <= buffer.getBufferEnd()
    pos: usize,
    // what column we 'want' to be at
    // should only be updated by left/right movement
    // 0 <= col
    col: usize,
};

pub const Cursor = struct {
    // the actual cursor
    head: Point,
    // the other end of the selection, if view.marked
    tail: Point,
    // allocated by view.allocator
    clipboard: []const u8,
};

pub const View = struct {
    allocator: *Allocator,
    buffer: *Buffer,
    // cursors.len > 0
    cursors: ArrayList(Cursor),
    marked: bool,
    mouse_was_down: bool,

    pub fn init(allocator: *Allocator, buffer: *Buffer) ! View {
        var cursors = ArrayList(Cursor).init(allocator);
        try cursors.append(.{
            .head = .{.pos=0, .col=0},
            .tail = .{.pos=0, .col=0},
            .clipboard="",
        });
        return View{
            .allocator = allocator,
            .buffer = buffer,
            .cursors = cursors,
            .marked = false,
            .mouse_was_down = false,
        };
    }

    pub fn deinit(self: *View) void {
        for (self.cursors.items) |cursor| {
            self.allocator.free(cursor.clipboard);
        }
        self.cursors.deinit();
    }

    pub fn searchBackwards(self: *View, point: Point, needle: []const u8) ?usize {
        return self.buffer.searchBackwards(point.pos, needle);
    }

    pub fn searchForwards(self: *View, point: Point, needle: []const u8) ?usize {
        return self.buffer.searchForwards(point.pos, needle);
    }

    pub fn getLineStart(self: *View, point: Point) usize {
        return self.searchBackwards(point, "\n") orelse 0;
    }

    pub fn getLineEnd(self: *View, point: Point) usize {
        return self.searchForwards(point, "\n") orelse self.buffer.getBufferEnd();
    }

    pub fn updateCol(self: *View, point: *Point) void {
        point.col = point.pos - self.getLineStart(point.*);
    }

    pub fn updatePos(self: *View, point: *Point, pos: usize) void {
        point.pos = pos;
        self.updateCol(point);
    }

    pub fn goPos(self: *View, cursor: *Cursor, pos: usize) void {
        self.updatePos(&cursor.head, pos);
    }

    pub fn goCol(self: *View, cursor: *Cursor, col: usize) void {
        const line_start = self.getLineStart(cursor.head);
        cursor.head.col = min(col, self.getLineEnd(cursor.head) - line_start);
        cursor.head.pos = line_start + cursor.head.col;
    }

    pub fn goLine(self: *View, cursor: *Cursor, line: usize) void {
        cursor.head.pos = self.buffer.getPosForLine(line);
        // leave head.col intact
    }

    pub fn goLineCol(self: *View, cursor: *Cursor, line: usize, col: usize) void {
        self.goLine(cursor, line);
        self.goCol(cursor, col);
    }

    pub fn goLeft(self: *View, cursor: *Cursor) void {
        cursor.head.pos -= @as(usize, if (cursor.head.pos == 0) 0 else 1);
        self.updateCol(&cursor.head);
    }

    pub fn goRight(self: *View, cursor: *Cursor) void {
        cursor.head.pos += @as(usize, if (cursor.head.pos >= self.buffer.getBufferEnd()) 0 else 1);
        self.updateCol(&cursor.head);
    }

    pub fn goDown(self: *View, cursor: *Cursor) void {
        if (self.searchForwards(cursor.head, "\n")) |line_end| {
            const col = cursor.head.col;
            cursor.head.pos = line_end + 1;
            self.goCol(cursor, col);
            cursor.head.col = col;
        }
    }

    pub fn goUp(self: *View, cursor: *Cursor) void {
        if (self.searchBackwards(cursor.head, "\n")) |line_start| {
            const col = cursor.head.col;
            cursor.head.pos = line_start - 1;
            self.goCol(cursor, col);
            cursor.head.col = col;
        }
    }

    pub fn goLineStart(self: *View, cursor: *Cursor) void {
        cursor.head.pos = self.getLineStart(cursor.head);
        cursor.head.col = 0;
    }

    pub fn goLineEnd(self: *View, cursor: *Cursor) void {
        cursor.head.pos = self.searchForwards(cursor.head, "\n") orelse self.buffer.getBufferEnd();
        self.updateCol(&cursor.head);
    }

    pub fn goPageStart(self: *View, cursor: *Cursor) void {
        self.goPos(cursor, 0);
    }

    pub fn goPageEnd(self: *View, cursor: *Cursor) void {
        self.goPos(cursor, self.buffer.getBufferEnd());
    }

    pub fn insert(self: *View, cursor: *Cursor, chars: []const u8) ! void {
        self.deleteSelection(cursor);
        try self.buffer.insert(cursor.head.pos, chars);
        const insert_at = cursor.head.pos;
        for (self.cursors.items) |*other_cursor| {
            for (&[2]*Point{&other_cursor.head, &other_cursor.tail}) |point| {
                // TODO want paste to leave each cursor after its own insert
                if (point.pos >= insert_at) point.pos += chars.len;
                self.updateCol(point);
            }
        }
    }

    pub fn delete(self: *View, start: usize, end: usize) void {
        assert(start <= end);
        self.buffer.delete(start, end);
        for (self.cursors.items) |*other_cursor| {
            for (&[2]*Point{&other_cursor.head, &other_cursor.tail}) |point| {
                if (point.pos >= start and point.pos <= end) point.pos = start;
                if (point.pos > end) point.pos -= (end - start);
                self.updateCol(point);
            }
        }
    }

    pub fn deleteSelection(self: *View, cursor: *Cursor) void {
        if (self.marked) {
            const selection = self.getSelection(cursor);
            self.delete(selection[0], selection[1]);
        }
    }

    pub fn deleteBackwards(self: *View, cursor: *Cursor) void {
        if (self.marked) {
            self.deleteSelection(cursor);
        } else if (cursor.head.pos > 0) {
            self.delete(cursor.head.pos-1, cursor.head.pos);
        }
    }

    pub fn deleteForwards(self: *View, cursor: *Cursor) void {
        if (self.marked) {
            self.deleteSelection(cursor);
        } else if (cursor.head.pos < self.buffer.getBufferEnd()) {
            self.delete(cursor.head.pos, cursor.head.pos+1);
        }
    }

    pub fn clearMark(self: *View) void {
        self.marked = false;
    }

    pub fn setMark(self: *View) void {
        self.marked = true;
        for (self.cursors.items) |*cursor| {
            cursor.tail = cursor.head;
        }
    }

    pub fn toggleMark(self: *View) void {
        if (self.marked) {
            self.clearMark();
        } else {
            self.setMark();
        }
    }

    pub fn swapHead(self: *View, cursor: *Cursor) void {
        std.mem.swap(Point, &cursor.head, &cursor.tail);
    }

    pub fn getSelection(self: *View, cursor: *Cursor) [2]usize {
        assert(self.marked);
        const selection_start_pos = min(cursor.head.pos, cursor.tail.pos);
        const selection_end_pos = max(cursor.head.pos, cursor.tail.pos);
        return [2]usize{selection_start_pos, selection_end_pos};
    }

    pub fn dupeSelection(self: *View, cursor: *Cursor) ! []const u8 {
        const selection = self.getSelection(cursor);
        return self.buffer.dupe(self.allocator, selection[0], selection[1]);
    }

    pub fn copy(self: *View, cursor: *Cursor) ! void {
        self.allocator.free(cursor.clipboard);
        cursor.clipboard = try self.dupeSelection(cursor);
    }

    pub fn cut(self: *View, cursor: *Cursor) ! void {
        self.allocator.free(cursor.clipboard);
        cursor.clipboard = try self.dupeSelection(cursor);
        self.deleteSelection(cursor);
    }

    pub fn paste(self: *View, cursor: *Cursor) ! void {
        try self.insert(cursor, cursor.clipboard);
    }

    pub fn newCursor(self: *View) ! *Cursor {
        try self.cursors.append(.{
            .head = .{.pos=0, .col=0},
            .tail = .{.pos=0, .col=0},
            .clipboard="",
        });
        return &self.cursors.items[self.cursors.items.len-1];
    }

    pub fn collapseCursors(self: *View) ! void {
        var size: usize = 0;
        for (self.cursors.items) |cursor| {
            size += cursor.clipboard.len;
        }
        var clipboard = try ArrayList(u8).initCapacity(self.allocator, size);
        for (self.cursors.items) |cursor| {
            clipboard.appendSlice(cursor.clipboard) catch unreachable;
            self.allocator.free(cursor.clipboard);
        }
        self.cursors.shrink(1);
        self.cursors.items[0].clipboard = clipboard.toOwnedSlice();
    }

    const text_color = UI.Color{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const highlight_color = UI.Color{ .r = 255, .g = 255, .b = 255, .a = 100 };

    pub fn frame(self: *View, ui: *UI, rect: UI.Rect) ! void {
        // TODO rctrl/ralt?
        const ctrl = 224;
        const alt = 226;

        // handle keys
        for (ui.key_went_down.items) |key| {
            if (ui.key_is_down[ctrl]) {
                switch (key) {
                    ' ' => self.toggleMark(),
                    'c' => {
                        for (self.cursors.items) |*cursor| try self.copy(cursor);
                        self.clearMark();
                    },
                    'x' => {
                        for (self.cursors.items) |*cursor| try self.cut(cursor);
                        self.clearMark();
                    },
                    'v' => {
                        for (self.cursors.items) |*cursor| try self.paste(cursor);
                        self.clearMark();
                    },
                    'j' => for (self.cursors.items) |*cursor| self.goLeft(cursor),
                    'l' => for (self.cursors.items) |*cursor| self.goRight(cursor),
                    'k' => for (self.cursors.items) |*cursor| self.goDown(cursor),
                    'i' => for (self.cursors.items) |*cursor| self.goUp(cursor),
                    else => {},
                }
            } else if (ui.key_is_down[alt]) {
                switch (key) {
                    ' ' => for (self.cursors.items) |*cursor| self.swapHead(cursor),
                    'j' => for (self.cursors.items) |*cursor| self.goLineStart(cursor),
                    'l' => for (self.cursors.items) |*cursor| self.goLineEnd(cursor),
                    'k' => for (self.cursors.items) |*cursor| self.goPageEnd(cursor),
                    'i' => for (self.cursors.items) |*cursor| self.goPageStart(cursor),
                    else => {},
                }
            } else {
                switch (key) {
                    8 => {
                        for (self.cursors.items) |*cursor| self.deleteBackwards(cursor);
                        self.clearMark();
                    },
                    13 => {
                        for (self.cursors.items) |*cursor| try self.insert(cursor, &[1]u8{'\n'});
                        self.clearMark();
                    },
                    27 => {
                        try self.collapseCursors();
                        self.clearMark();
                    },
                    79 => for (self.cursors.items) |*cursor| self.goRight(cursor),
                    80 => for (self.cursors.items) |*cursor| self.goLeft(cursor),
                    81 => for (self.cursors.items) |*cursor| self.goDown(cursor),
                    82 => for (self.cursors.items) |*cursor| self.goUp(cursor),
                    127 => {
                        for (self.cursors.items) |*cursor| self.deleteForwards(cursor);
                        self.clearMark();
                    },
                    else => if (key >= 32 and key <= 126) {
                        for (self.cursors.items) |*cursor| try self.insert(cursor, &[1]u8{key});
                        self.clearMark();
                    },
                }
            }
        }

        // handle mouse
        // TODO change mouse_is_down to event list like keys
        if (ui.mouse_is_down[0]) {
            const line = @divTrunc(ui.mouse_pos.y - rect.y, atlas.text_height);
            const col = @divTrunc(ui.mouse_pos.x - rect.x, atlas.max_char_width);
            const pos = self.buffer.getPosForLineCol(line, col);

            if (ui.mouse_went_down[0]) {
                // on mouse down
                if (ui.key_is_down[ctrl]) {
                    var cursor = try self.newCursor();
                    self.updatePos(&cursor.head, pos);
                    self.updatePos(&cursor.tail, pos);
                } else {
                    for (self.cursors.items) |*cursor| {
                        self.updatePos(&cursor.head, pos);
                        self.updatePos(&cursor.tail, pos);
                    }
                    self.clearMark();
                }
            } else {
                // on mouse drag
                if (ui.key_is_down[ctrl]) {
                    var cursor = &self.cursors.items[self.cursors.items.len-1];
                    if (cursor.tail.pos != pos and !self.marked) {
                        self.setMark();
                    }
                    self.updatePos(&cursor.head, pos);
                } else {
                    for (self.cursors.items) |*cursor| {
                        if (cursor.tail.pos != pos and !self.marked) {
                            self.setMark();
                        }
                        self.updatePos(&cursor.head, pos);
                    }
                }
            }
        } 

        // draw
        var lines = std.mem.split(self.buffer.text.items, "\n");
        var line_ix: u16 = 0;
        var line_start_pos: usize = 0;
        while (lines.next()) |line| : (line_ix += 1) {
            if ((line_ix * atlas.text_height) > rect.h) break;
            
            const y = rect.y + (line_ix * atlas.text_height);
            const line_end_pos = line_start_pos + line.len;

            for (self.cursors.items) |cursor| {
                // draw cursor
                if (cursor.head.pos >= line_start_pos and cursor.head.pos <= line_end_pos) {
                    const x = rect.x + ((cursor.head.pos - line_start_pos) * atlas.max_char_width);
                    try ui.queueRect(.{.x = @intCast(u16, x), .y = y, .w=1, .h=atlas.text_height}, text_color);
                }

                // draw selection
                if (self.marked) {
                    const selection_start_pos = min(cursor.head.pos, cursor.tail.pos);
                    const selection_end_pos = max(cursor.head.pos, cursor.tail.pos);
                    const highlight_start_pos = min(max(selection_start_pos, line_start_pos), line_end_pos);
                    const highlight_end_pos = min(max(selection_end_pos, line_start_pos), line_end_pos);
                    if ((highlight_start_pos < highlight_end_pos) or (selection_start_pos <= line_end_pos and selection_end_pos > line_end_pos)) {
                        const x = rect.x + ((highlight_start_pos - line_start_pos) * atlas.max_char_width);
                        const w = if (selection_end_pos > line_end_pos)
                            rect.x + rect.w - x
                            else
                            (highlight_end_pos - highlight_start_pos) * atlas.max_char_width;
                        try ui.queueRect(.{.x = @intCast(u16, x), .y = y, .w=@intCast(u16, w), .h=atlas.text_height}, highlight_color);
                    }
                }
            }
            
            // draw text
            try ui.queueText(.{.x = rect.x, .y = y}, text_color, line);
            
            line_start_pos = line_end_pos + 1; // + 1 for '\n'
        }
    }
};
