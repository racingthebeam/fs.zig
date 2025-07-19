const std = @import("std");
const Allocator = std.mem.Allocator;

const paths = @import("paths.zig");
const bd = @import("block_device.zig");
const FreeList = @import("free_list.zig").FreeList;
const BlockPool = @import("block_pool.zig").BlockPool;

const entry = @import("entry.zig");

const readBE = @import("util.zig").readBE;
const writeBE = @import("util.zig").writeBE;

const FSError = error{ NoEnt, InvalidOffset, FileSizeLimitReached };

const common = @import("common.zig");
const BlockPtrSize = common.BlockPtrSize;
const Ref = common.Ref;
const OpenFlags = common.OpenFlags;
const PublicErrors = common.Errors;
const OpenFile = common.OpenFile;
const OpenDir = common.OpenDir;
const Hnd = common.Hnd;
const FileFd = common.FileFd;
const DirFd = common.DirFd;

const Seq = @import("seq.zig").Seq;

const fds = @import("fd.zig");

pub const FileSystem = struct {
    const openFiles = std.AutoHashMap(common.INode, *OpenFile);
    const openDirs = std.AutoHashMap(common.INode, *OpenDir);

    allocator: Allocator,
    blk_dev: *bd.BlockDevice,

    free_list: FreeList,
    blk_pool: BlockPool,
    open_files: openFiles,
    open_dirs: openDirs,
    seq: Seq,
    file_fds: fds.FileFds,
    dir_fds: fds.DirFds,

    blk_size: u32, // cached block size
    root_dir_blk: u32, // cached block of root directory index
    pointers_per_block: u32, // number of file pointers that can be stored in one block
    indirect_offset_threshold: u32, // absolute file offset >= which we need to use indirect addressing
    dir_end: u32,

    pub fn format(allocator: Allocator, blk_dev: *bd.BlockDevice) !void {
        const end = try FreeList.create(allocator, blk_dev, 1);
        blk_dev.zeroBlock(end);
    }

    pub fn init(allocator: Allocator, blk_dev: *bd.BlockDevice) !FileSystem {
        var fl = try FreeList.init(allocator, blk_dev, 1);
        errdefer fl.deinit();

        var out = FileSystem{
            .allocator = allocator,
            .blk_dev = blk_dev,

            .free_list = fl,
            .blk_pool = BlockPool.init(allocator, blk_dev.blk_size),
            .open_files = FileSystem.openFiles.init(allocator),
            .open_dirs = FileSystem.openDirs.init(allocator),
            .seq = Seq{},
            .file_fds = undefined,
            .dir_fds = undefined,

            .blk_size = blk_dev.blk_size,
            .root_dir_blk = fl.endBlock(),
            .pointers_per_block = blk_dev.blk_size / common.BlockPtrSize,
            .indirect_offset_threshold = (blk_dev.blk_size / 4) * blk_dev.blk_size,
            .dir_end = blk_dev.blk_size - entry.DirEntSize,
        };

        out.file_fds = fds.FileFds.init(allocator, &out.seq);
        out.dir_fds = fds.DirFds.init(allocator, &out.seq);

        return out;
    }

    pub fn deinit(self: *@This()) void {
        self.free_list.deinit();
        self.blk_pool.deinit();
        self.open_files.deinit();
        self.open_dirs.deinit();
        self.file_fds.deinit();
        self.dir_fds.deinit();
    }

    //
    // Public Interface

    pub fn unlink(self: *@This(), inode: u32, filename: []const u8) !void {
        var ent = entry.DirEntRef{};
        try self.findEntryInDir(&ent, inode, filename);

        if (ent.ent.isDir()) {
            return PublicErrors.IsDir;
        }

        try self.zeroDirEnt(ent.ref);

        const data_blk = ent.ent.data_inode;
        if (self.getOpenFile(data_blk)) |of| {
            of.deleted = true;
        } else {
            try self.purgeFile(data_blk, true);
        }
    }

    pub fn closeFile(self: *@This(), hnd: common.Hnd) !void {
        const fd = self.file_fds.get(hnd) orelse {
            return PublicErrors.InvalidHandle;
        };

        const of = fd.*.file;

        self.file_fds.delete(hnd);

        of.*.ref_count -= 1;
        if (of.*.ref_count == 0) {
            const root_blk = of.*.root_blk;
            if (of.*.deleted) {
                self.purgeFile(root_blk, true);
            }
            self.open_files.remove(root_blk);
            self.allocator.destroy(of);
        }
    }

    pub fn open(self: *@This(), inode: u32, filename: []const u8, flags: u32) !u32 {
        var ent = entry.DirEntRef{};
        if (self.findEntryInDir(&ent, inode, filename)) {
            return self.openExistingFile(inode, &ent, flags);
        } else {
            return self.openNewFile(inode, filename, flags);
        }
    }

    fn openExistingFile(self: *@This(), inode: u32, ent: *entry.DirEntRef, flags: u32) !u32 {
        if (ent.*.ent.isDir()) {
            return PublicErrors.IsDir;
        }

        if (ent.ent.isDir()) {
            return PublicErrors.IsDir;
        } else {
            var fd = try self.allocator.create(FileFd);
            errdefer self.allocator.destroy(fd);

            var of = self.getOpenFile(inode) orelse {
                const new_of = try self.allocator.create(OpenFile);
                new_of.* = OpenFile{
                    .root_blk = inode,
                    .size = ent.ent.size,
                };
                new_of;
            };

            fd.* = FileFd{ .file = 100 };
        }
    }

    fn openNewFile(self: *@This(), inode: u32, filename: []const u8, flags: u32) !u32 {}

    pub fn eof(self: *@This(), fh: u32) !bool {
        const fd = try self.getFileFd(fh);
        return fd.abs_offset == fd.file.size;
    }

    pub fn read(self: *@This(), dst: []u8, fh: u32) !u32 {
        const fd = try self.getFileFd(fh);
        const of = fd.file;

        // TODO: check file is readable

        const scratch = self.blk_pool.take();
        defer self.blk_pool.give(scratch);

        const bytes_to_read: u32 = @min(dst.len, of.size - fd.abs_offset);
        var bytes_read: u32 = 0;
        while (bytes_read < bytes_to_read) {
            const bytes_remaining = bytes_to_read - bytes_read;
            const bytes_to_read_from_blk: u32 = @min(bytes_remaining, self.blk_size - fd.data.offset);

            try self.blk_dev.readBlock(scratch, fd.data.blk);
            @memcpy(dst[bytes_read .. bytes_read + bytes_to_read_from_blk], scratch[fd.data.offset .. fd.data.offset + bytes_to_read_from_blk]);

            fd.abs_offset += bytes_to_read_from_blk;
            fd.data.offset += bytes_to_read_from_blk;
            bytes_read += bytes_to_read_from_blk;

            if (fd.data.offset == self.blk_size) {
                try self.advanceFilePointer(fd);
            }
        }

        return bytes_read;
    }

    pub fn write(self: *@This(), fh: u32, buf: []u8) !u32 {
        const fd = try self.getFileFd(fh);

        // TODO: check file is writable

        const scratch = self.blk_pool.take();
        defer self.blk_pool.give(scratch);

        const bytes_to_write = buf.len;
        var bytes_written: u32 = 0;
        while (bytes_written < bytes_to_write) {
            const bytes_remaining = bytes_to_write - bytes_written;
            const bytes_to_write_to_blk = @min(bytes_remaining, self.blk_size - fd.data.offset);

            try self.blk_dev.readBlock(scratch, fd.data.blk);
            @memcpy(scratch[fd.data.offset .. fd.data.offset + bytes_to_write_to_blk], buf[bytes_written .. bytes_written + bytes_to_write_to_blk]);
            self.blk_dev.writeBlock(fd.data.blk, scratch);

            fd.abs_offset += bytes_to_write_to_blk;
            fd.data.offset += bytes_to_write_to_blk;
            bytes_written += bytes_to_write_to_blk;

            if (fd.data.offset == self.blk_size) {
                try self.advanceFilePointer(fd);
            }
        }

        if (fd.abs_offset > fd.file.size) {
            fd.file.size = fd.abs_offset;
            // TODO: write back directory entry?
        }

        return bytes_written;
    }

    //
    // Internals

    // free all blocks used by the directory whose index is rooted at index_blk.
    // it is assumed the directory is empty - no files will be freed.
    // returns the number of blocks freed.
    fn purgeDir(self: *@This(), index_blk: u32) u32 {
        const scratch = self.blk_pool.take();
        defer self.blk_pool.give(scratch);

        var freed = 0;
        var blk = index_blk;
        while (blk != 0) {
            self.blk_dev.readBlock(scratch, blk) catch @panic("no block");
            self.free_list.free(blk) catch @panic("no block");
            freed += 1;
            blk = entry.readContinuationPtr(scratch);
        }

        return freed;
    }

    // free all blocks used by the file whose index is rooted at index_blk,
    // including the index block itself.
    // returns the number of blocks freed.
    fn purgeFile(self: *@This(), index_blk: u32, free_root_blk: bool) u32 {
        const index_dat = self.blk_pool.take();
        defer self.blk_pool.give(index_dat);

        const l2_dat = self.blk_pool.take();
        defer self.blk_pool.give(l2_dat);

        self.blk_dev.readBlock(index_dat, index_blk) catch @panic("no block");
        var freed = self.freeReferencedBlocks(index_dat[0..(self.blk_size / 2)]);

        var i = self.indirect_offset_threshold;
        while (i < self.blk_size) : (i += 2) {
            const pointee = readBE(u16, index_dat[i .. i + 2]);
            if (pointee == 0) {
                continue;
            }

            self.blk_dev.readBlock(l2_dat, pointee) catch @panic("no block");
            freed += self.freeReferencedBlocks(l2_dat);

            self.free_list.free(pointee) catch @panic("no block");
            freed += 1;
        }

        if (free_root_blk) {
            self.free_list.free(index_blk) catch @panic("no block");
            freed += 1;
        }

        return freed;
    }

    // free all blocks referenced from blk_data, assuming blk_data is a
    // tightly-packed slice of block references.
    // returns the number of blocks freed.
    fn freeReferencedBlocks(self: *@This(), blk_data: []const u8) u32 {
        var freed: u32 = 0;
        var i = 0;
        while (i < blk_data.len) : (i += 2) {
            const pointee_blk = readBE(u16, blk_data[i .. i + 2]);
            if (pointee_blk == 0) {
                continue;
            }
            self.free_list.free(pointee_blk) catch @panic("no block");
            freed += 1;
        }
        return freed;
    }

    // Given a file descriptor whose data offset is pointing to the end of its
    // current data block, adjust it so that it is pointing to the start of the
    // data block containing the data immediately following, allocating a new
    // block if necessary, taking care of indirection as necessary.
    fn advanceFilePointer(self: *@This(), fd: *FileFd) !void {
        if (fd.data.offset != self.blk_size) {
            @panic("advanceFilePointer() called when data offset != block size");
        }

        var target_blk: u32 = 0;

        if (!fd.deep) {
            // root index offset at which we start using indirect addressing
            const indirect_threshold = self.blk_size / 2;
            if ((fd.root.offset + 2) < indirect_threshold) {
                target_blk = try self.simpleIncrement(&fd.root);
            } else {
                target_blk = try self.indirectIncrement(fd);
                fd.*.deep = true;
            }
        } else {
            if ((fd.mid.offset + 2) < self.blk_size) {
                target_blk = try self.simpleIncrement(&fd.mid);
            } else {
                target_blk = try self.indirectIncrement(fd);
            }
        }

        fd.*.data = Ref{ .blk = target_blk, .offset = 0 };
    }

    // Advances the given Ref by 2 bytes (the size of a block pointer).
    // If the pointer found at the updated Ref is zero, a new block is allocated, zeroed, and
    // the pointer is updated to point to this new block.
    //
    // Returns the address of the block that is pointed to.
    fn simpleIncrement(self: *@This(), ent: *Ref) !u32 {
        const scratch = self.blk_pool.take();
        defer self.blk_pool.give(scratch);

        try self.blk_dev.readBlock(scratch, ent.blk);

        const next_offset = ent.offset + 2;
        var target_blk = readBE(u16, scratch[next_offset .. next_offset + 2]);
        if (target_blk == 0) {
            const new_blk = try self.alloc();
            writeBE(u16, scratch[next_offset .. next_offset + 2], new_blk);
            self.blk_dev.writeBlock(ent.blk, scratch);
            target_blk = new_blk;
        }

        ent.*.offset = next_offset;

        return target_blk;
    }

    fn indirectIncrement(self: *@This(), fd: *FileFd) !u32 {
        const next_root_offset = fd.root.offset + 2;

        if (next_root_offset == self.blk_size) {
            return FSError.FileSizeLimitReached;
        }

        const tmp_data = self.blk_pool.take();
        defer self.blk_pool.give(tmp_data);
        try self.blk_dev.readBlock(tmp_data, fd.root.blk);
        const next_mid_blk = readBE(u16, tmp_data[next_root_offset .. next_root_offset + 2]);

        if (next_mid_blk == 0) {
            // if there's no indirect block, we need to allocate one (plus a data block)

            const mid_blk_data = try self.blk_pool.take();
            defer self.blk_pool.give(mid_blk_data);

            const blks = try self.alloc2();

            writeBE(u16, tmp_data[next_root_offset .. next_root_offset + 2], blks[0]);
            writeBE(u16, mid_blk_data[0..2], blks[1]);

            self.blk_dev.writeBlock(blks[0], mid_blk_data);
            self.blk_dev.writeBlock(fd.root.blk, tmp_data);

            fd.root.offset = next_root_offset;
            fd.mid = Ref{ .blk = blks[0], .offset = 0 };

            return blks[1];
        } else {
            // indirect block already present - pluck the next data block from its
            // first entry.

            try self.blk_dev.readBlock(tmp_data, next_mid_blk);
            const next_data_blk = readBE(u16, tmp_data[0..2]);

            fd.root.offset = next_root_offset;
            fd.mid = Ref{ .blk = next_mid_blk, .offset = 0 };

            return next_data_blk;
        }
    }

    // Zero the directory entry pointed to by ref and write the block
    fn zeroDirEnt(self: *@This(), ref: Ref) !void {
        var scratch = self.blk_pool.take();
        defer self.blk_pool.give(scratch);

        try self.blk_dev.readBlock(scratch, ref.blk);
        @memset(scratch[ref.offset .. ref.offset + entry.DirEntSize], 0);
        self.blk_dev.writeBlock(ref.blk, scratch);
    }

    //
    // Finding

    // Find the directory rooted at path, returning the first block of the index, or
    // null if the path was not found/was not a directory.
    //
    // On success, dst will be populated with the ref/entry that points to the
    // directory's contents, UNLESS path is the root directory. It
    // is the caller's responsibility to detect the root directory and act
    // appropriately.
    fn findDir(self: *@This(), dst: *entry.DirEntRef, path: []const u8) ?u32 {
        if (paths.isRoot(path)) {
            return self.root_dir_blk;
        }

        var dir = self.root_dir_blk;
        var iter = paths.PathComponentIterator.init(path);
        while (iter.next()) |cmp| {
            if (try self.findEntryInDir(dst, dir, cmp) and dst.ent.isDirectory()) {
                dir = dst.ent.data_inode;
            } else {
                return null;
            }
        }

        return dir;
    }

    fn findEntryInDir(self: *@This(), ent: *entry.DirEntRef, blk: u32, name: []const u8) !void {
        var cursor = try self.makeCursor(blk);
        defer self.destroyCursor(&cursor);

        while (try self.cursorNext(ent, &cursor)) {
            if (ent.isName(name)) {
                return;
            }
        }

        return PublicErrors.NoEnt;
    }

    //
    // Seek

    fn seek(self: *@This(), of: *OpenFile, fd: *FileFd, abs_offset: u32) !void {
        if (abs_offset > of.*.size) {
            return FSError.InvalidOffset;
        }

        if (abs_offset < self.indirect_offset_threshold) {
            try self.seekShallow(of, fd, abs_offset);
        } else {
            try self.seekDeep(of, fd, abs_offset);
        }

        fd.*.abs_offset = abs_offset;
    }

    fn seekShallow(self: *@This(), of: *OpenFile, fd: *FileFd, abs_offset: u32) !void {
        const scratch = self.blk_pool.take();
        defer self.blk_pool.give(scratch);

        const offsets = self.calculateShallowOffsets(abs_offset);

        const root = Ref{
            .blk = of.*.root_blk,
            .offset = offsets[0],
        };

        try self.blk_dev.readBlock(scratch, root.blk);

        fd.*.deep = false;
        fd.*.root = root;
        fd.*.data = Ref{
            .blk = readBE(u16, scratch[root.offset .. root.offset + BlockPtrSize]),
            .offset = offsets[1],
        };
    }

    fn seekDeep(self: *@This(), of: *OpenFile, fd: *FileFd, abs_offset: u32) !void {
        const scratch = self.blk_pool.take();
        defer self.blk_pool.give(scratch);

        const offsets = self.calculateDeepOffsets(abs_offset);

        const root = Ref{
            .blk = of.*.root_blk,
            .offset = offsets[0],
        };

        try self.blk_dev.readBlock(scratch, root.blk);

        const indirect = Ref{
            .blk = readBE(u16, scratch[root.offset .. root.offset + BlockPtrSize]),
            .offset = offsets[1],
        };

        try self.blk_dev.readBlock(scratch, indirect.blk);

        fd.*.deep = true;
        fd.*.root = root;
        fd.*.mid = indirect;
        fd.*.data = Ref{
            .blk = readBE(u16, scratch[indirect.offset .. indirect.offset + BlockPtrSize]),
            .offset = offsets[2],
        };
    }

    fn calculateShallowOffsets(self: @This(), abs_offset: u32) struct { u32, u32 } {
        return .{
            (abs_offset / self.blk_size) * BlockPtrSize,
            abs_offset % self.blk_size,
        };
    }

    fn calculateDeepOffsets(self: @This(), abs_offset: u32) struct { u32, u32, u32 } {
        const rel_offset = abs_offset - self.indirect_offset_threshold;
        const bytes_per_indirect_block = self.pointers_per_block * self.blk_size;
        const indirect_index = rel_offset / bytes_per_indirect_block;
        const root_offset = (self.blk_size / 2) + (indirect_index * BlockPtrSize);
        const indirect_offset = ((rel_offset % bytes_per_indirect_block) / self.blk_size) * BlockPtrSize;
        const data_offset = rel_offset % self.blk_size;
        return .{ root_offset, indirect_offset, data_offset };
    }

    //
    // Directory iteration

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

    fn makeCursor(self: *@This(), dir_root_blk: u32) !DirCursor {
        const scratch = self.blk_pool.take();
        try self.blk_dev.readBlock(scratch, dir_root_blk);
        return DirCursor.init(dir_root_blk, scratch);
    }

    fn destroyCursor(self: *@This(), iter: *DirCursor) void {
        self.blk_pool.give(iter.*.scratch);
    }

    fn cursorNext(self: *@This(), dst: *entry.DirEntRef, iter: *DirCursor) !bool {
        while (true) {
            if (iter.offset == self.dir_end) {
                const next_block = readBE(u16, entry.readContinuationPtr(iter.scratch));
                if (next_block == 0) {
                    return false;
                } else {
                    try self.blk_dev.readBlock(iter.scratch, next_block);
                    iter.blk = next_block;
                    iter.offset = 0;
                }
            }

            if (iter.scratch[iter.offset] == 0) {
                iter.offset += entry.DirEntSize;
            } else {
                dst.ref = Ref{ .blk = iter.blk, .offset = iter.offset };
                entry.readDirEnt(&dst.ent, iter.scratch[iter.offset .. iter.offset + entry.DirEntSize]);
                iter.offset += entry.DirEntSize;
                return true;
            }
        }
    }

    //
    // Open stuff

    fn getOpenFile(self: *@This(), inode: common.INode) ?*OpenFile {
        return self.open_files.get(inode);
    }

    fn getOpenDir(self: *@This(), inode: common.INode) ?*OpenDir {
        return self.open_dirs.get(inode);
    }

    fn getFileFd(_: @This(), _: common.Hnd) ?*FileFd {
        @panic("not implemented");
    }

    fn deleteFileFd(_: *@This(), _: common.Hnd) void {}

    fn getDirFd(_: @This(), _: common.Hnd) ?*DirFd {
        @panic("not implemented");
    }

    //
    //

    // allocate a block and zero it
    fn alloc(self: @This()) !u32 {
        const b = try self.free_list.alloc();
        self.blk_dev.zeroBlock(b);
        return b;
    }

    // allocate two blocks and zero them
    fn alloc2(self: *@This()) !struct { u32, u32 } {
        const b1 = try self.free_list.alloc();
        errdefer self.free_list.free(b1);
        const b2 = try self.free_list.alloc();
        self.blk_dev.zeroBlock(b1);
        self.blk_dev.zeroBlock(b2);
        return .{ b1, b2 };
    }
};
