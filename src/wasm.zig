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
