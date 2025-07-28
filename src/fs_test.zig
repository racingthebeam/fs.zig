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

const std = @import("std");
const expect = std.testing.expect;

const FileSystem = @import("./fs.zig").FileSystem;
const blkdev = @import("./block_device.zig");

const allocator = std.testing.allocator;

const P = @import("public.zig");
const L = @import("limits.zig");

fn createFileSystem(blk_size: u32, blk_count: u32, inode_blk_count: u32) FileSystem {
    const dev = blkdev.create(allocator, blk_size, blk_count) catch @panic("failed to create block device");
    var params = [_]u8{0} ** 16;
    FileSystem.format(allocator, dev, inode_blk_count, params[0..16]) catch @panic("format failed");
    const fs = FileSystem.init(allocator, dev, params[0..16]) catch @panic("filesystem init failed");
    return fs;
}

fn cleanup(fs: *FileSystem) void {
    fs.deinit();
    blkdev.destroy(allocator, fs.blk_dev);
}

// test "filesystem init" {
//     var fs = createFileSystem(512, 1024, 8);
//     defer cleanup(&fs);
// }

// test "create/delete directories" {
//     var fs = createFileSystem(512, 1024, 8);
//     defer cleanup(&fs);

//     try expect(!try fs.exists(0, "test-1"));
//     try expect(!try fs.exists(0, "test-2"));

//     _ = try fs.mkdir(0, "test-1");

//     try expect(try fs.exists(0, "test-1"));
//     try expect(!try fs.exists(0, "test-2"));

//     var did_fail = false;
//     _ = fs.mkdir(0, "test-1") catch {
//         did_fail = true;
//     };

//     try expect(did_fail);

//     _ = try fs.mkdir(0, "test-2");

//     try expect(try fs.exists(0, "test-1"));
//     try expect(try fs.exists(0, "test-2"));

//     try fs.rmdir(0, "test-1");

//     try expect(!try fs.exists(0, "test-1"));
//     try expect(try fs.exists(0, "test-2"));

//     try fs.rmdir(0, "test-2");

//     try expect(!try fs.exists(0, "test-1"));
//     try expect(!try fs.exists(0, "test-2"));
// }

fn writeMaxSizeFile(fs: *FileSystem, name: []const u8) P.Fd {
    const maxFileSize = L.maxFileSize(fs.blk_size);
    std.debug.print("Max file size: {}\n", .{maxFileSize});

    const inode = fs.create(@enumFromInt(0), name) catch @panic("create file failed");
    std.debug.print("New file inode: {}\n", .{inode});

    var writeBuffer: [64]u8 = undefined;
    for (&writeBuffer, 0..) |*v, i| {
        v.* = @truncate(i);
    }

    const fd = fs.open(inode, 0) catch @panic("failed to open file");

    var totalWritten: u32 = 0;
    while (totalWritten < maxFileSize) {
        const bytesToWrite = @min(maxFileSize - totalWritten, writeBuffer.len);
        const w = fs.write(fd, writeBuffer[0..bytesToWrite]) catch @panic("write failed");
        totalWritten += w;
    }

    return fd;
}

test "write max size file" {
    var fs = createFileSystem(128, 4096, 32);
    defer cleanup(&fs);

    const fd = writeMaxSizeFile(&fs, "test");

    var byte: [1]u8 = .{0xFF};
    try std.testing.expectError(error.NoSpace, fs.write(fd, byte[0..1]));

    try fs.close(fd);
}

test "deleting file releases blocks" {
    var fs = createFileSystem(128, 4096, 32);
    defer cleanup(&fs);

    // check block usage
    const free_blocks_before = fs.freelist.freeBlockCount();
    const fd = writeMaxSizeFile(&fs, "test");
    try fs.close(fd);
    const free_blocks_after = fs.freelist.freeBlockCount();
    const blocks_used = free_blocks_before - free_blocks_after;
    try std.testing.expect(blocks_used == L.blocksForMaxFileSize(fs.blk_size));

    // delete the file and ensure all the blocks are returned
    try fs.unlink(@enumFromInt(0), "test");
    try std.testing.expect(fs.freelist.freeBlockCount() == free_blocks_before);
}
