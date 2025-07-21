const Fd = @import("public.zig").Fd;

pub const Seq = struct {
    val: Fd,

    pub fn init() Seq {
        return Seq{ .val = 1 };
    }

    pub fn take(self: *@This()) Fd {
        const out = self.val;
        self.val += 1;
        return out;
    }
};
