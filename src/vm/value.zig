const std = @import("std");

pub const Value = union(enum) {
    number: f64,
    string: []const u8,
    boolean: bool,
    list: []Value,
    /// Internal only -- never observable from user code. Lives on the value
    /// stack while a `for` loop is executing (see `get_iter`/`for_iter` in
    /// chunk.zig).
    iterator: Iterator,

    pub const Iterator = struct {
        items: []Value,
        index: usize,
    };

    pub fn isTruthy(self: Value) bool {
        return switch (self) {
            .number => |n| n != 0,
            .string => |s| s.len != 0,
            .boolean => |b| b,
            .list => |items| items.len != 0,
            .iterator => unreachable,
        };
    }

    pub fn writeTo(self: Value, writer: *std.Io.Writer, quote_strings: bool) std.Io.Writer.Error!void {
        switch (self) {
            .number => |n| try writeNumber(n, writer),
            .boolean => |b| try writer.writeAll(if (b) "True" else "False"),
            .string => |s| {
                if (quote_strings) {
                    try writer.writeByte('\'');
                    try writer.writeAll(s);
                    try writer.writeByte('\'');
                } else {
                    try writer.writeAll(s);
                }
            },
            .list => |items| {
                try writer.writeByte('[');
                for (items, 0..) |item, i| {
                    if (i != 0) try writer.writeAll(", ");
                    try item.writeTo(writer, true);
                }
                try writer.writeByte(']');
            },
            .iterator => unreachable,
        }
    }

    fn writeNumber(n: f64, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        if (std.math.isFinite(n) and n == @trunc(n) and @abs(n) < 1e15) {
            try writer.print("{d}", .{@as(i64, @intFromFloat(n))});
        } else {
            try writer.print("{d}", .{n});
        }
    }
};
