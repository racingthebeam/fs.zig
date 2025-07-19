const Hnd = @import("common.zig").Hnd;

pub const Seq = struct {
    val: Hnd = 1,

    pub fn take(self: *@This()) Hnd {
        const out = self.val;
        self.val += 1;
        return out;
    }
};
