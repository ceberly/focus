const focus = @import("../focus.zig");
usingnamespace focus.common;

// TODO try PackedIntArray
// TODO Leaf/Branch can be done much nicer with packed structs once they are less buggy

const page_size = 4 * 1024;

fn roundDownTo(i: usize, mod: usize) usize {
    return mod * @divTrunc(i, mod);
}

fn roundUpTo(i: usize, mod: usize) usize {
    return mod * (@divTrunc(i, mod) + if (@mod(i, mod) > 0) @intCast(usize, 1) else 0);
}

fn alignTo(comptime T: type, address: usize) usize {
    return roundUpTo(address, @alignOf(T));
}

pub const Node = packed struct {
    parent: ?*Node,
    tag: packed enum(u8) { Leaf, Branch },

    fn getParent(self: Node) ?Branch {
        if (self.parent) |parent_node|
            return Branch.fromNode(parent_node)
        else
            return null;
    }

    pub fn findInParent(self: *Node) Branch.Offset {
        return self.getParent().?.findChild(self);
    }

    fn debugInto(self: *Node, output: *ArrayList(u8), indent: usize, num_bytes: usize) void {
        switch (self.tag) {
            .Leaf => Leaf.fromNode(self).debugInto(output, indent, num_bytes),
            .Branch => Branch.fromNode(self).debugInto(output, indent, num_bytes),
        }
    }
};

pub const Leaf = struct {
    node: *Node,
    bytes: *[max_bytes]u8,

    pub const max_bytes = page_size - @sizeOf(Node);
    pub const Offset = u16;
    comptime {
        assert(std.math.maxInt(Offset) > max_bytes);
    }

    fn init(allocator: *Allocator) Leaf {
        const page = allocator.alloc(u8, page_size) catch oom();
        const node = @ptrCast(*Node, page);
        node.parent = null;
        node.tag = .Leaf;
        return fromNode(node);
    }

    const bytes_offset = @sizeOf(Node);

    fn fromNode(node: *Node) Leaf {
        assert(node.tag == .Leaf);
        var address = @ptrToInt(node);
        return .{
            .node = node,
            .bytes = @intToPtr(*[max_bytes]u8, address + bytes_offset),
        };
    }

    fn debugInto(self: *Leaf, output: *ArrayList(u8), indent: usize, num_bytes: usize) void {
        output.appendNTimes(' ', indent) catch oom();
        std.fmt.format(output.outStream(), "{}\n", .{num_bytes}) catch oom();
    }
};

pub const Branch = struct {
    node: *Node,
    num_children: *Offset,
    children: *[max_children]*Node,
    num_bytes: *[max_children]usize,

    pub const max_children = @divTrunc(
        @sizeOf(usize) * @divTrunc(
            page_size - @sizeOf(Node) - @sizeOf(Offset),
            @sizeOf(usize),
        ),
        @sizeOf(*Node) + @sizeOf(*usize),
    );
    pub const Offset = u16;
    comptime {
        assert(std.math.maxInt(Offset) > max_children);
    }

    fn init(allocator: *Allocator) Branch {
        const page = allocator.allocWithOptions(usize, page_size, @alignOf(usize), null) catch oom();
        const node = @ptrCast(*Node, page);
        node.parent = null;
        node.tag = .Branch;
        var self = fromNode(node);
        self.num_children.* = 0;
        return self;
    }

    const num_children_offset = alignTo(Offset, @sizeOf(Node));
    const children_offset = alignTo(*Node, num_children_offset + @sizeOf(Offset));
    const num_bytes_offset = alignTo(usize, children_offset + @sizeOf([max_children]*Node));

    fn fromNode(node: *Node) Branch {
        assert(node.tag == .Branch);
        var address = @ptrToInt(node);
        return .{
            .node = node,
            .num_children = @intToPtr(*Offset, address + num_children_offset),
            .children = @intToPtr(*[max_children]*Node, address + children_offset),
            .num_bytes = @intToPtr(*[max_children]usize, address + num_bytes_offset),
        };
    }

    pub fn findChild(self: Branch, child: *Node) Offset {
        return @intCast(Offset, std.mem.indexOfScalar(*Node, self.children[0..self.num_children.*], child).?);
    }

    pub fn insertChild(self: Branch, child_ix: usize, child: *Node, num_bytes: usize) void {
        assert(self.num_children.* < Branch.max_children);
        std.mem.copyBackwards(
            *Node,
            self.children[child_ix + 1 ..],
            self.children[child_ix..self.num_children.*],
        );
        std.mem.copyBackwards(
            usize,
            self.num_bytes[child_ix + 1 ..],
            self.num_bytes[child_ix..self.num_children.*],
        );
        self.children[child_ix] = child;
        self.num_bytes[child_ix] = num_bytes;
        self.num_children.* += 1;
        child.parent = self.node;
    }

    pub fn getNumBytes(self: Branch) usize {
        var num_bytes: usize = 0;
        for (self.num_bytes[0..self.num_children.*]) |n|
            num_bytes += n;
        return num_bytes;
    }

    fn debugInto(self: *Branch, output: *ArrayList(u8), indent: usize, num_bytes: usize) void {
        output.appendNTimes(' ', indent) catch oom();
        output.appendSlice("*\n") catch oom();
        var child_ix: usize = 0;
        while (child_ix < self.num_children.*) : (child_ix += 1) {
            self.children[child_ix].debugInto(output, indent + 4, self.num_bytes[child_ix]);
        }
    }
};

pub const Point = struct {
    leaf: Leaf,
    offset: Leaf.Offset,
};

pub const Tree = struct {
    allocator: *Allocator,
    root: Branch,

    pub fn init(allocator: *Allocator) Tree {
        var branch = Branch.init(allocator);
        var leaf = Leaf.init(allocator);
        branch.insertChild(0, leaf.node, 0);
        return .{
            .allocator = allocator,
            .root = branch,
        };
    }

    pub fn getPointForPos(self: *Tree, pos: usize, which: enum { Earliest, Latest }) ?Point {
        var node = self.root.node;
        var pos_remaining = pos;
        var num_child_bytes: usize = undefined;
        node: while (node.tag == .Branch) {
            const branch = Branch.fromNode(node);
            const num_children = branch.num_children.*;
            const num_bytes = branch.num_bytes;
            var child_ix: usize = 0;
            while (true) {
                num_child_bytes = num_bytes[child_ix];
                if (pos_remaining < num_child_bytes or (which == .Earliest and pos_remaining == num_child_bytes)) {
                    node = branch.children[child_ix];
                    continue :node;
                }
                pos_remaining -= num_child_bytes;
                child_ix += 1;
                if (child_ix == num_children) {
                    node = branch.children[child_ix - 1];
                    continue :node;
                }
            }
        }
        return if (pos_remaining > num_child_bytes)
            null
        else
            .{
                .leaf = Leaf.fromNode(node),
                .offset = @intCast(Leaf.Offset, pos_remaining),
            };
    }

    pub fn insert(self: *Tree, start: usize, _bytes: []const u8) void {
        var arena = ArenaAllocator.init(self.allocator);
        defer arena.deinit();

        // find start point
        var point = self.getPointForPos(start, .Earliest).?;

        // make a stack of bytes to insert
        var bytes_stack = ArrayList([]const u8).initCapacity(&arena.allocator, 2) catch oom();
        bytes_stack.append(_bytes) catch oom();

        while (bytes_stack.popOrNull()) |bytes| {
            const leaf_child_ix = point.leaf.node.findInParent();
            const num_leaf_bytes = point.leaf.node.getParent().?.num_bytes[leaf_child_ix];

            if (bytes.len < point.leaf.bytes.len - num_leaf_bytes) {
                // insert in this leaf
                std.mem.copyBackwards(
                    u8,
                    point.leaf.bytes[point.offset + bytes.len .. num_leaf_bytes + bytes.len],
                    point.leaf.bytes[point.offset..num_leaf_bytes],
                );
                std.mem.copy(
                    u8,
                    point.leaf.bytes[point.offset .. point.offset + bytes.len],
                    bytes,
                );
                point.leaf.node.getParent().?.num_bytes[leaf_child_ix] = num_leaf_bytes + bytes.len;
            } else {
                // copy bytes after point onto the insert stack
                const new_bytes = std.mem.dupe(&arena.allocator, u8, point.leaf.bytes[point.offset..num_leaf_bytes]) catch oom();
                bytes_stack.append(new_bytes) catch oom();

                // insert what we can in this leaf
                const num_insert_bytes = min(point.leaf.bytes.len - point.offset, bytes.len);
                std.mem.copy(
                    u8,
                    point.leaf.bytes,
                    bytes[0..num_insert_bytes],
                );
                point.leaf.node.getParent().?.num_bytes[leaf_child_ix] = point.leaf.bytes.len;

                // push any remaining bytes back onto insert stack
                if (num_insert_bytes < bytes.len) {
                    bytes_stack.append(bytes[num_insert_bytes..]) catch oom();
                }

                // insert a new leaf somewhere and start there in the next loop iteration
                const new_leaf = self.insertLeaf(point);
                point = .{ .leaf = new_leaf, .offset = 0 };
            }
        }
    }

    fn insertLeaf(self: *Tree, point: Point) Leaf {
        const new_leaf = Leaf.init(self.allocator);
        var node = new_leaf.node;
        var num_bytes: usize = 0;
        var child_ix = point.leaf.node.findInParent();
        var branch = point.leaf.node.getParent().?;
        while (true) {
            if (branch.num_children.* < branch.children.len) {
                // insert node
                branch.insertChild(child_ix + 1, node, num_bytes);
                break;
            } else {
                // split off a new branch
                const new_branch = Branch.init(self.allocator);
                const split_point = @divTrunc(Branch.max_children, 2);
                std.mem.copy(
                    *Node,
                    new_branch.children,
                    branch.children[split_point..],
                );
                std.mem.copy(
                    usize,
                    new_branch.num_bytes,
                    branch.num_bytes[split_point..],
                );
                new_branch.num_children.* = branch.num_children.* - split_point;
                branch.num_children.* = split_point;

                // insert node
                if (child_ix < split_point)
                    branch.insertChild(child_ix + 1, node, num_bytes)
                else
                    new_branch.insertChild(child_ix - split_point + 1, node, num_bytes);

                // update branch parent
                if (branch.node.getParent()) |parent| {
                    parent.num_bytes[parent.findChild(branch.node)] = branch.getNumBytes();
                }

                if (branch.node.getParent()) |parent| {
                    // if have parent, insert new_branch into parent in next loop iteration
                    node = new_branch.node;
                    num_bytes = new_branch.getNumBytes();
                    child_ix = branch.node.findInParent();
                    branch = parent;
                    continue;
                } else {
                    // if no parent, make one and insert branch and new_branch
                    const new_parent = Branch.init(self.allocator);
                    self.root = new_parent;
                    new_parent.insertChild(0, branch.node, branch.getNumBytes());
                    new_parent.insertChild(1, new_branch.node, new_branch.getNumBytes());
                    break;
                }
            }
        }
        return new_leaf;
    }

    fn getDepth(self: *Tree) usize {
        var depth: usize = 0;
        var node = self.root.node;
        while (node.tag == .Branch) {
            depth += 1;
            node = Branch.fromNode(node).children[0];
        }
        return depth;
    }

    fn debugInto(self: *Tree, output: *ArrayList(u8)) void {
        self.root.debugInto(output, 0, 0);
    }
};

test "tree insert" {
    // TODO deinit
    var arena = ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var tree = Tree.init(&arena.allocator);
    tree.insert(0, @embedFile("/home/jamie/huge.js"));
    var output = ArrayList(u8).init(&arena.allocator);
    tree.debugInto(&output);
    std.debug.print("\n{}", .{output.items});
    dump(tree.getDepth());
}
