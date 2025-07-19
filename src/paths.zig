const std = @import("std");
const expect = std.testing.expect;

// PathComponentIterator iterates over each component of a valid
// path, excluding the root directory.
//
// For example, the path /foo/bar/baz would yield the components
//
//   - "foo"
//   - "bar"
//   - "baz"
//   - null
//
pub const PathComponentIterator = struct {
    path: []const u8,
    index: usize,

    pub fn init(path: []const u8) PathComponentIterator {
        return PathComponentIterator{ .path = path, .index = 1 };
    }

    pub fn next(self: *PathComponentIterator) ?[]const u8 {
        if (self.index == self.path.len) {
            return null;
        }

        const index = std.mem.indexOfScalarPos(u8, self.path, self.index, '/');
        if (index) |val| {
            const out = self.path[self.index..val];
            self.index = val + 1;
            return out;
        } else {
            const out = self.path[self.index..];
            self.index = self.path.len;
            return out;
        }
    }
};

test "path component iterator" {
    var it = PathComponentIterator.init("/");
    try expect(it.next() == null);
    try expect(it.next() == null);

    it = PathComponentIterator.init("/foo/bar/baz");
    try expect(eq("foo", it.next()));
    try expect(eq("bar", it.next()));
    try expect(eq("baz", it.next()));
    try expect(it.next() == null);
    try expect(it.next() == null);
}

// TODO: decide whether we want to concern ourselves with dots here.
// I think it might be better just to allow anything at this level
// and leave handling relative directory stuff to the layers above.

const valid_extra_path_chars = "._- ,$@";

fn isValidPathFragmentChar(ch: u8) bool {
    return (ch >= 'a' and ch <= 'z') or
        (ch >= 'A' and ch <= 'Z') or
        (ch >= '0' and ch <= '9') or
        std.mem.indexOfScalar(u8, valid_extra_path_chars, ch) != null;
}

pub fn isRoot(path: []const u8) bool {
    return std.mem.eql(u8, "/", path);
}

pub fn isValidPath(path: []const u8) bool {
    if ((path.len == 0) or (path[0] != '/')) return false;
    if (path.len == 1) return true;

    var prev: u8 = '/';
    for (path[1..]) |ch| {
        if (ch == '/') {
            if (prev == '/') {
                return false;
            }
        } else if (prev == '.' and ch == '.') {
            return false;
        } else if (!isValidPathFragmentChar(ch)) {
            return false;
        }
        prev = ch;
    }

    return prev != '/';
}

test "valid paths" {
    try expect(isValidPath("/"));
    try expect(isValidPath("/foo"));
    try expect(isValidPath("/foo/bar"));
    try expect(isValidPath("/foo/bar/baz"));
    try expect(isValidPath("/foo/bar/baz.bleem"));

    try expect(!isValidPath("//"));
    try expect(!isValidPath("foo"));
    try expect(!isValidPath("//foo/bar"));
    try expect(!isValidPath("/foo/bar/baz..bleem"));
    try expect(!isValidPath("/foo//bar/baz"));
    try expect(!isValidPath("/foo/bar/baz/"));
    try expect(!isValidPath("/foo/bar/baz//"));
}

// Return the depth of a given (valid) path.
// The path of root directory is zero.
pub fn pathDepth(path: []const u8) usize {
    var depth: usize = 0;
    for (path) |ch| {
        if (ch == '/') {
            depth += 1;
        }
    }
    return depth - 1;
}

// Return the directory name of the given (valid) path, including trailing slash.
pub fn dirname(path: []const u8) []const u8 {
    if (path.len == 1) {
        return path;
    } else if (std.mem.lastIndexOfScalar(u8, path, '/')) |ix| {
        return path[0 .. ix + 1];
    } else {
        unreachable;
    }
}

fn eq(exp: []const u8, value: ?[]const u8) bool {
    if (value) |str| {
        return std.mem.eql(u8, exp, str);
    } else {
        return false;
    }
}

test "dirname" {
    try expect(eq("/", dirname("/")));
    try expect(eq("/", dirname("/foo")));
    try expect(eq("/foo/", dirname("/foo/bar")));
}

pub fn basename(path: []const u8) ?[]const u8 {
    if (path.len == 1) {
        return null;
    } else if (std.mem.lastIndexOfScalar(u8, path, '/')) |ix| {
        return path[ix + 1 ..];
    } else {
        unreachable;
    }
}

test "basename" {
    try expect(basename("/") == null);
    try expect(eq("foo", basename("/foo")));
    try expect(eq("bar", basename("/foo/bar")));
}
