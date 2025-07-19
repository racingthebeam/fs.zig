const std = @import("std");
const expect = std.testing.expect;

const FileSystem = @import("./fs.zig").FileSystem;
const blkdev = @import("./block_device.zig");

const allocator = std.testing.allocator;

fn createFileSystem(blk_size: u32, blk_count: u32, inode_blk_count: u32) FileSystem {
    const dev = blkdev.create(allocator, blk_size, blk_count) catch @panic("failed to create block device");
    FileSystem.format(allocator, dev, inode_blk_count) catch @panic("format failed");
    const fs = FileSystem.init(allocator, dev, inode_blk_count) catch @panic("filesystem init failed");
    return fs;
}

fn cleanup(fs: *FileSystem) void {
    fs.deinit();
    blkdev.destroy(allocator, fs.blk_dev);
}

test "filesystem init" {
    var fs = createFileSystem(512, 1024, 4);
    defer cleanup(&fs);
}

test "create/delete directories" {
    var fs = createFileSystem(512, 1024, 4);
    defer cleanup(&fs);

    try expect(!try fs.exists(0, "test-1"));
    try expect(!try fs.exists(0, "test-2"));

    try fs.mkdir(0, "test-1");

    try expect(try fs.exists(0, "test-1"));
    try expect(!try fs.exists(0, "test-2"));

    try fs.mkdir(0, "test-2");

    try expect(try fs.exists(0, "test-1"));
    try expect(try fs.exists(0, "test-2"));

    try fs.rmdir(0, "test-1");

    try expect(!try fs.exists(0, "test-1"));
    try expect(try fs.exists(0, "test-2"));

    try fs.rmdir(0, "test-2");

    try expect(!try fs.exists(0, "test-1"));
    try expect(!try fs.exists(0, "test-2"));
}
