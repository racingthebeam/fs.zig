const std = @import("std");
const panic = std.debug.panic;
const expect = std.testing.expect;
const Allocator = std.mem.Allocator;

const bd = @import("block_device.zig");
const BlockDevice = bd.BlockDevice;

const I = @import("internal.zig");
const Inode = I.Inode;
const InodePtr = I.InodePtr;

const readBE = @import("util.zig").readBE;
const writeBE = @import("util.zig").writeBE;

const InodeSize = 16;

pub const InodeTable = struct {
    allocator: Allocator,
    table: []Inode,
    size: u32,
    start_blk: u32,
    end_blk: u32,

    blk_dev: *BlockDevice,
    inodes_per_blk: u32,
    scratch: []u8,
    free: std.ArrayList(InodePtr),

    pub fn initialize(blk_dev: *BlockDevice, start_blk: u32, blk_count: u32) u32 {
        var i: u32 = start_blk;
        while (i < start_blk + blk_count) : (i += 1) {
            blk_dev.zeroBlock(i);
        }
        return i;
    }

    pub fn init(allocator: Allocator, blk_dev: *BlockDevice, start_blk: u32, blk_count: u32) !InodeTable {
        const abs_size = (blk_count * blk_dev.blk_size) / InodeSize;
        if (abs_size > 65536) {
            return I.Error.LimitsExceeded;
        }

        const size: u16 = @truncate(abs_size);
        const inodes_per_blk = blk_dev.blk_size / InodeSize;
        const end_blk = start_blk + blk_count;

        const table = try allocator.alloc(Inode, size);
        errdefer allocator.free(table);

        const scratch = try allocator.alloc(u8, blk_dev.blk_size);
        errdefer allocator.free(scratch);

        var free = std.ArrayList(InodePtr).init(allocator);
        errdefer free.deinit();

        // Load table in reverse order so inodes are allocated smallest-first
        var wp: u16 = size - 1;
        var loaded_blk: u32 = std.math.maxInt(u32);
        while (wp != std.math.maxInt(u16)) : (wp -%= 1) {
            const rel_blk = wp / inodes_per_blk;
            const abs_blk = start_blk + rel_blk;
            if (abs_blk != loaded_blk) {
                try blk_dev.readBlock(scratch, abs_blk);
                loaded_blk = abs_blk;
            }
            const offset = (wp % inodes_per_blk) * InodeSize;
            readEntry(&table[wp], scratch[offset .. offset + InodeSize]);
            if (!table[wp].isPresent()) {
                try free.append(wp);
            }
        }

        return InodeTable{
            .allocator = allocator,
            .table = table,
            .size = size,
            .start_blk = start_blk,
            .end_blk = end_blk,

            .blk_dev = blk_dev,
            .inodes_per_blk = inodes_per_blk,
            .scratch = scratch,
            .free = free,
        };
    }

    pub fn deinit(self: *@This()) void {
        self.allocator.free(self.table);
        self.allocator.free(self.scratch);
        self.free.deinit();
    }

    pub fn create(self: *@This(), inode: *const Inode) ?u16 {
        std.debug.assert(inode.isPresent());

        const ptr = self.free.pop() orelse return null;
        self.table[ptr] = inode.*;
        self.writeBack(ptr);
        return ptr;
    }

    pub fn update(self: *@This(), ptr: InodePtr, size: ?u32, mtime: ?u32) !void {
        var inode = Inode{};
        self.mustRead(&inode, ptr);
        if (size) |sz| {
            inode.size = sz;
        }
        if (mtime) |mt| {
            inode.mtime = mt;
        }
        self.write(ptr, &inode);
    }

    pub fn take(self: *@This()) ?InodePtr {
        const ino = self.free.pop() orelse return null;
        self.table[ino].flags = 0xFFFF;
        return ino;
    }

    pub fn give(self: *@This(), ptr: InodePtr) void {
        std.debug.assert(ptr < self.size);

        self.table[ptr] = Inode{};
        self.writeBack(ptr);

        self.free.append(ptr) catch @panic("OOM");
    }

    pub fn read(self: *@This(), dst: *Inode, ptr: InodePtr) bool {
        std.debug.assert(ptr < self.size);

        if (!self.table[ptr].isPresent()) {
            return false;
        }

        dst.* = self.table[ptr];
        return true;
    }

    pub fn mustRead(self: *@This(), dst: *Inode, ptr: InodePtr) void {
        std.debug.assert(ptr < self.size);
        std.debug.assert(self.table[ptr].isPresent());

        dst.* = self.table[ptr];
    }

    pub fn write(self: *@This(), ptr: InodePtr, src: *const Inode) void {
        std.debug.assert(ptr < self.size);
        std.debug.assert(src.isPresent());

        self.table[ptr] = src.*;
        self.writeBack(ptr);
    }

    pub fn clear(self: *@This(), ptr: InodePtr) void {
        std.debug.assert(ptr < self.size);

        self.table[ptr] = Inode{};
        self.writeBack(ptr);
    }

    fn writeBack(self: *@This(), ptr: InodePtr) void {
        const rel_blk = ptr / self.inodes_per_blk;
        const abs_blk = self.start_blk + rel_blk;

        self.blk_dev.readBlock(self.scratch, abs_blk) catch @panic("no block");

        const offset = (ptr % self.inodes_per_blk) * InodeSize;
        writeEntry(self.scratch[offset .. offset + InodeSize], &self.table[ptr]);

        self.blk_dev.writeBlock(abs_blk, self.scratch);
    }
};

test "InodeTable" {
    const allocator = std.testing.allocator;

    const blk_dev = try bd.create(allocator, 128, 128);
    defer bd.destroy(allocator, blk_dev);
    @memset(blk_dev.data, 0xFF);

    // check correct end is reported
    const end = InodeTable.initialize(blk_dev, 1, 4);
    try expect(end == 5);

    // check the zeroes are written only to the inode table
    for (blk_dev.data, 0..) |foo, ix| {
        if (ix < 128 or ix >= 5 * 128) {
            try expect(foo == 0xFF);
        } else {
            try expect(foo == 0);
        }
    }

    var t1 = try InodeTable.init(allocator, blk_dev, 1, 4);
    defer t1.deinit();

    try expect(t1.table.len == 32);
    try expect(t1.size == 32);
    try expect(t1.start_blk == 1);
    try expect(t1.end_blk == 5);
    try expect(t1.inodes_per_blk == 8);
    try expect(t1.free.items.len == 32);

    // check free inodes are stored in descending order
    for (t1.free.items, 0..) |inode, ix| {
        try expect(inode == 31 - ix);
    }

    var read_back = Inode{};

    {
        // check we can't read back any entries - they should all be empty
        var i: u16 = 0;
        while (i < t1.size) : (i += 1) {
            try expect(!t1.read(&read_back, i));
        }
    }

    const inode = Inode{
        .flags = 0x1234,
        .data_blk = 0x5678,
        .meta_blk = 0x9ABC,
        .mtime = 30_000_000,
        .size = 50_000_000,
    };

    t1.write(12, &inode);

    {
        // should be able to read back the entry we just wrote
        var i: u16 = 0;
        while (i < t1.size) : (i += 1) {
            try expect(t1.read(&read_back, i) == (i == 12));
        }
    }

    // reinitialise new table on same block store
    var t2 = try InodeTable.init(allocator, blk_dev, 1, 4);
    defer t2.deinit();

    {
        // check we can read back the same entry
        var i: u16 = 0;
        while (i < t2.size) : (i += 1) {
            try expect(t2.read(&read_back, i) == (i == 12));
        }
    }

    // check entry values match what was written
    try expect(inode.flags == read_back.flags);
    try expect(inode.data_blk == read_back.data_blk);
    try expect(inode.meta_blk == read_back.meta_blk);
    try expect(inode.size == read_back.size);
    try expect(inode.mtime == read_back.mtime);
}

const offset_flags = 0;
const offset_unused = offset_flags + 2;
const offset_data_blk = offset_unused + 2;
const offset_meta_blk = offset_data_blk + 2;
const offset_modified = offset_meta_blk + 2;
const offset_size = offset_modified + 4;

fn readEntry(ent: *Inode, src: []const u8) void {
    ent.flags = readBE(u16, src[offset_flags .. offset_flags + 2]);
    ent.data_blk = readBE(u16, src[offset_data_blk .. offset_data_blk + 2]);
    ent.meta_blk = readBE(u16, src[offset_meta_blk .. offset_meta_blk + 2]);
    ent.size = readBE(u32, src[offset_size .. offset_size + 4]);
    ent.mtime = readBE(u32, src[offset_modified .. offset_modified + 4]);
}

test "readEntry" {
    const buf = [_]u8{
        0xd, 0xe, // flags
        0, 0, // unused
        0x1, 0x2, // data
        0x3, 0x4, // meta
        0x5, 0x6, 0x7, 0x8, // modified
        0x9, 0xa, 0xb, 0xc, // size
    };

    var ent = Inode{};

    readEntry(&ent, &buf);

    try expect(ent.flags == 0x0d0e);
    try expect(ent.data_blk == 0x0102);
    try expect(ent.meta_blk == 0x0304);
    try expect(ent.size == 0x090a0b0c);
    try expect(ent.mtime == 0x05060708);
}

fn writeEntry(dst: []u8, ent: *Inode) void {
    writeBE(u16, dst[offset_flags .. offset_flags + 2], ent.*.flags);
    dst[offset_unused + 0] = 0;
    dst[offset_unused + 1] = 0;
    writeBE(u16, dst[offset_data_blk .. offset_data_blk + 2], ent.*.data_blk);
    writeBE(u16, dst[offset_meta_blk .. offset_meta_blk + 2], ent.*.meta_blk);
    writeBE(u32, dst[offset_size .. offset_size + 4], ent.*.size);
    writeBE(u32, dst[offset_modified .. offset_modified + 4], ent.*.mtime);
}

test "writeEntry" {
    var ent = Inode{ .flags = 0x0e0d, .data_blk = 0x0201, .meta_blk = 0x0403, .mtime = 0x08070605, .size = 0x0c0b0a09 };

    var buf = [_]u8{255} ** 16;

    writeEntry(&buf, &ent);

    const expected = [_]u8{
        0x0e, 0x0d, // flags
        0, 0, // unused
        0x02, 0x01, // data
        0x04, 0x03, // meta
        0x08, 0x07, 0x06, 0x05, // mod
        0x0c, 0x0b, 0x0a, 0x09, // size
    };

    try expect(std.mem.eql(u8, &buf, &expected));
}
