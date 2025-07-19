const builtin = @import("builtin");
const std = @import("std");

pub usingnamespace if (builtin.is_test) struct {
    pub fn notifyBlockChanged(device_id: i32, block: u32) void {
        std.debug.print("Block changed {}:{}\n", .{ device_id, block });
    }
} else struct {
    pub extern fn notifyBlockChanged(device_id: i32, block: u32) void;
};
