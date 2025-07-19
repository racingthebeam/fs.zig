// Public error types

pub const MaxPathComponentLen = 16;

pub const INode = u32;

// Public handle to an open file/directory
pub const Hnd = u64;

pub const BlockPtrSize = 2;

// Ref is a pointer to a specific byte on disk, expressed in
// terms of block:offset.
pub const Ref = struct {
    blk: u32 = 0,
    offset: u32 = 0,
};

pub const OpenFlags = enum(u32) {
    Read = 1,
    Write = 2,
    Create = 4,
    Truncate = 8,
    SeekEnd = 16,
};

pub const InodePtr = u32;

pub const Dir = 0x0001;
pub const File = 0x0002;
pub const Executable = 0x8000;

pub const Inode = struct {
    flags: u16 = 0,
    data_blk: u16 = 0,
    meta_blk: u16 = 0,
    size: u32 = 0,
    mtime: u32 = 0,

    pub fn init() Inode {
        return Inode{
            .flags = undefined,
            .data_blk = undefined,
            .meta_blk = undefined,
            .size = undefined,
            .mtime = undefined,
        };
    }

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
    // inode ptr
    inode_ptr: u16,

    root_blk: u16,

    // current size of file
    size: u32,

    // was this file deleted while it was open?
    deleted: bool = false,

    // number of FileFd instances that reference this file
    ref_count: u32 = 1,
};

pub const FileFd = struct {
    file: *OpenFile = undefined,
    flags: u32 = undefined,

    root: Ref = undefined, // position in the root block
    mid: Ref = undefined, // position in the indirect block (only valid when deep == true)
    data: Ref = undefined, // position in the data block
    abs_offset: u32 = undefined,
    deep: bool = undefined,

    // Initialize a FileFd with the given handle, open file, and flags.
    // The root, mid, and data pointers are zeroed.
    pub fn init(file: *OpenFile, flags: OpenFlags) FileFd {
        return FileFd{
            .file = file,
            .flags = flags,

            .root = Ref{},
            .mid = Ref{},
            .data = Ref{},
            .abs_offset = 0,
            .deep = false,
        };
    }
};

// pub const OpenDir = struct {
//     root_blk: u32,
//     ref_count: u32 = 1,
// };

// pub const DirFd = struct {
//     hnd: Hnd,
//     dir: *OpenDir,

//     pub fn init(hnd: Hnd, dir: *OpenDir) DirFd {
//         return DirFd{
//             .hnd = hnd,
//             .dir = dir,
//         };
//     }
// };
