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

const P = @import("public.zig");

pub const Error = error{
    FSInternalError,
    InvalidFileName,
    LimitsExceeded,
};

//
// Block pointer

pub const BlockPtr = u16;
pub const BlockPtrSize = @sizeOf(BlockPtr);

//
// Inodes

pub const Dir = 0x0001;
pub const File = 0x0002;
pub const Executable = 0x8000;

pub const InodePtr = u16;
pub const InodePtrSize = @sizeOf(InodePtr);
pub const Inode = struct {
    flags: u16 = 0,
    data_blk: u16 = 0,
    meta_blk: u16 = 0,
    size: u32 = 0,
    mtime: u32 = 0,

    pub fn isPresent(self: *const @This()) bool {
        return self.flags != 0;
    }

    pub fn isDir(self: *const @This()) bool {
        return (self.flags & Dir) > 0;
    }

    pub fn isFile(self: *const @This()) bool {
        return (self.flags & File) > 0;
    }
};

// Represents the shared global state for an open file.
// A file can have multiple active FileFds, but only ever
// one OpenFile.
pub const OpenFile = struct {
    inode_ptr: u16, // inode ptr
    root_blk: u16, // root data block (cached from inode)
    size: u32, // current size of file
    deleted: bool = false, // was this file deleted while it was open?
    ref_count: u32 = 1, // number of FileFd instances that reference this file
};

pub const FileFd = struct {
    of: *OpenFile = undefined,
    flags: u32 = undefined,

    // indicates the root, mid, and data Refs are invalid and must be recalculated.
    // set this to true after seek so that we can delay block offset calculation
    // until there's guaranteed to be a valid block
    refs_invalid: bool = undefined,
    root: Ref = undefined, // position in the root block
    mid: Ref = undefined, // position in the indirect block (only valid when deep == true)
    data: Ref = undefined, // position in the data block
    abs_offset: u32 = undefined,
    deep: bool = undefined,
};

// Ref is a pointer to a specific byte on disk, expressed in terms of block:offset.
pub const Ref = struct {
    blk: u32 = 0,
    offset: u32 = 0,
};

pub const MaxFilenameLen = 14;
pub const DirEntSize = MaxFilenameLen + InodePtrSize;

comptime {
    if (DirEntSize != 16) {
        @compileError("DirEntSize must be 16");
    }
}

pub const DirEnt = struct {
    name: [MaxFilenameLen:0]u8 = .{0} ** MaxFilenameLen,
    inode: InodePtr = 0,

    pub fn isEmpty(self: *DirEnt) bool {
        return self.name[0] == 0;
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

pub fn noBlock(_: error{BlockNotReady}) noreturn {
    @panic("NO BLOCK");
}

pub fn oom(_: error{OutOfMemory}) noreturn {
    @panic("OOM");
}

pub fn publicInodePtrToInternal(p: P.InodePtr) InodePtr {
    const as_int = @intFromEnum(p);
    return @intCast(as_int);
}

pub fn internalInodePtrToPublic(p: InodePtr) P.InodePtr {
    return @enumFromInt(p);
}
