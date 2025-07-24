// fs.zig - a simple filesystem on top of a memory-backed block store
// Copyright (C) 2025 rtb

// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.

// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

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
