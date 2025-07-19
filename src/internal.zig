const std = @import("std");
const expect = std.testing.expect;

const C = @import("./common.zig");

pub const Error = error{
    FSInternalError,
    InvalidFileName,
    LimitsExceeded,
};

pub const Inode = C.Inode;
pub const InodePtr = u16;
pub const InodePtrSize = 2;

pub const BlockPtrSize = 2;

pub const OpenFile = C.OpenFile;
pub const FileFd = C.FileFd;

pub const Ref = C.Ref;

pub const MaxFilenameLen = 14;

pub const Dir = 0x0001;
pub const File = 0x0002;
pub const Executable = 0x8000;

pub const DirEntSize = 16;

pub const DirEnt = struct {
    name: [MaxFilenameLen:0]u8 = .{0} ** MaxFilenameLen,
    inode: InodePtr = 0,

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
