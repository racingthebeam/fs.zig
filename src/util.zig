const std = @import("std");

pub fn readBE(comptime T: type, src: []const u8) T {
    return std.mem.readInt(T, src[0..@sizeOf(T)], std.builtin.Endian.big);
}

pub fn writeBE(comptime T: type, dst: []u8, val: T) void {
    std.mem.writeInt(T, dst[0..@sizeOf(T)], val, std.builtin.Endian.big);
}
