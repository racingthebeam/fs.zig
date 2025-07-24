const std = @import("std");

pub const Seq = struct {
    next: i32,

    pub fn init() Seq {
        return Seq{ .next = 1 };
    }

    pub fn take(self: *@This()) i32 {
        const out = self.next;
        if (self.next == std.math.maxInt(i32)) {
            self.next = 1;
        } else {
            self.next += 1;
        }
        return out;
    }
};
