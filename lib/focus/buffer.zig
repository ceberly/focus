const focus = @import("../focus.zig");
usingnamespace focus.common;
const App = focus.App;
const Editor = focus.Editor;
const meta = focus.meta;
const LineWrappedBuffer = focus.LineWrappedBuffer;

pub const BufferSource = union(enum) {
    None,
    File: struct {
        absolute_filename: []const u8,
        mtime: i128,
    },

    fn deinit(self: *BufferSource, app: *App) void {
        switch (self.*) {
            .None => {},
            .File => |file_source| app.allocator.free(file_source.absolute_filename),
        }
    }
};

pub const Edit = struct {
    tag: enum {
        Insert, Delete
    },
    data: struct {
        start: usize,
        end: usize,
        bytes: []const u8,
    },
};

pub const Buffer = struct {
    app: *App,
    source: BufferSource,
    bytes: ArrayList(u8),
    undos: ArrayList([]Edit),
    doing: ArrayList(Edit),
    redos: ArrayList([]Edit),
    modified_since_last_save: bool,
    editors: ArrayList(*Editor),

    pub fn initEmpty(app: *App) *Buffer {
        const self = app.allocator.create(Buffer) catch oom();
        self.* = Buffer{
            .app = app,
            .source = .None,
            .bytes = ArrayList(u8).init(app.allocator),
            .undos = ArrayList([]Edit).init(app.allocator),
            .doing = ArrayList(Edit).init(app.allocator),
            .redos = ArrayList([]Edit).init(app.allocator),
            .modified_since_last_save = false,
            .editors = ArrayList(*Editor).init(app.allocator),
        };
        return self;
    }

    pub fn initFromAbsoluteFilename(app: *App, absolute_filename: []const u8) *Buffer {
        assert(std.fs.path.isAbsolute(absolute_filename));
        const self = Buffer.initEmpty(app);
        self.source = .{
            .File = .{
                .absolute_filename = std.mem.dupe(self.app.allocator, u8, absolute_filename) catch oom(),
                .mtime = 0,
            },
        };
        self.load();
        // don't want the load on the undo stack
        for (self.doing.items) |edit| self.app.allocator.free(edit.data.bytes);
        self.doing.shrink(0);
        return self;
    }

    pub fn deinit(self: *Buffer) void {
        // all editors should have unregistered already
        assert(self.editors.items.len == 0);
        self.editors.deinit();

        for (self.undos.items) |edits| {
            for (edits) |edit| self.app.allocator.free(edit.data.bytes);
            self.app.allocator.free(edits);
        }
        self.undos.deinit();

        for (self.doing.items) |edit| self.app.allocator.free(edit.data.bytes);
        self.doing.deinit();

        for (self.redos.items) |edits| {
            for (edits) |edit| self.app.allocator.free(edit.data.bytes);
            self.app.allocator.free(edits);
        }
        self.redos.deinit();

        self.bytes.deinit();

        self.source.deinit(self.app);

        self.app.allocator.destroy(self);
    }

    const TryLoadResult = struct {
        bytes: []const u8,
        mtime: i128,
    };
    fn tryLoad(self: *Buffer) !TryLoadResult {
        const file = try std.fs.cwd().createFile(self.source.File.absolute_filename, .{ .read = true, .truncate = false });
        defer file.close();

        const mtime = (try file.stat()).mtime;

        const chunk_size = 1024;
        var buf = self.app.frame_allocator.alloc(u8, chunk_size) catch oom();
        var bytes = ArrayList(u8).init(self.app.frame_allocator);

        while (true) {
            const len = try file.readAll(buf);
            // worth handling oom here for big files
            try bytes.appendSlice(buf[0..len]);
            if (len < chunk_size) break;
        }

        return TryLoadResult{
            .bytes = bytes.toOwnedSlice(),
            .mtime = mtime,
        };
    }

    fn load(self: *Buffer) void {
        if (self.tryLoad()) |result| {
            self.replace(result.bytes);
            self.source.File.mtime = result.mtime;
        } else |err| {
            const message = format(self.app.allocator, "{} while loading {s}", .{ err, self.getFilename() });
            dump(message);
            self.replace(message);
        }
    }

    pub fn refresh(self: *Buffer) void {
        switch (self.source) {
            .None => {},
            .File => |file_source| {
                const file = std.fs.cwd().createFile(file_source.absolute_filename, .{ .read = true, .truncate = false }) catch |err| panic("{} while refreshing {s}", .{ err, file_source.absolute_filename });
                defer file.close();
                const stat = file.stat() catch |err| panic("{} while refreshing {s}", .{ err, file_source.absolute_filename });
                if (stat.mtime != file_source.mtime) {
                    self.load();
                }
            },
        }
    }

    pub fn save(self: *Buffer) void {
        switch (self.source) {
            .None => {},
            .File => |*file_source| {
                const file = std.fs.cwd().createFile(file_source.absolute_filename, .{ .read = false, .truncate = true }) catch |err| panic("{} while saving {s}", .{ err, file_source.absolute_filename });
                defer file.close();
                file.writeAll(self.bytes.items) catch |err| panic("{} while saving {s}", .{ err, file_source.absolute_filename });
                const stat = file.stat() catch |err| panic("{} while saving {s}", .{ err, file_source.absolute_filename });
                file_source.mtime = stat.mtime;
                self.modified_since_last_save = false;
            },
        }
    }

    pub fn getBufferEnd(self: *Buffer) usize {
        return self.bytes.items.len;
    }

    pub fn getPosForLine(self: *Buffer, line: usize) usize {
        var pos: usize = 0;
        var lines_remaining = line;
        while (lines_remaining > 0) : (lines_remaining -= 1) {
            pos = if (self.searchForwards(pos, "\n")) |next_pos| next_pos + 1 else self.bytes.items.len;
        }
        return pos;
    }

    pub fn getPosForLineCol(self: *Buffer, line: usize, col: usize) usize {
        var pos = self.getPosForLine(line);
        const end = if (self.searchForwards(pos, "\n")) |line_end| line_end else self.bytes.items.len;
        pos += min(col, end - pos);
        return pos;
    }

    pub fn getLineColForPos(self: *Buffer, pos: usize) [2]usize {
        var line: usize = 0;
        const col = pos - (self.searchBackwards(pos, "\n") orelse 0);
        var pos_remaining = pos;
        while (self.searchBackwards(pos_remaining, "\n")) |line_start| {
            pos_remaining = line_start - 1;
            line += 1;
        }
        return .{ line, col };
    }

    pub fn searchBackwards(self: *Buffer, pos: usize, needle: []const u8) ?usize {
        const bytes = self.bytes.items[0..pos];
        return if (std.mem.lastIndexOf(u8, bytes, needle)) |result_pos| result_pos + needle.len else null;
    }

    pub fn searchForwards(self: *Buffer, pos: usize, needle: []const u8) ?usize {
        const bytes = self.bytes.items[pos..];
        return if (std.mem.indexOf(u8, bytes, needle)) |result_pos| result_pos + pos else null;
    }

    pub fn getLineStart(self: *Buffer, pos: usize) usize {
        return self.searchBackwards(pos, "\n") orelse 0;
    }

    pub fn getLineEnd(self: *Buffer, pos: usize) usize {
        return self.searchForwards(pos, "\n") orelse self.getBufferEnd();
    }

    // TODO pass outStream instead of Allocator for easy concat/sentinel? but costs more allocations?
    pub fn dupe(self: *Buffer, allocator: *Allocator, start: usize, end: usize) []const u8 {
        assert(start <= end);
        assert(end <= self.bytes.items.len);
        return std.mem.dupe(allocator, u8, self.bytes.items[start..end]) catch oom();
    }

    fn rawInsert(self: *Buffer, pos: usize, bytes: []const u8) void {
        self.bytes.resize(self.bytes.items.len + bytes.len) catch oom();
        std.mem.copyBackwards(u8, self.bytes.items[pos + bytes.len ..], self.bytes.items[pos .. self.bytes.items.len - bytes.len]);
        std.mem.copy(u8, self.bytes.items[pos..], bytes);
        self.modified_since_last_save = true;
        for (self.editors.items) |editor| {
            editor.updateAfterInsert(pos, bytes);
        }
    }

    fn rawDelete(self: *Buffer, start: usize, end: usize) void {
        assert(start <= end);
        assert(end <= self.bytes.items.len);
        std.mem.copy(u8, self.bytes.items[start..], self.bytes.items[end..]);
        self.bytes.shrink(self.bytes.items.len - (end - start));
        self.modified_since_last_save = true;
        for (self.editors.items) |editor| {
            editor.updateAfterDelete(start, end);
        }
    }

    pub fn insert(self: *Buffer, pos: usize, bytes: []const u8) void {
        self.doing.append(.{
            .tag = .Insert,
            .data = .{
                .start = pos,
                .end = pos + bytes.len,
                .bytes = std.mem.dupe(self.app.allocator, u8, bytes) catch oom(),
            },
        }) catch oom();
        self.redos.shrink(0);
        self.rawInsert(pos, bytes);
    }

    pub fn delete(self: *Buffer, start: usize, end: usize) void {
        self.doing.append(.{
            .tag = .Delete,
            .data = .{
                .start = start,
                .end = end,
                .bytes = std.mem.dupe(self.app.allocator, u8, self.bytes.items[start..end]) catch oom(),
            },
        }) catch oom();
        self.redos.shrink(0);
        self.rawDelete(start, end);
    }

    pub fn replace(self: *Buffer, new_bytes: []const u8) void {
        if (!std.mem.eql(u8, self.bytes.items, new_bytes)) {
            self.doing.append(.{
                .tag = .Delete,
                .data = .{
                    .start = 0,
                    .end = self.bytes.items.len,
                    .bytes = std.mem.dupe(self.app.allocator, u8, self.bytes.items) catch oom(),
                },
            }) catch oom();
            self.doing.append(.{
                .tag = .Insert,
                .data = .{
                    .start = 0,
                    .end = new_bytes.len,
                    .bytes = std.mem.dupe(self.app.allocator, u8, new_bytes) catch oom(),
                },
            }) catch oom();
            self.redos.shrink(0);

            var line_colss = ArrayList([][2]usize).init(self.app.frame_allocator);
            for (self.editors.items) |editor| {
                line_colss.append(editor.updateBeforeReplace()) catch oom();
            }
            std.mem.reverse([][2]usize, line_colss.items);

            self.bytes.resize(0) catch oom();
            self.bytes.appendSlice(new_bytes) catch oom();

            for (self.editors.items) |editor| {
                editor.updateAfterReplace(line_colss.pop());
            }
        }
    }

    pub fn newUndoGroup(self: *Buffer) void {
        if (self.doing.items.len > 0) {
            const edits = self.doing.toOwnedSlice();
            std.mem.reverse(Edit, edits);
            self.undos.append(edits) catch oom();
        }
    }

    pub fn undo(self: *Buffer) ?usize {
        self.newUndoGroup();
        var pos: ?usize = null;
        if (self.undos.popOrNull()) |edits| {
            for (edits) |edit| {
                switch (edit.tag) {
                    .Insert => {
                        self.rawDelete(edit.data.start, edit.data.end);
                        pos = edit.data.start;
                    },
                    .Delete => {
                        self.rawInsert(edit.data.start, edit.data.bytes);
                        pos = edit.data.end;
                    },
                }
            }
            std.mem.reverse(Edit, edits);
            self.redos.append(edits) catch oom();
        }
        return pos;
    }

    pub fn redo(self: *Buffer) ?usize {
        var pos: ?usize = null;
        if (self.redos.popOrNull()) |edits| {
            for (edits) |edit| {
                switch (edit.tag) {
                    .Insert => {
                        self.rawInsert(edit.data.start, edit.data.bytes);
                        pos = edit.data.end;
                    },
                    .Delete => {
                        self.rawDelete(edit.data.start, edit.data.end);
                        pos = edit.data.start;
                    },
                }
            }
            std.mem.reverse(Edit, edits);
            self.undos.append(edits) catch oom();
        }
        return pos;
    }

    pub fn countLines(self: *Buffer) usize {
        var lines: usize = 0;
        var iter = std.mem.split(self.bytes.items, "\n");
        while (iter.next()) |_| lines += 1;
        return lines;
    }

    pub fn getFilename(self: *Buffer) ?[]const u8 {
        return switch (self.source) {
            .None => null,
            .File => |file_source| file_source.absolute_filename,
        };
    }

    pub fn getChar(self: *Buffer, pos: usize) u8 {
        return self.bytes.items[pos];
    }

    pub fn registerEditor(self: *Buffer, editor: *Editor) void {
        self.editors.append(editor) catch oom();
    }

    pub fn deregisterEditor(self: *Buffer, editor: *Editor) void {
        const i = std.mem.indexOfScalar(*Editor, self.editors.items, editor).?;
        _ = self.editors.swapRemove(i);
    }
};
