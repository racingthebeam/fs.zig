const std = @import("std");
const math = std.math;
const Allocator = std.mem.Allocator;

const notifyBlockChanged = @import("./wasm.zig").notifyBlockChanged;

pub const BlockDeviceInitError = error{InvalidBlockDeviceParams};
pub const BlockDeviceAccessError = error{BlockNotReady};

pub fn create(allocator: Allocator, blk_size: u32, blk_count: u32) !*BlockDevice {
    const ptr = try allocator.create(BlockDevice);
    errdefer allocator.destroy(ptr);

    ptr.* = try BlockDevice.init(allocator, blk_size, blk_count);
    return ptr;
}

pub fn destroy(allocator: Allocator, blk_dev: *BlockDevice) void {
    blk_dev.deinit();
    allocator.destroy(blk_dev);
}

pub const BlockDevice = struct {
    allocator: Allocator,
    blk_size: u32,
    blk_count: u32,
    data: []u8,

    id: i32, // for external use; if > 0, notification is enabled
    ref_count: u32, // for external use

    pub fn init(allocator: Allocator, blk_size: u32, blk_count: u32) (BlockDeviceInitError || error{OutOfMemory})!BlockDevice {
        if (!math.isPowerOfTwo(blk_size)) {
            return error.InvalidBlockDeviceParams;
        }

        const data_len = blk_size * blk_count;
        const data = try allocator.alloc(u8, data_len);
        @memset(data, 0);

        return BlockDevice{
            .allocator = allocator,
            .blk_size = blk_size,
            .blk_count = blk_count,
            .data = data,

            .ref_count = 0,
            .id = 0,
        };
    }

    pub fn deinit(self: *@This()) void {
        self.allocator.free(self.data);
    }

    pub fn readBlock(self: *BlockDevice, dst: []u8, block: u32) BlockDeviceAccessError!void {
        self.validateBlock(block);
        self.validateSlice(dst);

        const start = block * self.blk_size;
        @memcpy(dst, self.data[start .. start + self.blk_size]);
    }

    pub fn writeBlock(self: *BlockDevice, block: u32, src: []u8) void {
        self.validateBlock(block);
        self.validateSlice(src);

        const start = block * self.blk_size;
        @memcpy(self.data[start .. start + self.blk_size], src);

        self.notify(block);
    }

    pub fn zeroBlock(self: *BlockDevice, block: u32) void {
        self.validateBlock(block);

        const start = block * self.blk_size;
        @memset(self.data[start .. start + self.blk_size], 0);

        self.notify(block);
    }

    fn validateBlock(self: *BlockDevice, block: u32) void {
        if (block >= self.blk_count) {
            @panic("attempted to read or write invalid block");
        }
    }

    fn validateSlice(self: *BlockDevice, slice: []u8) void {
        if (slice.len < self.blk_size) {
            @panic("slice size is less than block size");
        }
    }

    fn notify(self: *BlockDevice, block: u32) void {
        if (self.id > 0) {
            notifyBlockChanged(self.id, block);
        }
    }
};

test "block device" {
    const expect = std.testing.expect;

    const bd = try create(std.testing.allocator, 64, 128);
    defer destroy(std.testing.allocator, bd);

    try expect(bd.*.data.len == 64 * 128);

    var buf = [_]u8{0} ** 64;
    // what the fuck.
    var known_at_runtime_zero: usize = 0;
    _ = &known_at_runtime_zero;
    const buf_slice = buf[known_at_runtime_zero..buf.len];

    try bd.*.readBlock(buf_slice, 0);

    for (buf_slice) |b| {
        try expect(b == 0);
    }

    for (buf_slice) |*b| {
        b.* = 100;
    }

    bd.*.writeBlock(100, buf_slice);
    @memset(buf_slice, 0);

    try bd.*.readBlock(buf_slice, 100);

    for (buf_slice) |b| {
        try expect(b == 100);
    }

    bd.*.zeroBlock(100);

    try bd.*.readBlock(buf_slice, 100);

    for (buf_slice) |b| {
        try expect(b == 0);
    }
}
