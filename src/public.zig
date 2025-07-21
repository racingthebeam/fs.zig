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
    InvalidFileName,
    InvalidOffset,
    IsDir,
    NotDir,
    NoEnt,
    Exists,
    UsageError,
    InvalidHandle,
    NoSpace,
    InvalidFSParams,
    Busy,
    NotReadable,
    NotWritable,
    NoFreeInodes,
};
