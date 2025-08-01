// fs.zig - a simple filesystem on top of a memory-backed block store
// Copyright (C) 2025 rtb

// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.

// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

const std = @import("std");
const Allocator = std.mem.Allocator;

const bd = @import("block_device.zig");
const FreeList = @import("free_list.zig").FreeList;
const BlockPool = @import("block_pool.zig").BlockPool;
const InodeTable = @import("inode_table.zig").InodeTable;

const readBE = @import("util.zig").readBE;
const writeBE = @import("util.zig").writeBE;

const BLOCK_COUNT_MULTIPLIER = 8;

const P = @import("public.zig");
const I = @import("internal.zig");
const Ref = I.Ref;

const Seq = @import("seq.zig").Seq;

pub const FileSystem = struct {
    const OpenFiles = std.AutoHashMap(I.InodePtr, *I.OpenFile);
    const FileHandles = std.AutoHashMap(P.Fd, *I.FileFd);

    allocator: Allocator,
    blk_dev: *bd.BlockDevice,

    inodes: InodeTable,
    freelist: FreeList,
    blk_pool: BlockPool,

    // map of currently opened files, indexed by inode pointer.
    //
    // each *OpenFile value stores a cache of the "live state" of
    // an open file, as well as tracking deletion, so that
    // contents may be purged on close.
    //
    // any given file has at most one *OpenFile, regardless of
    // how many active file handles exist.
    open_file_state: OpenFiles,

    // open file handles, indexed by public handle
    open_files: FileHandles,

    // open directory handles, indexed by public handle
    // directories have separate lookup to ensure that arbitrary file
    // operations cannot be performed on open directories.
    open_dirs: FileHandles,

    // shared sequence number generator for file + directory handles
    seq: Seq,

    // cached block size
    blk_size: u32,

    // absolute file offset >= which we need to use indirect addressing
    indirect_offset_threshold: u32,

    // number of file pointers that can be stored in one block
    pointers_per_block: u32,

    pub fn format(allocator: Allocator, blk_dev: *bd.BlockDevice, inode_blk_count: u32, config_out: []u8) !void {
        if ((inode_blk_count % BLOCK_COUNT_MULTIPLIER != 0) or (config_out.len != 16)) {
            return P.Error.InvalidFSParams;
        }

        // create inode table, immediately followed by the freelist
        const inode_end = InodeTable.initialize(blk_dev, 1, inode_blk_count);
        const freelist_end = try FreeList.create(allocator, blk_dev, inode_end);

        // load the inode table and freelist we've just created so we can bootstrap the FS
        var inodes = try InodeTable.init(allocator, blk_dev, 1, inode_blk_count);
        var freelist = try FreeList.init(allocator, blk_dev, inode_end);
        defer inodes.deinit();
        defer freelist.deinit();

        // directories are stored as files so we need 2 blocks - one for the index table,
        // and another for the first data block. in the future we'll improve this so small
        // directories only take a single block
        const root_index_blk = try freelist.alloc();
        const root_data_blk = try freelist.alloc();
        std.debug.assert(root_index_blk == freelist_end);

        // root directory is empty so just zero its data block
        blk_dev.zeroBlock(root_data_blk);

        // set up the first entry of the root index to point to the empty data block
        var index = try allocator.alloc(u8, blk_dev.blk_size);
        defer allocator.free(index);
        @memset(index, 0);
        writeBE(u16, index[0..2], @truncate(root_data_blk));
        blk_dev.writeBlock(root_index_blk, index);

        // finally, allocate an inode, ensure it's zero, because the root directory is
        // always pointed to by inode zero.
        const root_inode = inodes.create(true, @truncate(root_index_blk)) orelse @panic("failed to create root inode");
        std.debug.assert(root_inode == 0);

        // Store the FS config in the output slice
        //
        // This data is in fact stored at the end of block 0, but because we also
        // store disk geometry, label, and version check there, direct access
        // to its contents is not permitted. Instead, we write the metadata to
        // an auxiliary slice and a higher level OOB process takes care of
        // writing the data to the block device.
        @memset(config_out, 0);
        config_out[0] = P.FS_TYPE_ID;
        config_out[1] = 1; // version
        config_out[2] = @truncate((inode_blk_count / BLOCK_COUNT_MULTIPLIER) - 1);
    }

    pub fn init(allocator: Allocator, blk_dev: *bd.BlockDevice, config: []u8) !FileSystem {
        if (config.len != 16 or config[0] != P.FS_TYPE_ID or config[1] != 1) {
            return P.Error.InvalidFSParams;
        }

        var inode_blk_count: u32 = config[2];
        inode_blk_count += 1;
        inode_blk_count *= BLOCK_COUNT_MULTIPLIER;

        var inodes = try InodeTable.init(allocator, blk_dev, 1, inode_blk_count);
        errdefer inodes.deinit();

        var freelist = try FreeList.init(allocator, blk_dev, inodes.end_blk);
        errdefer freelist.deinit();

        const out = FileSystem{
            .allocator = allocator,
            .blk_dev = blk_dev,

            .inodes = inodes,
            .freelist = freelist,
            .blk_pool = BlockPool.init(allocator, blk_dev.blk_size),
            .open_file_state = OpenFiles.init(allocator),
            .open_files = FileHandles.init(allocator),
            .open_dirs = FileHandles.init(allocator),
            .seq = Seq.init(),

            .blk_size = blk_dev.blk_size,
            .indirect_offset_threshold = (blk_dev.blk_size / 4) * blk_dev.blk_size,
            .pointers_per_block = blk_dev.blk_size / I.BlockPtrSize,
        };

        return out;
    }

    pub fn deinit(self: *@This()) void {
        self.inodes.deinit();
        self.freelist.deinit();
        self.blk_pool.deinit();
        self.open_file_state.deinit();
        self.open_files.deinit();
        self.open_dirs.deinit();
    }

    pub fn lookup(self: *@This(), dir_inode_ptr: P.InodePtr, filename: []const u8) !?P.InodePtr {
        try self.checkFilename(filename);

        var dir_fd = I.FileFd{};
        try self.openInternal(I.publicInodePtrToInternal(dir_inode_ptr), &dir_fd, true, 0);
        defer self.closeInternal(&dir_fd);

        const res = try self.findInode(&dir_fd, filename);
        if (res.inode) |inode| {
            return @enumFromInt(inode);
        } else {
            return null;
        }
    }

    pub fn exists(self: *@This(), dir_inode_ptr: P.InodePtr, filename: []const u8) !bool {
        try self.checkFilename(filename);

        return (try self.lookup(dir_inode_ptr, filename)) != null;
    }

    pub fn stat(self: *@This(), dst: *P.Stat, inode_ptr: P.InodePtr) !void {
        var inode = I.Inode{};
        if (!self.inodes.read(&inode, I.publicInodePtrToInternal(inode_ptr))) {
            return P.Error.NoEnt;
        }
        @memset(dst.filename[0..], 0);
        dst.inode = inode_ptr;
        dst.setFromInode(&inode);
    }

    pub fn open(self: *@This(), inode_ptr: P.InodePtr, flags: u32) !P.Fd {
        const file = self.allocator.create(I.FileFd) catch |err| I.oom(err);
        errdefer self.allocator.destroy(file);

        try self.openInternal(I.publicInodePtrToInternal(inode_ptr), file, false, flags);

        const fd = self.allocateFd();
        self.open_files.put(fd, file) catch |err| I.oom(err);

        return fd;
    }

    pub fn create(self: *@This(), dir_inode_ptr: P.InodePtr, filename: []const u8) !P.InodePtr {
        try self.checkFilename(filename);

        var dir_fd = I.FileFd{};
        try self.openInternal(I.publicInodePtrToInternal(dir_inode_ptr), &dir_fd, true, 0);
        defer self.closeInternal(&dir_fd);

        const res = try self.findInode(&dir_fd, filename);
        if (res.inode) |_| {
            return P.Error.Exists;
        }

        const inode_ptr = try self.createFile(false);
        errdefer self.purgeInode(inode_ptr);
        try self.insertDirEntry(&dir_fd, filename, inode_ptr, res.free_offset);

        return I.internalInodePtrToPublic(inode_ptr);
    }

    pub fn unlink(self: *@This(), dir_inode_ptr: P.InodePtr, filename: []const u8) !void {
        try self.checkFilename(filename);

        var dir_fd = I.FileFd{};
        try self.openInternal(I.publicInodePtrToInternal(dir_inode_ptr), &dir_fd, true, 0);
        defer self.closeInternal(&dir_fd);

        const res = try self.findInode(&dir_fd, filename);
        if (res.inode == null) {
            return P.Error.NoEnt;
        }

        const inode_ptr = res.inode.?;

        var inode = I.Inode{};
        if (!self.inodes.read(&inode, inode_ptr)) {
            @panic("failed to read inode in unlink() - this is a bug");
        } else if (inode.isDir()) {
            return P.Error.IsDir;
        }

        // this is slightly bad behaviour
        // if we've found the inode, the file pointer must be immediately after the entry.
        // rewind it by one entry so we can zero it out.
        self.seekInternal(&dir_fd, dir_fd.abs_offset - I.DirEntSize) catch @panic("seek failed in unlink() - this is a bug");

        // now zero it
        const zeroes = [_]u8{0} ** I.DirEntSize;
        _ = self.writeInternal(&dir_fd, zeroes[0..16]) catch @panic("failed to zero dir entry in unlink() - this is a bug");

        if (self.open_file_state.get(inode_ptr)) |of| {
            of.deleted = true;
        } else {
            self.purgeInode(inode_ptr);
        }
    }

    pub fn read(self: *@This(), dst: []u8, fd: P.Fd) !struct { u32, bool } {
        const file = try self.get_open_file(fd);
        return self.readInternal(dst, file);
    }

    pub fn write(self: *@This(), fd: P.Fd, src: []u8) !u32 {
        const file = try self.get_open_file(fd);
        return self.writeInternal(file, src);
    }

    pub fn close(self: *@This(), fd: P.Fd) !void {
        const pair = self.open_files.fetchRemove(fd) orelse return P.Error.InvalidFileHandle;
        self.closeInternal(pair.value);
        self.allocator.destroy(pair.value);
    }

    pub fn tell(self: *@This(), fd: P.Fd) !u32 {
        const file = try self.get_open_file(fd);
        return file.abs_offset;
    }

    pub fn statfd(self: *@This(), dst: *P.Stat, fd: P.Fd) !void {
        const file = try self.get_open_file(fd);
        const inode_ptr = file.of.inode_ptr;

        var inode = I.Inode{};
        if (!self.inodes.read(&inode, inode_ptr)) {
            return P.Error.NoEnt;
        }

        @memset(dst.filename[0..], 0);
        dst.inode = I.internalInodePtrToPublic(inode_ptr);
        dst.setFromInode(&inode);
    }

    pub fn eof(self: *@This(), fd: P.Fd) !bool {
        const file = try self.get_open_file(fd);
        return file.abs_offset == file.of.size;
    }

    pub fn seek(self: *@This(), fd: P.Fd, offset: i32, whence: P.Whence) !void {
        const file = try self.get_open_file(fd);

        const targetOffset: i64 = switch (whence) {
            P.Whence.Abs => offset,
            P.Whence.RelCurr => blk: {
                const currOffset: i64 = @intCast(file.abs_offset);
                break :blk currOffset + offset;
            },
            P.Whence.RelEnd => blk: {
                const fileSize: i64 = @intCast(file.of.size);
                break :blk fileSize + offset;
            },
        };

        // we just check the integer range here; seekInternal() handles
        // the quantitative validation of the offset.
        if (targetOffset < 0 or targetOffset > std.math.maxInt(u32)) {
            return P.Error.InvalidOffset;
        }

        try self.seekInternal(file, @intCast(targetOffset));
    }

    pub fn opendir(self: *@This(), inode_ptr: P.InodePtr) !P.Fd {
        const dir = self.allocator.create(I.FileFd) catch |err| I.oom(err);
        errdefer self.allocator.destroy(dir);
        try self.openInternal(I.publicInodePtrToInternal(inode_ptr), dir, true, 0);
        const fd = self.allocateFd();
        self.open_dirs.put(fd, dir) catch |err| I.oom(err);
        return fd;
    }

    pub fn closedir(self: *@This(), fd: P.Fd) !void {
        const dir = try self.get_open_dir(fd);
        const of = dir.of;
        self.allocator.destroy(dir);
        std.debug.assert(self.open_dirs.remove(fd));
        self.unref(of);
    }

    // read the next directory entry from the given directory handle into dst
    // returns true on success, false on EOF
    pub fn readdir(self: *@This(), dst: *P.Stat, fd: P.Fd) !bool {
        const file = try self.get_open_dir(fd);

        var ent = I.DirEnt{};
        const ok = try self.readDirInternal(&ent, file, false);
        if (!ok) {
            return false;
        }

        var inode = I.Inode{};
        if (!self.inodes.read(&inode, ent.inode)) {
            return P.Error.FatalInternalError;
        }

        @memcpy(&dst.filename, &ent.name);
        dst.inode = @enumFromInt(ent.inode);
        dst.setFromInode(&inode);

        return true;
    }

    pub fn mkdir(self: *@This(), dir: P.InodePtr, filename: []const u8) !P.InodePtr {
        try self.checkFilename(filename);

        var parent_dir_fd = I.FileFd{};
        try self.openInternal(I.publicInodePtrToInternal(dir), &parent_dir_fd, true, 0);
        defer self.closeInternal(&parent_dir_fd);

        const res = try self.findInode(&parent_dir_fd, filename);
        if (res.inode) |_| {
            return P.Error.Exists;
        }

        const inode_ptr = try self.createFile(true);
        try self.insertDirEntry(&parent_dir_fd, filename, inode_ptr, res.free_offset);

        return I.internalInodePtrToPublic(inode_ptr);
    }

    pub fn rmdir(self: *@This(), dir: P.InodePtr, filename: []const u8) !void {
        try self.checkFilename(filename);

        var fd = I.FileFd{};
        try self.openInternal(I.publicInodePtrToInternal(dir), &fd, true, 0);
        defer self.closeInternal(&fd);

        // Find entry in dir

        var found = false;
        var ent = I.DirEnt{};
        while (try self.readDirInternal(&ent, &fd, false)) {
            if (ent.isName(filename)) {
                found = true;
                break;
            }
        }

        if (!found) {
            return P.Error.NoEnt;
        }

        // Free inode and delete file contents

        // TODO: this needs to take account of open state etc.

        const content_ptrs = self.inodes.mustFree(ent.inode);
        _ = self.purgeFileContents(content_ptrs[0]);

        // Clear directory entry

        self.seekInternal(&fd, fd.abs_offset - I.DirEntSize) catch {
            @panic("internal error - seek failed when clearing directory entry");
        };
        var zeroes = [_]u8{0} ** I.DirEntSize;
        _ = try self.writeInternal(&fd, &zeroes);
    }

    //
    //

    // Find an entry in the given directory
    // If the entry is found, return inode will be set in return value.
    // If entry was not found, and there was an empty entry in the dir, this will be
    // reported in free_offset.
    fn findInode(self: *@This(), dir_fd: *I.FileFd, filename: []const u8) !struct { inode: ?I.InodePtr, free_offset: ?u32 } {
        var free_offset: ?u32 = null;
        var ent = I.DirEnt{};
        while (try self.readDirInternal(&ent, dir_fd, true)) {
            if (ent.isEmpty()) {
                if (free_offset == null) {
                    free_offset = dir_fd.abs_offset - I.DirEntSize;
                }
            } else if (ent.isName(filename)) {
                return .{ .inode = ent.inode, .free_offset = free_offset };
            }
        }
        return .{ .inode = null, .free_offset = free_offset };
    }

    // Insert the an entry into the directory whose contents are addressed by the provided file pointer.
    //
    // It is assumed that:
    //   - filename is a valid length
    //   - no conflicting filename exists in the directory
    //   - directory file pointer was opened with write access
    //
    // If offset is not null, the entry will be inserted at this location.
    // Otherwise, the entry is appended to the end of the file.
    fn insertDirEntry(self: *@This(), dir: *I.FileFd, filename: []const u8, inode_ptr: I.InodePtr, offset: ?u32) !void {
        if (offset) |o| {
            try self.seekInternal(dir, o);
        } else {
            self.seekEnd(dir);
        }

        var buffer = [_]u8{0} ** I.DirEntSize;
        @memcpy(buffer[0..filename.len], filename);
        writeBE(I.InodePtr, buffer[I.DirEntSize - 2 .. I.DirEntSize], inode_ptr);
        _ = try self.writeInternal(dir, &buffer);
    }

    // Create an empty file with index/data blocks, returning the inode.
    fn createFile(self: *@This(), is_dir: bool) error{ NoFreeBlocks, NoFreeInodes }!I.InodePtr {
        const blocks = try self.alloc2();
        const index_ptr = blocks[0];
        const data_ptr = blocks[1];

        errdefer {
            self.freelist.free(index_ptr);
            self.freelist.free(data_ptr);
        }

        self.patchBlockBE(u16, index_ptr, 0, @truncate(data_ptr));

        const inode = self.inodes.create(is_dir, @truncate(index_ptr));
        if (inode) |i| {
            return i;
        } else {
            return P.Error.NoFreeInodes;
        }
    }

    fn openInternal(self: *@This(), ptr: I.InodePtr, fd: *I.FileFd, dir: bool, flags: u32) !void {
        var inode = I.Inode{};
        if (!self.inodes.read(&inode, ptr)) {
            @panic("internal error - failed to read inode in openInternal()");
        }

        if (!dir and inode.isDir()) {
            return P.Error.IsDir;
        } else if (dir and !inode.isDir()) {
            return P.Error.NotDir;
        }

        const index_dat = self.blk_pool.take();
        defer self.blk_pool.give(index_dat);
        self.blk_dev.readBlock(index_dat, inode.data_blk) catch |err| I.noBlock(err);

        const open_file = if (self.open_file_state.get(ptr)) |ex| block: {
            // can't truncate file if it's already open
            // this limitation may be removed in the future but for now it's more complex to deal with than it's worth.
            if ((flags & P.TRUNCATE) > 0) {
                return P.Error.Busy;
            }
            ex.ref_count += 1;
            break :block ex;
        } else block: {
            const of = self.allocator.create(I.OpenFile) catch |err| I.oom(err);
            errdefer self.allocator.destroy(of);
            of.* = I.OpenFile{
                .inode_ptr = ptr,
                .root_blk = inode.data_blk,
                .size = inode.size,
                .deleted = false,
                .ref_count = 1,
            };
            self.open_file_state.put(ptr, of) catch |err| I.oom(err);
            break :block of;
        };

        fd.* = I.FileFd{
            .of = open_file,
            .flags = flags,
            .refs_invalid = false,
            .root = Ref{ .blk = inode.data_blk, .offset = 0 },
            .mid = undefined,
            .data = Ref{ .blk = readBE(u16, index_dat[0..2]), .offset = 0 },
            .abs_offset = 0,
            .deep = false,
        };

        if ((flags & P.TRUNCATE) != 0) {
            _ = self.truncateFileContents(open_file.root_blk);
            self.inodes.update(ptr, 0, null);
            open_file.size = 0;
        }

        if ((flags & P.SEEK_END) != 0) {
            self.seekInternal(fd, open_file.size) catch |err| {
                // this construct is here so that compilation will fail if seeks() error set
                // is ever expanded.
                switch (err) {
                    error.InvalidOffset => @panic("SEEK_END failed with invalid offset - this is a bug"),
                }
            };
        }

        // std.debug.print("File opened (inode={}, root_blk={}, size={}):\n", .{ fd.file.inode_ptr, fd.file.root_blk, fd.file.size });
        // std.debug.print("  root={}:{} mid={}:{} data={}:{}\n", .{ fd.root.blk, fd.root.offset, fd.mid.blk, fd.mid.offset, fd.data.blk, fd.data.offset });
    }

    fn closeInternal(self: *@This(), fd: *I.FileFd) void {
        self.unref(fd.of);
    }

    fn unref(self: *@This(), of: *I.OpenFile) void {
        of.ref_count -= 1;
        if (of.ref_count == 0) {
            if (of.deleted) {
                self.purgeInode(of.inode_ptr);
            }
            std.debug.assert(self.open_file_state.remove(of.inode_ptr));
            self.allocator.destroy(of);
        }
    }

    fn readInternal(self: *@This(), dst: []u8, fd: *I.FileFd) !struct { u32, bool } {
        const of = fd.of;

        const bytes_to_read: u32 = @min(dst.len, of.size - fd.abs_offset);
        if (bytes_to_read == 0) {
            return .{ 0, dst.len > 0 };
        }

        if (fd.refs_invalid) {
            // this is always safe to do because the fact there's data to read
            // means the block refs must be valid.
            self.updateRefs(fd);
            std.debug.assert(!fd.refs_invalid);
        }

        const scratch = self.blk_pool.take();
        defer self.blk_pool.give(scratch);

        var bytes_read: u32 = 0;
        while (bytes_read < bytes_to_read) {
            if (fd.data.offset == self.blk_size) {
                try self.advanceFilePointer(fd);
            }

            const bytes_remaining = bytes_to_read - bytes_read;
            const bytes_to_read_from_blk: u32 = @min(bytes_remaining, self.blk_size - fd.data.offset);

            try self.blk_dev.readBlock(scratch, fd.data.blk);
            @memcpy(dst[bytes_read .. bytes_read + bytes_to_read_from_blk], scratch[fd.data.offset .. fd.data.offset + bytes_to_read_from_blk]);

            fd.abs_offset += bytes_to_read_from_blk;
            fd.data.offset += bytes_to_read_from_blk;
            bytes_read += bytes_to_read_from_blk;
        }

        // only return an EOF flag if we're both
        // a) at the file end, and
        // b) we attempted to read past the end
        const is_eof = (fd.abs_offset == of.size) and (bytes_read < dst.len);

        return .{ bytes_read, is_eof };
    }

    fn readDirInternal(self: *@This(), dst: *I.DirEnt, fd: *I.FileFd, include_empty: bool) !bool {
        var buf = [_]u8{0} ** I.DirEntSize;
        while (true) {
            const res = try self.readInternal(&buf, fd);
            if (res[1]) {
                return false; // EOF
            } else if (res[0] != I.DirEntSize) {
                return I.Error.FSInternalError; // less than 16 bytes => invalid entry
            } else if (buf[0] == 0 and !include_empty) {
                continue; // no entry (previously deleted)
            } else {
                @memcpy(&dst.*.name, buf[0..I.MaxFilenameLen]);
                dst.*.inode = readBE(u16, buf[I.DirEntSize - 2 .. I.DirEntSize]);
                return true;
            }
        }
    }

    fn writeInternal(self: *@This(), fd: *I.FileFd, buf: []const u8) !u32 {
        const bytes_to_write = buf.len;
        if (bytes_to_write == 0) {
            return 0;
        }

        if (fd.refs_invalid) {
            self.updateRefs(fd);
            std.debug.assert(!fd.refs_invalid);
        }

        const scratch = self.blk_pool.take();
        defer self.blk_pool.give(scratch);

        var bytes_written: u32 = 0;
        while (bytes_written < bytes_to_write) {
            if (fd.data.offset == self.blk_size) {
                try self.advanceFilePointer(fd);
            }

            const bytes_remaining = bytes_to_write - bytes_written;
            const bytes_to_write_to_blk = @min(bytes_remaining, self.blk_size - fd.data.offset);

            try self.blk_dev.readBlock(scratch, fd.data.blk);
            @memcpy(scratch[fd.data.offset .. fd.data.offset + bytes_to_write_to_blk], buf[bytes_written .. bytes_written + bytes_to_write_to_blk]);
            self.blk_dev.writeBlock(fd.data.blk, scratch);

            fd.abs_offset += bytes_to_write_to_blk;
            fd.data.offset += bytes_to_write_to_blk;
            bytes_written += bytes_to_write_to_blk;
        }

        if (fd.abs_offset > fd.of.size) {
            fd.of.size = fd.abs_offset;
            self.inodes.update(fd.of.inode_ptr, fd.of.size, null);
        }

        return bytes_written;
    }

    // Given a file descriptor whose data offset is pointing to the end of its
    // current data block, adjust it so that it is pointing to the start of the
    // data block containing the data immediately following, allocating a new
    // block if necessary, taking care of indirection as necessary.
    fn advanceFilePointer(self: *@This(), fd: *I.FileFd) !void {
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
                fd.deep = true;
            }
        } else {
            if ((fd.mid.offset + 2) < self.blk_size) {
                target_blk = try self.simpleIncrement(&fd.mid);
            } else {
                target_blk = try self.indirectIncrement(fd);
            }
        }

        fd.data = I.Ref{ .blk = target_blk, .offset = 0 };
    }

    // Advances the given Ref by 2 bytes (the size of a block pointer).
    // If the pointer found at the updated Ref is zero, a new block is allocated, zeroed, and
    // the pointer is updated to point to this new block.
    //
    // Returns the address of the block that is pointed to.
    fn simpleIncrement(self: *@This(), ent: *I.Ref) !u32 {
        const scratch = self.blk_pool.take();
        defer self.blk_pool.give(scratch);

        try self.blk_dev.readBlock(scratch, ent.blk);

        const next_offset = ent.offset + 2;
        var target_blk = readBE(u16, scratch[next_offset .. next_offset + 2]);
        if (target_blk == 0) {
            const new_blk = try self.alloc();
            writeBE(u16, scratch[next_offset .. next_offset + 2], @truncate(new_blk));
            self.blk_dev.writeBlock(ent.blk, scratch);
            target_blk = @truncate(new_blk);
        }

        ent.offset = next_offset;

        return target_blk;
    }

    fn indirectIncrement(self: *@This(), fd: *I.FileFd) !u32 {
        const next_root_offset = fd.root.offset + 2;

        if (next_root_offset == self.blk_size) {
            return P.Error.NoSpace;
        }

        const tmp_data = self.blk_pool.take();
        defer self.blk_pool.give(tmp_data);
        try self.blk_dev.readBlock(tmp_data, fd.root.blk);
        const next_mid_blk = readBE(u16, tmp_data[next_root_offset .. next_root_offset + 2]);

        if (next_mid_blk == 0) {
            // if there's no indirect block, we need to allocate one (plus a data block)

            const mid_blk_data = self.blk_pool.take();
            defer self.blk_pool.give(mid_blk_data);

            const blks = try self.alloc2();

            // tmp_data is already valid - contains the root block
            writeBE(u16, tmp_data[next_root_offset .. next_root_offset + 2], @truncate(blks[0]));

            // read the freshly zero'd mid-block
            // alternatively we could just zero it ourselves here but this is
            // more consistent.
            try self.blk_dev.readBlock(mid_blk_data, blks[1]);
            writeBE(u16, mid_blk_data[0..2], @truncate(blks[1]));

            self.blk_dev.writeBlock(blks[0], mid_blk_data);
            self.blk_dev.writeBlock(fd.root.blk, tmp_data);

            fd.root.offset = next_root_offset;
            fd.mid = I.Ref{ .blk = blks[0], .offset = 0 };

            return blks[1];
        } else {
            // indirect block already present - pluck the next data block from its
            // first entry.

            try self.blk_dev.readBlock(tmp_data, next_mid_blk);
            const next_data_blk = readBE(u16, tmp_data[0..2]);

            fd.root.offset = next_root_offset;
            fd.mid = I.Ref{ .blk = next_mid_blk, .offset = 0 };

            return next_data_blk;
        }
    }

    //
    // Seek

    fn seekEnd(self: *@This(), fd: *I.FileFd) void {
        self.seekInternal(fd, fd.of.size) catch @panic("seekEnd() failed - this is a bug");
    }

    fn seekInternal(_: *@This(), fd: *I.FileFd, new_abs_offset: u32) error{InvalidOffset}!void {
        const of = fd.of;

        if (new_abs_offset == fd.abs_offset) {
            return;
        } else if (new_abs_offset > of.size) {
            return P.Error.InvalidOffset;
        }

        fd.refs_invalid = true;
        fd.abs_offset = new_abs_offset;
    }

    fn updateRefs(self: *@This(), fd: *I.FileFd) void {
        // if we're at the end of the last block in the file we need to prime the read/write
        // routines to call advanceFilePointer(). we do this by seeking one block back from
        // the target and then setting the data offset to match the block size - a condition
        // which will cause read/write to call advanceFilePointer().
        const hack = (fd.abs_offset > 0 and fd.abs_offset == fd.of.size and (fd.abs_offset % self.blk_size) == 0);
        const seek_offset = if (hack) fd.abs_offset - self.blk_size else fd.abs_offset;

        if (seek_offset < self.indirect_offset_threshold) {
            self.updateRefsShallow(fd.of, fd, seek_offset);
        } else {
            self.updateRefsDeep(fd.of, fd, seek_offset);
        }

        if (hack) {
            std.debug.assert(fd.data.offset == 0);
            fd.data.offset = self.blk_size;
        }

        fd.refs_invalid = false;
    }

    fn updateRefsShallow(self: *@This(), of: *I.OpenFile, fd: *I.FileFd, abs_offset: u32) void {
        const scratch = self.blk_pool.take();
        defer self.blk_pool.give(scratch);

        const offsets = self.calculateShallowOffsets(abs_offset);

        const root = I.Ref{
            .blk = of.*.root_blk,
            .offset = offsets[0],
        };

        self.blk_dev.readBlock(scratch, root.blk) catch |err| I.noBlock(err);

        fd.deep = false;
        fd.root = root;
        fd.data = I.Ref{
            .blk = readBE(u16, scratch[root.offset .. root.offset + I.BlockPtrSize]),
            .offset = offsets[1],
        };
    }

    fn updateRefsDeep(self: *@This(), of: *I.OpenFile, fd: *I.FileFd, abs_offset: u32) void {
        const scratch = self.blk_pool.take();
        defer self.blk_pool.give(scratch);

        const offsets = self.calculateDeepOffsets(abs_offset);

        const root = I.Ref{
            .blk = of.*.root_blk,
            .offset = offsets[0],
        };

        self.blk_dev.readBlock(scratch, root.blk) catch |err| I.noBlock(err);

        const indirect = I.Ref{
            .blk = readBE(u16, scratch[root.offset .. root.offset + I.BlockPtrSize]),
            .offset = offsets[1],
        };

        self.blk_dev.readBlock(scratch, indirect.blk) catch |err| I.noBlock(err);

        fd.*.deep = true;
        fd.*.root = root;
        fd.*.mid = indirect;
        fd.*.data = I.Ref{
            .blk = readBE(u16, scratch[indirect.offset .. indirect.offset + I.BlockPtrSize]),
            .offset = offsets[2],
        };
    }

    fn calculateShallowOffsets(self: @This(), abs_offset: u32) struct { u32, u32 } {
        return .{
            (abs_offset / self.blk_size) * I.BlockPtrSize,
            abs_offset % self.blk_size,
        };
    }

    fn calculateDeepOffsets(self: @This(), abs_offset: u32) struct { u32, u32, u32 } {
        const rel_offset = abs_offset - self.indirect_offset_threshold;
        const bytes_per_indirect_block = self.pointers_per_block * self.blk_size;
        const indirect_index = rel_offset / bytes_per_indirect_block;
        const root_offset = (self.blk_size / 2) + (indirect_index * I.BlockPtrSize);
        const indirect_offset = ((rel_offset % bytes_per_indirect_block) / self.blk_size) * I.BlockPtrSize;
        const data_offset = rel_offset % self.blk_size;
        return .{ root_offset, indirect_offset, data_offset };
    }

    //
    // Truncate/purge

    // truncate file to zero length, leaving first index block and first data block.
    // note: this does not update the inode or any open files
    fn truncateFileContents(self: *@This(), index_blk: u32) u32 {
        const index_dat = self.blk_pool.take();
        defer self.blk_pool.give(index_dat);

        self.blk_dev.readBlock(index_dat, index_blk) catch |err| return I.noBlock(err);
        var freed = self.freeReferencedBlocks(index_dat[2..(self.blk_size / 2)]);
        freed += self.freeIndirectReferencedBlocks(index_dat[(self.blk_size / 2)..]);

        // zero out the index block except for the first entry
        @memset(index_dat[2..], 0);
        self.blk_dev.writeBlock(index_blk, index_dat);

        // zero the first data block
        self.blk_dev.zeroBlock(readBE(u16, index_dat[0..2]));

        return freed;
    }

    // free the inode and all of the data it points to
    fn purgeInode(self: *@This(), inode_ptr: I.InodePtr) void {
        const ptrs = self.inodes.mustFree(inode_ptr);
        _ = self.purgeFileContents(ptrs[0]);
    }

    // free all blocks used by the file whose index is rooted at index_blk.
    // returns the number of blocks freed.
    fn purgeFileContents(self: *@This(), index_blk: u32) u32 {
        const index_dat = self.blk_pool.take();
        defer self.blk_pool.give(index_dat);

        self.blk_dev.readBlock(index_dat, index_blk) catch @panic("no block");
        var freed = self.freeReferencedBlocks(index_dat[0..(self.blk_size / 2)]);
        freed += self.freeIndirectReferencedBlocks(index_dat[(self.blk_size / 2)..]);
        self.freelist.free(index_blk);
        freed += 1;

        return freed;
    }

    // free all blocks referenced from blk_data, assuming blk_data is a
    // tightly-packed slice of block references.
    // returns the number of blocks freed.
    fn freeReferencedBlocks(self: *@This(), blk_data: []const u8) u32 {
        var freed: u32 = 0;
        var i: u32 = 0;
        while (i < blk_data.len) : (i += 2) {
            const pointee_blk = readBE(u16, blk_data[i .. i + 2]);
            if (pointee_blk == 0) {
                continue;
            }
            self.freelist.free(pointee_blk);
            freed += 1;
        }
        return freed;
    }

    fn freeIndirectReferencedBlocks(self: *@This(), pointers: []u8) u32 {
        const l2_dat = self.blk_pool.take();
        defer self.blk_pool.give(l2_dat);

        var freed: u32 = 0;
        var i: u32 = 0;
        while (i < pointers.len) : (i += 2) {
            const pointee = readBE(u16, pointers[i .. i + 2]);
            if (pointee == 0) {
                continue;
            }

            self.blk_dev.readBlock(l2_dat, pointee) catch |err| return I.noBlock(err);
            freed += self.freeReferencedBlocks(l2_dat);

            self.freelist.free(pointee);
            freed += 1;
        }

        return freed;
    }

    //
    // Misc helpers

    fn checkFilename(_: *@This(), filename: []const u8) error{NameTooLong}!void {
        if (filename.len > I.MaxFilenameLen) {
            return P.Error.NameTooLong;
        }
    }

    // allocate a block and zero it
    fn alloc(self: *@This()) !u32 {
        const b = try self.freelist.alloc();
        self.blk_dev.zeroBlock(b);
        return b;
    }

    // allocate two blocks and zero them
    fn alloc2(self: *@This()) !struct { u32, u32 } {
        const b1 = try self.freelist.alloc();
        errdefer self.freelist.free(b1);
        const b2 = try self.freelist.alloc();
        self.blk_dev.zeroBlock(b1);
        self.blk_dev.zeroBlock(b2);
        return .{ b1, b2 };
    }

    // patch a single integer value into a target block at the given offset
    fn patchBlockBE(self: *@This(), comptime T: type, block: u32, offset: u32, value: T) void {
        const data = self.blk_pool.take();
        defer self.blk_pool.give(data);
        self.blk_dev.readBlock(data, block) catch |err| I.noBlock(err);
        writeBE(T, data[offset..(offset + @sizeOf(T))], value);
        self.blk_dev.writeBlock(block, data);
    }

    // alllocate a new file descriptor
    fn allocateFd(self: *@This()) P.Fd {
        while (true) {
            const fd: P.Fd = @enumFromInt(self.seq.take());
            if (self.open_dirs.contains(fd) or self.open_files.contains(fd)) {
                continue;
            }
            return fd;
        }
    }

    fn get_open_file(self: *@This(), fd: P.Fd) error{InvalidFileHandle}!*I.FileFd {
        return self.open_files.get(fd) orelse return P.Error.InvalidFileHandle;
    }

    fn get_open_dir(self: *@This(), fd: P.Fd) error{InvalidFileHandle}!*I.FileFd {
        return self.open_dirs.get(fd) orelse return P.Error.InvalidFileHandle;
    }
};
