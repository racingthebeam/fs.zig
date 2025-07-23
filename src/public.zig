pub const Fd = u64;
pub const InodePtr = u32;

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
