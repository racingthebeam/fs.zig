const std = @import("std");
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const allocator = gpa.allocator();

//
// Shuttle buffer for transferring data between JS/WASM

// this determines the max supported block size, as well as the maximum
// number of bytes that can be read/written in a single operation.
// technically we could make this dynamic by receiving it as an init param...
pub const SHUTTLE_BUFFER_SIZE = 16384;
var shuttle_buffer: [SHUTTLE_BUFFER_SIZE]u8 = undefined;

pub export fn getShuttleBufferPtr() [*]u8 {
    return &shuttle_buffer;
}

pub export fn getShuttleBufferSize() usize {
    return SHUTTLE_BUFFER_SIZE;
}

//
// Block devices

const bd = @import("./block_device.zig");

var devices = std.AutoArrayHashMap(i32, *bd.BlockDevice).init(gpa.allocator());
var next_blk_dev_id: i32 = 1;

const NoBlockDevice = -1;
const BlockDeviceInUse = -2;
const BlockNotReady = -3;
const InternalError = -4;
const NoFS = -5;
const InvalidParam = -6;

pub export fn init() void {}

pub export fn createBlockDevice(blk_size: u32, blk_count: u32) i32 {
    if (blk_size > SHUTTLE_BUFFER_SIZE) {
        return InvalidParam;
    }

    var dev = bd.create(allocator, blk_size, blk_count) catch @panic("create block device failed");
    dev.id = next_blk_dev_id;
    next_blk_dev_id += 1;
    devices.put(dev.id, dev) catch @panic("block device put failed");

    return dev.id;
}

pub export fn destroyBlockDevice(id: i32) i32 {
    const dev = devices.get(id) orelse return NoBlockDevice;

    if (dev.ref_count > 0) {
        return BlockDeviceInUse;
    }

    std.debug.assert(devices.swapRemove(id));

    return 0;
}

pub export fn readBlock(device_id: i32, blk: u32) i32 {
    const dev = devices.get(device_id) orelse return NoBlockDevice;
    if (dev.readBlock(shuttle_buffer[0..dev.blk_size], blk)) {
        return 0;
    } else |err| {
        if (err == error.BlockNotReady) {
            return BlockNotReady;
        } else {
            unreachable;
        }
    }
}

pub export fn writeBlock(device_id: i32, blk: u32) i32 {
    const dev = devices.get(device_id) orelse return NoBlockDevice;
    dev.writeBlock(blk, shuttle_buffer[0..dev.blk_size]);
    return 0;
}

pub export fn zeroBlock(device_id: i32, blk: u32) i32 {
    const dev = devices.get(device_id) orelse return NoBlockDevice;
    dev.zeroBlock(blk);
    return 0;
}

//
// Filesystem init

const fs = @import("./fs.zig");

// open
var file_systems = std.AutoArrayHashMap(i32, *fs.FileSystem).init(gpa.allocator());
var next_fs_id: i32 = 1;

pub export fn fileSystemFormat(device_id: i32, inode_blk_count: u32) i32 {
    const dev = devices.get(device_id) orelse return NoBlockDevice;
    if (dev.ref_count > 0) {
        return BlockDeviceInUse;
    }

    fs.FileSystem.format(
        gpa.allocator(),
        dev,
        inode_blk_count,
        shuttle_buffer[0..16],
    ) catch |err| {
        return mapError(err);
    };

    return 0;
}

pub export fn fileSystemInit(device_id: i32) i32 {
    const dev = devices.get(device_id) orelse return NoBlockDevice;
    if (dev.ref_count > 0) {
        return BlockDeviceInUse;
    }

    dev.ref_count = 1;
    errdefer dev.ref_count = 0;

    const instance = allocator.create(fs.FileSystem) catch |err| return mapError(err);
    errdefer allocator.destroy(instance);

    instance.* = fs.FileSystem.init(allocator, dev, shuttle_buffer[0..16]) catch |err| return mapError(err);
    errdefer instance.*.deinit();

    const id = next_fs_id;
    file_systems.put(id, instance) catch |err| return mapError(err);
    next_fs_id += 1;

    return id;
}

pub export fn fileSystemDestroy(fs_id: i32) i32 {
    const instance = file_systems.get(fs_id) orelse return NoFS;

    instance.blk_dev.ref_count -= 1;

    instance.deinit();
    allocator.destroy(instance);
    std.debug.assert(file_systems.swapRemove(fs_id));

    return 0;
}

//
// Filesystem ops

// lookup
// exists
// stat
// mkdir
// rmdir
// opendir
// closedir
// open
// close
// seek
// tell
// read
// write
// unlink

//
// Helpers

fn mapError(_: anyerror) i32 {
    // TODO: map error values to status codes
    return -1;
}
