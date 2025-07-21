const std = @import("std");
const Allocator = std.mem.Allocator;
const blkdev = @import("./block_device.zig");

pub const FreeListErrors = error{NoFreeBlocks};

pub const FreeList = struct {
    allocator: Allocator,
    blk_dev: *blkdev.BlockDevice,
    start_blk: u32,
    entries_per_blk: u32,
    scratch: []u8,
    list: std.ArrayList(u32),

    pub fn create(allocator: Allocator, block_dev: *blkdev.BlockDevice, start_block: u32) !u32 {
        const length = calculateFreeListSize(block_dev.blk_size, block_dev.blk_count);
        const entries_per_block = block_dev.blk_size * 8;

        // we assume that all blocks prior to the freelist are already occupied.
        const initial_occupied_blocks: u32 = start_block + length;

        var curr_block: u32 = std.math.maxInt(u32);

        const scratch = try allocator.alloc(u8, block_dev.*.blk_size);
        defer allocator.free(scratch);

        var i: u32 = 0;
        while (i < block_dev.blk_count) : (i += 1) {
            const occupied = i < initial_occupied_blocks;

            const block = start_block + (i / entries_per_block);
            if (block != curr_block) {
                if (curr_block != std.math.maxInt(u32)) {
                    block_dev.writeBlock(curr_block, scratch);
                }
                try block_dev.readBlock(scratch, block);
                curr_block = block;
                @memset(scratch, 0xFF);
            }
            if (occupied) {
                const logical_offset = i % entries_per_block;
                const byte_offset = logical_offset / 8;
                const bit_offset: u3 = @truncate(logical_offset % 8);
                scratch[byte_offset] &= ~(@as(u8, 1) << bit_offset);
            }
        }

        if (curr_block != std.math.maxInt(u32)) {
            block_dev.writeBlock(curr_block, scratch);
        }

        return initial_occupied_blocks;
    }

    pub fn init(allocator: Allocator, block_dev: *blkdev.BlockDevice, start_block: u32) !FreeList {
        var fl = FreeList{
            .allocator = allocator,
            .blk_dev = block_dev,
            .start_blk = start_block,
            .entries_per_blk = block_dev.blk_size * 8,
            .scratch = try allocator.alloc(u8, block_dev.*.blk_size),
            .list = std.ArrayList(u32).init(allocator),
        };

        try fl.loadFromBlockDevice();

        return fl;
    }

    pub fn deinit(self: *@This()) void {
        self.allocator.free(self.scratch);
        self.list.deinit();
    }

    pub fn endBlock(self: *FreeList) u32 {
        return self.start_blk + calculateFreeListSize(self.blk_dev.blk_size, self.blk_dev.blk_count);
    }

    pub fn alloc(self: *FreeList) error{NoFreeBlocks}!u32 {
        const opt_blk = self.list.pop();
        if (opt_blk) |blk| {
            self.markBlock(blk, false);
            return blk;
        } else {
            return FreeListErrors.NoFreeBlocks;
        }
    }

    pub fn free(self: *FreeList, block: u32) void {
        self.list.append(block) catch @panic("OOM");
        self.markBlock(block, true);
    }

    fn markBlock(self: *FreeList, block: u32, isFree: bool) void {
        const pos = self.getBlockPos(block);
        self.blk_dev.readBlock(self.scratch, pos.block) catch @panic("NO BLOCK");
        if (isFree) {
            self.scratch[pos.byte_offset] |= (@as(u8, 1) << pos.bit_offset);
        } else {
            self.scratch[pos.byte_offset] &= ~(@as(u8, 1) << pos.bit_offset);
        }
        self.blk_dev.writeBlock(pos.block, self.scratch);
    }

    fn loadFromBlockDevice(self: *FreeList) !void {
        var loaded_block: u32 = std.math.maxInt(u32);

        // iterate in reverse order so lower block numbers are handed out first
        var i: u32 = self.blk_dev.blk_count;
        while (i > 0) {
            i -= 1;
            const pos = self.getBlockPos(i);

            if (pos.block != loaded_block) {
                try self.blk_dev.readBlock(self.scratch, pos.block);
                loaded_block = pos.block;
            }

            if ((self.scratch[pos.byte_offset] & (@as(u8, 1) << pos.bit_offset)) != 0) {
                try self.list.append(i);
            }
        }
    }

    fn getBlockPos(self: *FreeList, block: u32) _blockPos {
        const storage_block = self.start_blk + (block / self.entries_per_blk);
        const logical_offset = block % self.entries_per_blk;
        const byte_offset = logical_offset / 8;
        const bit_offset: u3 = @truncate(logical_offset % 8);
        return _blockPos{ .block = storage_block, .byte_offset = byte_offset, .bit_offset = bit_offset };
    }

    const _blockPos = struct {
        block: u32,
        byte_offset: u32,
        bit_offset: u3,
    };
};

// return the number of blocks required to store a freelist bitmap
fn calculateFreeListSize(blockSize: u32, blockCount: u32) u32 {
    const entriesPerBlock = blockSize * 8;
    return std.math.divCeil(u32, blockCount, entriesPerBlock) catch unreachable;
}

test "FreeList initializes correctly" {
    const a7r = std.testing.allocator;

    // at a block size of 64, each block stores the state of 512 blocks.
    // with a block count of 768, we should be using 1.5 blocks.
    const bd = try blkdev.create(a7r, 64, 768);
    defer blkdev.destroy(a7r, bd);

    const end = try FreeList.create(a7r, bd, 1);
    try std.testing.expect(end == 3);

    var fl1 = try FreeList.init(a7r, bd, 1);
    defer fl1.deinit();

    try std.testing.expect(fl1.list.items.len == 765);
    try std.testing.expect(fl1.endBlock() == 3);

    var i: u32 = 0;
    while (i < 765) : (i += 1) {
        const blk = try fl1.alloc();
        try std.testing.expect(blk == (i + 3));
    }

    if (fl1.alloc()) |blk| {
        _ = blk;
        try std.testing.expect(false);
    } else |_| {}

    // reload the freelist from the same block device and check we
    // can't allocate any more blocks

    var fl2 = try FreeList.init(a7r, bd, 1);
    defer fl2.deinit();

    if (fl2.alloc()) |blk| {
        _ = blk;
        try std.testing.expect(false);
    } else |_| {}

    //
    //
}
