pub const Fd = u64;
pub const InodePtr = u32;

// unique ID that identifies this filesystem type
pub const FsTypeId = 1;

pub const Error = error{
    InvalidFileName,
    InvalidOffset,
    IsDir,
    NoEnt,
    Exists,
    UsageError,
    InvalidHandle,
    NoSpace,
    InvalidFSParams,
};
