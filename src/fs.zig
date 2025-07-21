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
    open_files: OpenFiles,
    file_handles: FileHandles,
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
        config_out[1] = @truncate((inode_blk_count / BLOCK_COUNT_MULTIPLIER) - 1);
    }

    pub fn init(allocator: Allocator, blk_dev: *bd.BlockDevice, config: []u8) !FileSystem {
        if (config.len != 16 or config[0] != P.FS_TYPE_ID) {
            return P.Error.InvalidFSParams;
        }

        var inode_blk_count: u32 = config[1];
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
            .open_files = OpenFiles.init(allocator),
            .file_handles = FileHandles.init(allocator),
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
        self.open_files.deinit();
        self.file_handles.deinit();
    }

    pub fn lookup(self: *@This(), dir: P.InodePtr, filename: []const u8) !?P.InodePtr {
        var dir_fd = I.FileFd{};
        try self.openInternal(@truncate(dir), &dir_fd, true, P.READ);
        defer self.closeInternal(&dir_fd);

        const res = try self.findInode(&dir_fd, filename);
        if (res.inode) |inode| {
            return inode;
        } else {
            return null;
        }
    }

    pub fn exists(self: *@This(), dir: P.InodePtr, filename: []const u8) !bool {
        return (try self.lookup(dir, filename)) != null;
    }

    pub fn open(self: *@This(), dir: P.InodePtr, filename: []const u8, flags: u32) !P.Fd {
        const create = (flags & P.CREATE) > 0;

        var dir_open_flags: u32 = P.READ;
        if (create) {
            dir_open_flags |= P.WRITE;
        }

        var dir_fd = I.FileFd{};
        try self.openInternal(@truncate(dir), &dir_fd, true, dir_open_flags);
        defer self.closeInternal(&dir_fd) catch @panic("closeInternal() failed");

        const res = try self.findInode(&dir_fd, filename);
        if (res.inode) |inode| {
            return self.openFileExisting(inode, flags);
        } else if (!create) {
            return P.Error.NoEnt;
        } else {
            return self.openFileCreate(&dir_fd, filename, flags, res.free_offset);
        }
    }

    fn openFileExisting(self: *@This(), inode_ptr: I.InodePtr, flags: u32) !P.Fd {
        const file = self.allocator.create(I.FileFd) catch |err| I.oom(err);
        errdefer self.allocator.destroy(file);
        try self.openInternal(inode_ptr, file, false, flags);
        const fd = self.seq.take();
        self.file_handles.put(fd, file) catch |err| I.oom(err);
        return fd;
    }

    fn openFileCreate(self: *@This(), fd: *I.FileFd, filename: []const u8, flags: u32, free_offset: ?u32) !P.Fd {
        // flags to handle: none
        _ = self;
        _ = fd;
        _ = filename;
        _ = flags;
        _ = free_offset;
        return 0;
    }

    pub fn mkdir(self: *@This(), dir: P.InodePtr, filename: []const u8) !P.InodePtr {
        if (filename.len > I.MaxFilenameLen) {
            return P.Error.InvalidFileName;
        }

        var fd = I.FileFd{};
        try self.openInternal(@truncate(dir), &fd, true, P.READ | P.WRITE);
        defer self.closeInternal(&fd);

        const res = try self.findInode(&fd, filename);
        if (res.inode) |_| {
            return P.Error.Exists;
        } else if (res.free_offset) |fo| {
            try self.seek(&fd, fo);
        }

        const inode = try self.createFile(true);

        var buffer = [_]u8{0} ** I.DirEntSize;
        @memcpy(buffer[0..filename.len], filename);
        writeBE(u16, buffer[I.DirEntSize - 2 .. I.DirEntSize], inode);
        _ = try self.writeInternal(&fd, &buffer);

        return inode;
    }

    pub fn rmdir(self: *@This(), dir: P.InodePtr, filename: []const u8) !void {
        var fd = I.FileFd{};
        try self.openInternal(@truncate(dir), &fd, true, P.READ);
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

        self.seek(&fd, fd.abs_offset - I.DirEntSize) catch {
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
    fn findInode(self: *@This(), fd: *I.FileFd, filename: []const u8) !struct { inode: ?I.InodePtr, free_offset: ?u32 } {
        var free_offset: ?u32 = null;
        var ent = I.DirEnt{};
        while (try self.readDirInternal(&ent, fd, true)) {
            if (ent.name[0] == 0 and free_offset == null) {
                free_offset = fd.abs_offset - I.DirEntSize;
            } else if (ent.isName(filename)) {
                return .{ .inode = ent.inode, .free_offset = free_offset };
            }
        }
        return .{ .inode = null, .free_offset = free_offset };
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
        self.blk_dev.readBlock(index_dat, inode.data_blk) catch |err| I.noBlock2(err);

        const open_file = if (self.open_files.get(ptr)) |ex| block: {
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
            self.open_files.put(ptr, of) catch |err| I.oom(err);
            break :block of;
        };

        fd.* = I.FileFd{
            .file = open_file,
            .flags = flags,
            .root = Ref{ .blk = inode.data_blk, .offset = 0 },
            .mid = Ref{ .blk = 0, .offset = 0 },
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
            self.seek(fd, open_file.size) catch |err| {
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
        const of = fd.*.file;

        of.*.ref_count -= 1;

        if (of.*.ref_count == 0) {
            const was_deleted = of.*.deleted;
            const removed = self.open_files.remove(of.*.inode_ptr);
            std.debug.assert(removed);

            const inode_ptr = of.inode_ptr;
            self.allocator.destroy(of);

            if (was_deleted) {
                self.purgeInode(inode_ptr);
            }
        }
    }

    fn readInternal(self: *@This(), dst: []u8, fd: *I.FileFd) !struct { u32, bool } {
        const of = fd.file;

        if (!fd.isReadable()) {
            return P.Error.NotReadable;
        }

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

        // only return an EOF flag if we're both
        // a) at the file end, and
        // b) we attempted to read past the end
        const eof = (fd.abs_offset == of.size) and (bytes_read < dst.len);

        return .{ bytes_read, eof };
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

    fn writeInternal(self: *@This(), fd: *I.FileFd, buf: []u8) !u32 {
        if (!fd.isWritable()) {
            return P.Error.NotWritable;
        }

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
            self.inodes.update(fd.file.inode_ptr, fd.file.size, null);
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
                fd.*.deep = true;
            }
        } else {
            if ((fd.mid.offset + 2) < self.blk_size) {
                target_blk = try self.simpleIncrement(&fd.mid);
            } else {
                target_blk = try self.indirectIncrement(fd);
            }
        }

        fd.*.data = I.Ref{ .blk = target_blk, .offset = 0 };
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

        ent.*.offset = next_offset;

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

            writeBE(u16, tmp_data[next_root_offset .. next_root_offset + 2], @truncate(blks[0]));
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

    fn seek(self: *@This(), fd: *I.FileFd, abs_offset: u32) error{InvalidOffset}!void {
        const of = fd.file;

        if (abs_offset > of.*.size) {
            return P.Error.InvalidOffset;
        }

        if (abs_offset < self.indirect_offset_threshold) {
            self.seekShallow(of, fd, abs_offset);
        } else {
            self.seekDeep(of, fd, abs_offset);
        }

        fd.*.abs_offset = abs_offset;
    }

    fn seekShallow(self: *@This(), of: *I.OpenFile, fd: *I.FileFd, abs_offset: u32) void {
        const scratch = self.blk_pool.take();
        defer self.blk_pool.give(scratch);

        const offsets = self.calculateShallowOffsets(abs_offset);

        const root = I.Ref{
            .blk = of.*.root_blk,
            .offset = offsets[0],
        };

        self.blk_dev.readBlock(scratch, root.blk) catch |err| I.noBlock2(err);

        fd.*.deep = false;
        fd.*.root = root;
        fd.*.data = I.Ref{
            .blk = readBE(u16, scratch[root.offset .. root.offset + I.BlockPtrSize]),
            .offset = offsets[1],
        };
    }

    fn seekDeep(self: *@This(), of: *I.OpenFile, fd: *I.FileFd, abs_offset: u32) void {
        const scratch = self.blk_pool.take();
        defer self.blk_pool.give(scratch);

        const offsets = self.calculateDeepOffsets(abs_offset);

        const root = I.Ref{
            .blk = of.*.root_blk,
            .offset = offsets[0],
        };

        self.blk_dev.readBlock(scratch, root.blk) catch |err| I.noBlock2(err);

        const indirect = I.Ref{
            .blk = readBE(u16, scratch[root.offset .. root.offset + I.BlockPtrSize]),
            .offset = offsets[1],
        };

        self.blk_dev.readBlock(scratch, indirect.blk) catch |err| I.noBlock2(err);

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

        self.blk_dev.readBlock(index_dat, index_blk) catch return I.noBlock();
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

            self.blk_dev.readBlock(l2_dat, pointee) catch return I.noBlock();
            freed += self.freeReferencedBlocks(l2_dat);

            self.freelist.free(pointee);
            freed += 1;
        }

        return freed;
    }

    //
    // Misc helpers

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
        self.blk_dev.readBlock(data, block) catch |err| I.noBlock2(err);
        writeBE(T, data[offset..(offset + @sizeOf(T))], value);
        self.blk_dev.writeBlock(block, data);
    }
};
