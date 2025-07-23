const builtin = @import("builtin");
const std = @import("std");

//
// Block change notification

const NotifyImpl = if (builtin.is_test) struct {
    pub fn notifyBlockChanged(device_id: i32, block: u32) void {
        std.debug.print("Block changed {}:{}\n", .{ device_id, block });
    }
} else struct {
    pub extern fn notifyBlockChanged(device_id: i32, block: u32) void;
};

pub const notifyBlockChanged = NotifyImpl.notifyBlockChanged;

//
// Time

const epoch = std.time.epoch.ios;

const NowImpl = if (builtin.is_test) struct {
    pub fn now() i64 {
        return std.time.timestamp();
    }
} else struct {
    pub extern fn now() i64;
};

pub fn now() u32 {
    return @intCast(NowImpl.now() - epoch);
}
