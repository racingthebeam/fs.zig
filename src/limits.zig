pub fn diskSize(blk_size: u32, blk_count: u32) u32 {
    return blk_size * blk_count;
}

pub fn blockPointersPerBlock(blk_size: u32) u32 {
    return blk_size / 2;
}

pub fn indirectThreshold(blk_size: u32) u32 {
    return (blockPointersPerBlock(blk_size) / 2) * blk_size;
}

pub fn maxFileSize(blk_size: u32) u32 {
    const direct = indirectThreshold(blk_size);
    const indirect = ((blockPointersPerBlock(blk_size) / 2) * blockPointersPerBlock(blk_size) * blk_size);

    // the current implementation automatically allocates a block
    // when we hit the end so the max size is actually one byte less.
    return direct + indirect - 1;
}
