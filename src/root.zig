const std = @import("std");
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const allocator = gpa.allocator();

const P = @import("public.zig");
const I = @import("internal.zig");
const U = @import("util.zig");

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
// String buffer for sending strings from JS

pub const STRING_BUFFER_SIZE = 1024;
var string_buffer: [STRING_BUFFER_SIZE]u8 = undefined;

pub export fn getStringBufferPtr() [*]u8 {
    return &string_buffer;
}

pub export fn getStringBufferSize() usize {
    return STRING_BUFFER_SIZE;
}

//
// Block devices

const bd = @import("./block_device.zig");

var devices = std.AutoArrayHashMap(i32, *bd.BlockDevice).init(gpa.allocator());
var next_blk_dev_id: i32 = 1;

const E_NODEV = -1;
const E_DEVICEBUSY = -2;
const E_NOTREADY = -3;
const E_INTERNAL = -4;
const E_NOFS = -5;
const E_PARAM = -6;
const E_NOENT = -7;

pub export fn init() void {}

//
// Low level helpers

pub export fn alloc(size: usize) ?[*]u8 {
    const slice = allocator.alloc(u8, size) catch return null;
    return slice.ptr;
}

pub export fn free(ptr: [*]u8, size: usize) void {
    allocator.free(ptr[0..size]);
}

//
//

pub export fn createBlockDevice(blk_size: u32, blk_count: u32) i32 {
    if (blk_size > SHUTTLE_BUFFER_SIZE) {
        return E_PARAM;
    }

    var dev = bd.create(allocator, blk_size, blk_count) catch @panic("create block device failed");
    dev.id = next_blk_dev_id;
    next_blk_dev_id += 1;
    devices.put(dev.id, dev) catch @panic("block device put failed");

    return dev.id;
}

pub export fn destroyBlockDevice(id: i32) i32 {
    const dev = devices.get(id) orelse return E_NODEV;

    if (dev.ref_count > 0) {
        return E_DEVICEBUSY;
    }

    std.debug.assert(devices.swapRemove(id));

    return 0;
}

pub export fn readBlock(device_id: i32, blk: u32) i32 {
    const dev = devices.get(device_id) orelse return E_NODEV;
    if (dev.readBlock(shuttle_buffer[0..dev.blk_size], blk)) {
        return 0;
    } else |err| {
        if (err == error.BlockNotReady) {
            return E_NOTREADY;
        } else {
            unreachable;
        }
    }
}

pub export fn writeBlock(device_id: i32, blk: u32) i32 {
    const dev = devices.get(device_id) orelse return E_NODEV;
    dev.writeBlock(blk, shuttle_buffer[0..dev.blk_size]);
    return 0;
}

pub export fn zeroBlock(device_id: i32, blk: u32) i32 {
    const dev = devices.get(device_id) orelse return E_NODEV;
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
    const dev = devices.get(device_id) orelse return E_NODEV;
    if (dev.ref_count > 0) {
        return E_DEVICEBUSY;
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
    const dev = devices.get(device_id) orelse return E_NODEV;
    if (dev.ref_count > 0) {
        return E_DEVICEBUSY;
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
    const instance = file_systems.get(fs_id) orelse return E_NOFS;

    instance.blk_dev.ref_count -= 1;

    instance.deinit();
    allocator.destroy(instance);
    std.debug.assert(file_systems.swapRemove(fs_id));

    return 0;
}

//
// Filesystem ops

pub export fn fsLookup(fs_id: i32, inode: i32, name: [*]u8, name_len: usize) i32 {
    const f = file_systems.get(fs_id) orelse return E_NOFS;
    if (f.lookup(inodeFromJS(inode), name[0..name_len]) catch |err| return mapError(err)) |found_inode| {
        return inodeToJS(found_inode);
    } else {
        return E_NOENT;
    }
}

pub export fn fsStat(fs_id: i32, inode: i32) i32 {
    const f = file_systems.get(fs_id) orelse return E_NOFS;
    var stat = P.Stat{};
    f.stat(&stat, inodeFromJS(inode)) catch |err| return mapError(err);
    return @intCast(shuttleStat(&stat));
}

pub export fn fsExists(fs_id: i32, inode: i32, name: [*]u8, name_len: usize) i32 {
    const f = file_systems.get(fs_id) orelse return E_NOFS;
    if (f.exists(inodeFromJS(inode), name[0..name_len]) catch |err| return mapError(err)) {
        return 1;
    } else {
        return 0;
    }
}

//
// File

pub export fn fsOpen(fs_id: i32, inode: i32, name: [*]u8, name_len: usize, flags: u32) i32 {
    const f = file_systems.get(fs_id) orelse return E_NOFS;
    const fd = f.open(inodeFromJS(inode), name[0..name_len], flags) catch |err| return mapError(err);
    return fdToJS(fd);
}

pub export fn fsClose(fs_id: i32, fd: i32) i32 {
    const f = file_systems.get(fs_id) orelse return E_NOFS;
    f.close(fdFromJS(fd)) catch |err| return mapError(err);
    return 0;
}

pub export fn fsUnlink(fs_id: i32, dir_inode_ptr: i32, name: [*]u8, name_len: usize) i32 {
    const f = file_systems.get(fs_id) orelse return E_NOFS;
    f.unlink(inodeFromJS(dir_inode_ptr), name[0..name_len]) catch |err| return mapError(err);
    return 0;
}

pub export fn fsTell(fs_id: i32, fd: i32) i32 {
    const f = file_systems.get(fs_id) orelse return E_NOFS;
    const pos = f.tell(fdFromJS(fd)) catch |err| return mapError(err);
    return @intCast(pos);
}

pub export fn fsEof(fs_id: i32, fd: i32) i32 {
    const f = file_systems.get(fs_id) orelse return E_NOFS;
    const eof = f.eof(fdFromJS(fd)) catch |err| return mapError(err);
    return if (eof) 1 else 0;
}

pub export fn fsSeek(fs_id: i32, fd: i32, offset: u32) i32 {
    const f = file_systems.get(fs_id) orelse return E_NOFS;
    f.seek(fdFromJS(fd), offset) catch |err| return mapError(err);
    return 0;
}

pub export fn fsRead(fs_id: i32, fd: i32, len: u32) i32 {
    const f = file_systems.get(fs_id) orelse return E_NOFS;
    const read = f.read(shuttle_buffer[0..len], fdFromJS(fd)) catch |err| return mapError(err);
    return @intCast(read[0]);
}

pub export fn fsWrite(fs_id: i32, fd: i32, len: u32) i32 {
    const f = file_systems.get(fs_id) orelse return E_NOFS;
    const written = f.write(fdFromJS(fd), shuttle_buffer[0..len]) catch |err| return mapError(err);
    return @intCast(written);
}

//
// Directory

pub export fn fsMkdir(fs_id: i32, inode: i32, name: [*]u8, name_len: usize) i32 {
    const f = file_systems.get(fs_id) orelse return E_NOFS;
    const new_inode = f.mkdir(inodeFromJS(inode), name[0..name_len]) catch |err| return mapError(err);
    return inodeToJS(new_inode);
}

pub export fn fsRmdir(fs_id: i32, inode: i32, name: [*]u8, name_len: usize) i32 {
    const f = file_systems.get(fs_id) orelse return E_NOFS;
    f.rmdir(inodeFromJS(inode), name[0..name_len]) catch |err| return mapError(err);
    return 0;
}

pub export fn fsOpendir(fs_id: i32, inode: i32) i32 {
    const f = file_systems.get(fs_id) orelse return E_NOFS;
    const fd = f.opendir(inodeFromJS(inode)) catch |err| return mapError(err);
    return fdToJS(fd);
}

pub export fn fsClosedir(fs_id: i32, fd: i32) i32 {
    const f = file_systems.get(fs_id) orelse return E_NOFS;
    f.closedir(fdFromJS(fd)) catch |err| return mapError(err);
    return 0;
}

// read next directory entry from an open directory
// on success, the file stat is copied into the shuttle buffer and its length returned
// on EOF, returns 0 (no more entries left in dir)
// on other error, returns < 0
pub export fn fsReaddir(fs_id: i32, fd: i32) i32 {
    const f = file_systems.get(fs_id) orelse return E_NOFS;
    var stat = P.Stat{};
    const ok = f.readdir(&stat, fdFromJS(fd)) catch |err| return mapError(err);
    if (ok) {
        return @intCast(shuttleStat(&stat));
    } else {
        return 0; // EOF
    }
}

//
// Helpers

// encode the given P.Stat into the shuttle buffer
fn shuttleStat(s: *P.Stat) usize {
    var stream = std.io.fixedBufferStream(shuttle_buffer[0..]);
    const w = stream.writer();
    _ = w.writeAll(s.filename[0 .. I.MaxFilenameLen + 1]) catch unreachable; // include null terminator
    _ = w.writeByte(s.typ) catch unreachable;
    _ = w.writeByte(if (s.executable) 1 else 0) catch unreachable;
    _ = w.writeInt(u32, s.mtime, std.builtin.Endian.big) catch unreachable;
    _ = w.writeInt(u32, s.size, std.builtin.Endian.big) catch unreachable;
    return stream.pos;
}

fn mapError(err: anyerror) i32 {
    return switch (err) {
        error.NameTooLong => -1,
        error.InvalidOffset => -2,
        error.IsDir => -3,
        error.NotDir => -4,
        error.NoEnt => E_NOENT,
        error.Exists => -5,
        error.NoSpace => -6,
        error.InvalidFSParams => -7,
        error.Busy => -8,
        error.NotReadable => -9,
        error.NotWritable => -10,
        error.NoFreeInodes => -11,
        error.InvalidFileHandle => -12,
        error.FatalInternalError => -13,
        else => E_INTERNAL,
    };
}

fn inodeToJS(inode: P.InodePtr) i32 {
    return @intFromEnum(inode);
}

fn inodeFromJS(js: i32) P.InodePtr {
    return @enumFromInt(js);
}

fn fdToJS(fd: P.Fd) i32 {
    return @intFromEnum(fd);
}

fn fdFromJS(js: i32) P.Fd {
    return @enumFromInt(js);
}
