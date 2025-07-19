const std = @import("std");

const epoch = std.time.epoch.ios;

pub fn now() u32 {
    std.time.timestamp() - epoch;
}
