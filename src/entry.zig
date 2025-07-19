const std = @import("std");
const expect = std.testing.expect;

const readBE = @import("./util.zig").readBE;
const writeBE = @import("./util.zig").writeBE;

const Error = @import("./common.zig").Error;

// Size of a directory entry
pub const DirEntSize = 32;

pub const FlagDir: u16 = 0x01;

const MaxFilenameLen = 16;

pub const DirEnt = struct {
    name: [MaxFilenameLen:0]u8 = .{0} ** MaxFilenameLen,
    data_inode: u16 = 0,
    meta_inode: u16 = 0,
    modified: u32 = 0,
    size: u32 = 0,
    flags: u16 = 0,

    pub fn isDir(self: *DirEnt) bool {
        return self.flags & FlagDir > 0;
    }

    pub fn setName(self: *DirEnt, newName: []const u8) !void {
        if (newName.len > MaxFilenameLen) {
            return Error.InvalidFileName;
        }

        // TODO: work out how to do this properly in Zig

        var i: u32 = 0;
        while (i < newName.len) : (i += 1) {
            self.name[i] = newName[i];
        }

        while (i < MaxFilenameLen) : (i += 1) {
            self.name[i] = 0;
        }
    }

    pub fn isName(self: *DirEnt, name: []const u8) bool {
        if (name.len > MaxFilenameLen) {
            return false;
        }

        // TODO: work out how to do this properly in Zig

        var i: u32 = 0;
        while (i < name.len) : (i += 1) {
            if (self.name[i] != name[i]) {
                return false;
            }
        }

        return true;
    }
};

test "isName" {
    var ent = DirEnt{};
    try ent.setName("hotdog");

    try expect(ent.isName("hotdog"));
    try expect(!ent.isName("not-hotdog"));
    try expect(!ent.isName("this is a very long filename far longer than the longest we allow"));
}

pub const DirEntRef = struct {
    ref: @import("./common.zig").Ref,
    ent: DirEnt,
};

const offset_name = 0;
const length_name = MaxFilenameLen;
const offset_data_inode = MaxFilenameLen;
const offset_meta_inode = offset_data_inode + 2;
const offset_modified = offset_meta_inode + 2;
const offset_size = offset_modified + 4;
const offset_flags = offset_size + 4;

pub fn readDirEnt(ent: *DirEnt, src: []const u8) void {
    @memcpy(&ent.name, src[0..length_name]);
    ent.data_inode = readBE(u16, src[offset_data_inode .. offset_data_inode + 2]);
    ent.meta_inode = readBE(u16, src[offset_meta_inode .. offset_meta_inode + 2]);
    ent.modified = readBE(u32, src[offset_modified .. offset_modified + 4]);
    ent.size = readBE(u32, src[offset_size .. offset_size + 4]);
    ent.flags = readBE(u16, src[offset_flags .. offset_flags + 2]);
}

test "readDirEnt" {
    const buf = [_]u8{
        'h', 'e', 'l', 'l', 'o', 0, 0, 0,
        0,   0,   0,   0,   0,   0, 0, 0,
        0x1, 0x2, // data
        0x3, 0x4, // meta
        0x5, 0x6, 0x7, 0x8, // modified
        0x9, 0xa, 0xb, 0xc, // size
        0xd, 0xe, // flags
        0, 0, // unused
    };

    var ent = DirEnt{};

    readDirEnt(&ent, &buf);

    try expect(ent.isName("hello"));
    try expect(ent.data_inode == 0x0102);
    try expect(ent.meta_inode == 0x0304);
    try expect(ent.modified == 0x05060708);
    try expect(ent.size == 0x090a0b0c);
    try expect(ent.flags == 0x0d0e);
}

pub fn writeDirEnt(dst: []u8, ent: *DirEnt) void {
    @memcpy(dst[0..length_name], &ent.*.name);
    writeBE(u16, dst[offset_data_inode .. offset_data_inode + 2], ent.*.data_inode);
    writeBE(u16, dst[offset_meta_inode .. offset_meta_inode + 2], ent.*.meta_inode);
    writeBE(u32, dst[offset_modified .. offset_modified + 4], ent.*.modified);
    writeBE(u32, dst[offset_size .. offset_size + 4], ent.*.size);
    writeBE(u16, dst[offset_flags .. offset_flags + 2], ent.*.flags);
    dst[30] = 0;
    dst[31] = 0;
}

test "writeDirEnt" {
    var ent = DirEnt{ .data_inode = 0x0201, .meta_inode = 0x0403, .modified = 0x08070605, .size = 0x0c0b0a09, .flags = 0x0e0d };
    ent.setName("boomtime") catch unreachable;

    var buf = [_]u8{255} ** 32;

    writeDirEnt(&buf, &ent);

    const expected = [_]u8{
        'b', 'o', 'o', 'm', 't', 'i', 'm', 'e',
        0,   0,   0,   0,   0,   0,   0,   0,
        0x02, 0x01, // data
        0x04, 0x03, // meta
        0x08, 0x07, 0x06, 0x05, // mod
        0x0c, 0x0b, 0x0a, 0x09, // size
        0x0e, 0x0d, // flags
        0, 0, // unused
    };

    try expect(std.mem.eql(u8, &buf, &expected));
}

pub fn readContinuationPtr(blk_data: []const u8) u16 {
    return readBE(u16, blk_data[blk_data.len - 2 .. blk_data.len]);
}

pub fn writeContinuationPtr(blk_data: []u8, ptr: u16) void {
    writeBE(u16, blk_data[blk_data.len - 2 .. blk_data.len], ptr);
}
