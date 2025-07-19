const std = @import("std");
const Allocator = std.mem.Allocator;

pub const BlockPool = struct {
    allocator: Allocator,
    blk_size: u32,
    avail: std.ArrayList([]u8),
    all: std.ArrayList([]u8),

    pub fn init(allocator: Allocator, blk_size: u32) BlockPool {
        return BlockPool{
            .allocator = allocator,
            .blk_size = blk_size,
            .avail = std.ArrayList([]u8).init(allocator),
            .all = std.ArrayList([]u8).init(allocator),
        };
    }

    pub fn deinit(self: *@This()) void {
        for (self.all.items) |blk| {
            self.allocator.free(blk);
        }
        self.all.deinit();
        self.avail.deinit();
    }

    pub fn take(self: *BlockPool) []u8 {
        if (self.avail.items.len == 0) {
            const blk = self.allocator.alloc(u8, self.blk_size) catch @panic("OOM");
            self.avail.append(blk) catch @panic("OOM");
            self.all.append(blk) catch @panic("OOM");
        }

        return self.avail.pop() orelse unreachable;
    }

    pub fn give(self: *BlockPool, block: []u8) void {
        self.avail.append(block) catch @panic("failed to return block to pool");
    }
};

test "block pool" {
    const expect = std.testing.expect;

    var pool = BlockPool.init(std.testing.allocator, 64);
    defer pool.deinit();

    const blk1 = pool.take();
    try expect(blk1.len == 64);
    pool.give(blk1);

    const blk2 = pool.take();
    try expect(blk1.ptr == blk2.ptr);

    const blk3 = pool.take();
    try expect(blk3.len == 64);
    try expect(blk3.ptr != blk2.ptr);

    const blk4 = pool.take();
    try expect(blk4.len == 64);
    try expect(blk4.ptr != blk3.ptr);
    try expect(blk4.ptr != blk2.ptr);
}
