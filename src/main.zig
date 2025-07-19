const std = @import("std");
const Allocator = std.mem.Allocator;

const paths = @import("./paths.zig");

var gpa = std.heap.GeneralPurposeAllocator(.{}){};


const FSError = error{ NoEnt, InvalidPath, Exists };





test "union stuff" {
    const oh = try gpa.allocator().create(OpenHandle);

    oh.* = OpenHandle{
        .file = OpenFile{ .inode = 100 },
    };

    // yes this looks dumb i'm just learning. making sure unions don't have any
    // funky behaviour.

    try std.testing.expect(oh.*.file.inode == 100);
    oh.*.file.inode = 200;
    try std.testing.expect(oh.*.file.inode == 200);

    switch (oh.*) {
        .file => |*value| try std.testing.expect(value.*.inode == 200),
        .dir => unreachable,
    }

    oh.* = OpenHandle{
        .dir = OpenDir{ .inode = 300 },
    };
    try std.testing.expect(oh.*.dir.inode == 300);

    switch (oh.*) {
        .file => unreachable,
        .dir => |*value| try std.testing.expect(value.*.inode == 300),
    }
}


const FileSystem = struct {
    allocator: Allocator,
    blk_dev: *BlockDevice,
    blk_size: u32,
    free_list: FreeList,
    root_dir_blk: u32,
    blk_pool: BlockPool,
    dir_end: u32,

    open_files: std.HashMap(Fd, OpenHandle, foo, 90);
    // deep threshold
    // open files (map)
    // fs (map)

    //
    // Types
    
    //
    //

    pub fn init(allocator: Allocator, blk_dev: *BlockDevice) !FileSystem {
        var fl = try FreeList.init(allocator, blk_dev, 1);

        return FileSystem{
            .allocator = allocator, // force NL
            .blk_dev = blk_dev,
            .blk_size = blk_dev.blk_size,
            .free_list = fl,
            .root_dir_blk = fl.endBlock(),
            .blk_pool = BlockPool.init(allocator, blk_dev.blk_size),
            .dir_end = blk_dev.blk_size - dir_ent_size,
            .open_files = @FieldType(@This(), "open_files").init(gpa.allocator()),
        };
    }

    pub fn format(a: Allocator, blk_dev: *BlockDevice) !void {
        const end = try FreeList.create(a, blk_dev, 1);
        try blk_dev.zeroBlock(end);
    }

    //
    // Public Interface

    pub fn mkDir(self: *@This(), path: []const u8) !void {
        if (paths.isRoot(path)) {
            return FSError.Exists;
        }

        const dirname = paths.dirname(path);
        var ent: DirEnt = {};
        var dir = self.root_dir_blk;
        var iter = paths.PathComponentIterator.init(dirname);
        while (iter.next()) |cmp| {
            switch (try self.findEntryInDir(&ent, dir, cmp)) {
                .found => |_| {
                    dir = ent.dataInode;
                },
                .not_found => |_| {
                    return FSError.NoEnt;
                },
            }
        }

        const file = paths.basename(path).?;

        const ref = try self.findEntryInDir(&ent, dir, file);
        switch (ref) {
            .found => |_| {
                return FSError.Exists;
            },
            .not_found => |_| {
                // TODO: handle this error correctly
                const new_dir_blk = try self.free_list.alloc();
                try self.blk_dev.zeroBlock(new_dir_blk);
                @memcpy(ent.name, file);
                ent.dataInode = @truncate(new_dir_blk);
                ent.metaInode = 0;
                ent.modified = self.now();
                ent.size = 0;
                ent.flags = FlagDir;
                try self.insertDirEnt(dir, &ent);
                // TODO: need to increase size of parent block
            },
        }

        return;
    }

    pub fn rmDir(self: *@This(), path: []const u8) !void {}

    pub fn openDir(self: *@This(), path: []const u8) !Fd {}

    pub fn closeDir(self: *@This(), fd: Fd) !void {}

    pub fn readDir(self: *@This(), dst: *DirEnt, fd: Fd) !void {}

    //
    //

    // // find the directory entry represented by the given path from the root directory.
    // // path is assumed to be a valid path.
    // // returns an error if path is the root directory.
    // fn findEntForPath(self: *FileSystem, path: []const u8) !?EntRef {
    //     if (paths.isRoot(path)) {
    //         return FSError.InvalidPath;
    //     }
    // }

    // fn countEntriesInDir(self: *FileSystem, dir_blk: u32) !u32 {}

    fn findEntryInDir(self: *FileSystem, dst: *DirEnt, dir_blk: u32, name: []const u8) !FindEntryResult {
        var result = FindEntryResult{ .try_next_block = dir_blk };
        while (true) {
            switch (try self.findEntryInBlock(dst, result.try_next_block, name)) {
                .try_next_block => |blk| result = FindEntryResult{ .try_next_block = blk },
                else => return result,
            }
        }
    }

    fn findFreeSlotInDir(self: *FileSystem, block: u32) !FindEntryResult {
        var record = DirEnt{};
        return self.findEntryInDir(&record, block, []u8{});
    }

    fn findEntryInBlock(self: *FileSystem, dst: *DirEnt, block: u32, name: []const u8) !FindEntryResult {
        const blk = try self.blk_pool.take();
        defer self.blk_pool.give(blk);

        try self.blk_dev.readBlock(blk, block);

        const end = self.blk_size - dir_ent_size;
        var rp: u32 = 0;
        while (rp < end) : (rp += dir_ent_size) {
            readDirEnt(dst, blk[rp .. rp + dir_ent_size]);
            if (std.mem.eql(u8, name, dst.*.name)) {
                return FindEntryResult{ .found = EntRef{
                    .blk = block,
                    .offset = rp,
                } };
            }
        }

        const next_block = readBigEndian(u16, blk[rp .. rp + 2]);
        return if (next_block == 0) {
            FindEntryResult{ .not_found = block };
        } else {
            FindEntryResult{ .try_next_block = next_block };
        };
    }

    // EntRef is a block:offset pointer to a directory entry
    const EntRef = struct {
        blk: u32,
        offset: u32,
    };



    //
    //

    // Insert the given directory entry into the first free slot in the directory
    // rooted at dir_root_blk, allocating an additional block if necessary.
    // ent is not checked for validity, including checks for conflicting filenames.
    // Such checks must be handled elsewhere.
    fn insertDirEnt(self: *@This(), dir_root_blk: u32, ent: *DirEnt) !EntRef {
        var scratch = try self.blk_pool.take();
        defer self.blk_pool.give(scratch);

        var blk = dir_root_blk;
        while (true) {
            try self.blk_dev.readBlock(scratch, blk);

            var off: u32 = 0;
            while (off < self.dir_end) {
                if (scratch[off] == 0) {
                    writeDirEnt(scratch[off .. off + dir_ent_size], ent);
                    try self.blk_dev.writeBlock(blk, scratch);
                    return EntRef{ .blk = blk, .offset = off };
                }
                off += dir_ent_size;
            }

            const cp = readContinuationPtr(scratch);
            if (cp == 0) {
                break;
            }

            blk = cp;
            off = 0;
        }

        // we've hit the end of the directory so we need to add another block
        // allocate a new block and write the directory entry
        const new_blk = try self.free_list.alloc();

        const new_blk_scratch = try self.blk_pool.take();
        defer self.blk_pool.give(new_blk_scratch);
        @memset(new_blk_scratch, 0);

        writeDirEnt(new_blk_scratch[0..dir_ent_size], ent);
        try self.blk_dev.writeBlock(new_blk, new_blk_scratch);

        // now set up the continuation pointer
        writeContinuationPtr(scratch, @truncate(new_blk));
        try self.blk_dev.writeBlock(blk, scratch);

        // return reference to new block
        return EntRef{ .blk = new_blk, .offset = 0 };
    }

    // Remove the specified entry from a directory. If this operation leaves the directory
    // empty, and prev_block is provided, the block will be removed and re-inserted into
    // the freelist.
    fn removeDirEnt(self: *@This(), ref: EntRef, prev_block: ?u32) !void {
        const scratch = try self.blk_pool.take();
        defer self.blk_pool.give(scratch);

        try self.blk_dev.readBlock(scratch, ref.blk);
        @memset(scratch[ref.offset .. ref.offset + dir_ent_size], 0);

        if (prev_block != null and self.isDirectoryBlockEmpty(scratch)) {
            const cp = readContinuationPtr(scratch);
            try self.blk_dev.readBlock(scratch, prev_block.?);
            writeContinuationPtr(scratch, cp);
            try self.blk_dev.writeBlock(prev_block.?, scratch);
            try self.free_list.free(ref.blk);
        } else {
            try self.blk_dev.writeBlock(ref.blk, scratch);
        }
    }

    // Compact a directory by eliminating gaps between entries, freeing any blocks
    // that become empty.
    fn compactDir(self: @This(), dir_root_blk: u32) !void {}

    //
    // Directory iteration

    fn makeCursor(self: *FileSystem, dir_root_blk: u32) !DirCursor {
        const scratch = try self.blk_pool.take();
        try self.blk_dev.readBlock(scratch, dir_root_blk);
        return DirCursor.init(dir_root_blk, scratch);
    }

    fn destroyCursor(self: *FileSystem, iter: *DirCursor) void {
        self.blk_pool.give(iter.*.scratch);
    }

    fn cursorNext(self: *FileSystem, dst: ?*DirEnt, iter: *DirCursor) !?EntRef {
        while (true) {
            if (iter.offset == self.dir_end) {
                const next_block = readBigEndian(u16, iter.scratch[self.dir_end .. self.dir_end + 2]);
                if (next_block == 0) {
                    return null;
                } else {
                    try self.blk_dev.readBlock(iter.scratch, next_block);
                    iter.blk = next_block;
                    iter.offset = 0;
                }
            }

            if (iter.scratch[iter.offset] == 0) {
                iter.offset += dir_ent_size;
            } else {
                if (dst != null) {
                    readDirEnt(dst.?, iter.scratch[iter.offset .. iter.offset + dir_ent_size]);
                }
                const out = EntRef{ .blk = iter.blk, .offset = iter.offset };
                iter.offset += dir_ent_size;
                return out;
            }
        }
    }

    const DirCursor = struct {
        root_blk: u32,
        scratch: []u8,
        blk: u32,
        offset: u32,

        pub fn init(root_blk: u32, scratch: []u8) DirCursor {
            return DirCursor{
                .root_blk = root_blk,
                .scratch = scratch,
                .blk = root_blk,
                .offset = 0,
            };
        }
    };

    //
    // Helpers

    fn isDirectoryBlockEmpty(self: *@This(), blk_data: []const u8) bool {
        var rp: u32 = 0;
        while (rp < self.dir_end) : (rp += dir_ent_size) {
            if (blk_data[rp] != 0) {
                return false;
            }
        }
        return true;
    }

    fn now(self: *@This()) u32 {
        return 0;
    }

    fn getOpenDir(fd: Fd) ?*OpenDir{

    }
};

//
// Helpers

//

fn runTest(name: []const u8, blk_size: u32, blk_count: u32, cb: fn (*FileSystem) anyerror!void) !void {
    const bd = try newBlockDevice(blk_size, blk_count);
    try FileSystem.format(gpa.allocator(), bd);
    var fs = try FileSystem.init(gpa.allocator(), bd);

    std.debug.print("@begin {s}\n", .{name});
    try cb(&fs);
    std.debug.print("@end\n\n", .{name});
}

fn emptyDirectoryIteration(fs: *FileSystem) !void {
    var count: usize = 0;
    var iter = try fs.makeCursor(fs.root_dir_blk);
    defer fs.destroyCursor(&iter);
    while (true) {
        if (try fs.cursorNext(null, &iter)) |ent| {
            count += 1;
            std.debug.print("cursor {}:{}\n", .{ ent.blk, ent.offset });
        } else {
            break;
        }
    }

    std.debug.print("Number of files in root: {}\n", .{count});
}

pub fn main() !void {
    try runTest("emptyDirectoryIteration", 64, 64, emptyDirectoryIteration);
}
