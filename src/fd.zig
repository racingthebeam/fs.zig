const std = @import("std");

const P = @import("public.zig");
const Hnd = P.Fd;

const I = @import("internal.zig");

const Seq = @import("seq.zig").Seq;

pub const FileFds = fdSet(I.FileFd);

fn fdSet(comptime T: type) type {
    return struct {
        const Map = std.AutoHashMap(Hnd, *T);

        allocator: std.mem.Allocator,
        fds: Map,
        seq: *Seq,

        pub fn init(allocator: std.mem.Allocator, seq: *Seq) @This() {
            return @This(){
                .allocator = allocator,
                .fds = Map.init(allocator),
                .seq = seq,
            };
        }

        pub fn deinit(self: *@This()) void {
            var it = self.fds.valueIterator();
            while (it.next()) |desc| {
                self.allocator.destroy(desc);
            }
            self.fds.deinit();
        }

        pub fn get(self: *@This(), hnd: Hnd) ?*T {
            return self.fds.get(hnd);
        }

        pub fn add(self: *@This()) !struct { Hnd, *T } {
            const ptr = try self.allocator.create(T);
            const hnd = self.seq.take();
            try self.fds.put(hnd, ptr);
            return .{ hnd, ptr };
        }

        pub fn delete(self: *@This(), hnd: Hnd) bool {
            if (self.fds.fetchRemove(hnd)) |ent| {
                self.allocator.destroy(ent.value);
                return true;
            } else {
                return false;
            }
        }
    };
}

test "FdSet" {
    const expect = std.testing.expect;

    var seq = Seq{};
    const expected_hnd = seq.val;

    var fds = FileFds.init(std.testing.allocator, &seq);
    defer fds.deinit();

    const f1 = try fds.add();
    try expect(f1[0] == expected_hnd);

    const f2 = fds.get(expected_hnd);
    try expect(f2 != null);
    try expect(f1[1] == f2.?);

    try expect(fds.delete(expected_hnd));
    try expect(fds.get(expected_hnd) == null);

    try expect(!fds.delete(expected_hnd));
}
