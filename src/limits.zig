const I = @import("internal.zig");

pub fn diskSize(blk_size: u32, blk_count: u32) u32 {
    return blk_size * blk_count;
}

pub fn blockPointersPerBlock(blk_size: u32) u32 {
    return blk_size / I.BlockPtrSize;
}

pub fn indirectThreshold(blk_size: u32) u32 {
    return (blockPointersPerBlock(blk_size) / 2) * blk_size;
}

pub fn maxFileSize(blk_size: u32) u32 {
    const direct = indirectThreshold(blk_size);
    const indirect = ((blockPointersPerBlock(blk_size) / 2) * blockPointersPerBlock(blk_size) * blk_size);
    return direct + indirect;
}

pub fn blocksForMaxFileSize(blk_size: u32) u32 {
    const index = 1;
    const indirect = blockPointersPerBlock(blk_size) / 2;

    const direct_data = blockPointersPerBlock(blk_size) / 2;
    const indirect_data = indirect * blockPointersPerBlock(blk_size);

    return index + indirect + direct_data + indirect_data;
}
