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

pub const Fd = enum(i32) { _ };
pub const InodePtr = enum(i32) { _ };

// unique ID that identifies this filesystem type
pub const FS_TYPE_ID = 1;

pub const CREATE = 1;
pub const SEEK_END = 2;
pub const TRUNCATE = 4;
pub const READ = 8;
pub const WRITE = 16;

pub const Error = error{
    NameTooLong,
    InvalidOffset,
    IsDir,
    NotDir,
    NoEnt,
    Exists,
    NoSpace,
    InvalidFSParams,
    Busy,
    NotReadable,
    NotWritable,
    NoFreeInodes,
    InvalidFileHandle,

    FatalInternalError,
};

const I = @import("internal.zig");

pub const FILE_TYPE_FILE = 1;
pub const FILE_TYPE_DIR = 2;

pub const Stat = struct {
    filename: [I.MaxFilenameLen:0]u8 = undefined,
    inode: InodePtr = undefined,
    typ: u8 = undefined,
    executable: bool = undefined,
    mtime: u32 = undefined,
    size: u32 = undefined,

    pub fn setFromInode(self: *Stat, inode: *I.Inode) void {
        self.typ = if (inode.isDir()) FILE_TYPE_DIR else FILE_TYPE_FILE;
        self.executable = false;
        self.mtime = inode.mtime;
        self.size = inode.size;
    }
};
