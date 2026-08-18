const std = @import("std");
const value_mod = @import("value.zig");
const Value = value_mod.Value;
const chunk_mod = @import("chunk.zig");
const Instruction = chunk_mod.Instruction;
const Chunk = chunk_mod.Chunk;

pub const RuntimeError = error{
    UndefinedName,
    TypeMismatch,
    DivisionByZero,
    NotIterable,
} || std.mem.Allocator.Error || std.Io.Writer.Error;

/// Holds the locals and value stack for one level of execution. There is
/// only ever one Frame today (no function calls yet), but keeping the
/// state bundled here means adding a call stack of Frames later doesn't
/// require restructuring the VM.
pub const Frame = struct {
    locals: std.StringHashMap(Value),
    stack: std.ArrayList(Value) = .empty,

    pub fn init(allocator: std.mem.Allocator) Frame {
        return .{ .locals = std.StringHashMap(Value).init(allocator) };
    }

    pub fn deinit(self: *Frame, allocator: std.mem.Allocator) void {
        self.locals.deinit();
        self.stack.deinit(allocator);
    }
};

pub const VM = struct {
    allocator: std.mem.Allocator,
    frame: Frame,

    pub fn init(allocator: std.mem.Allocator) VM {
        return .{ .allocator = allocator, .frame = Frame.init(allocator) };
    }

    pub fn deinit(self: *VM) void {
        self.frame.deinit(self.allocator);
    }

    pub fn run(self: *VM, chunk: Chunk, writer: *std.Io.Writer) RuntimeError!void {
        var ip: usize = 0;
        while (ip < chunk.code.len) {
            const instr = chunk.code[ip];
            ip += 1;
            switch (instr) {
                .push_number => |n| try self.push(.{ .number = n }),
                .push_string => |s| try self.push(.{ .string = s }),
                .push_bool => |b| try self.push(.{ .boolean = b }),
                .load_name => |name| {
                    const v = self.frame.locals.get(name) orelse return RuntimeError.UndefinedName;
                    try self.push(v);
                },
                .store_name => |name| {
                    const v = self.pop();
                    try self.frame.locals.put(name, v);
                },
                .add => try self.binaryArith(.add),
                .sub => try self.binaryArith(.sub),
                .mul => try self.binaryArith(.mul),
                .div => try self.binaryArith(.div),
                .mod => try self.binaryArith(.mod),
                .neg => {
                    const v = self.pop();
                    if (v != .number) return RuntimeError.TypeMismatch;
                    try self.push(.{ .number = -v.number });
                },
                .eq => try self.compare(.eq),
                .ne => try self.compare(.ne),
                .lt => try self.compare(.lt),
                .le => try self.compare(.le),
                .gt => try self.compare(.gt),
                .ge => try self.compare(.ge),
                .build_list => |count| try self.buildList(count),
                .print => |count| try self.doPrint(count, writer),
                .pop => _ = self.pop(),
                .jump => |target| ip = target,
                .jump_if_false => |target| {
                    const v = self.pop();
                    if (!v.isTruthy()) ip = target;
                },
                .get_iter => try self.getIter(),
                .for_iter => |target| try self.forIter(target, &ip),
                .while_iter => |target| {
                    const v = self.pop();
                    if (!v.isTruthy()) ip = target;
                },
            }
        }
    }

    fn push(self: *VM, v: Value) RuntimeError!void {
        try self.frame.stack.append(self.allocator, v);
    }

    fn pop(self: *VM) Value {
        return self.frame.stack.pop().?;
    }

    const ArithOp = enum { add, sub, mul, div, mod };

    fn binaryArith(self: *VM, op: ArithOp) RuntimeError!void {
        const right = self.pop();
        const left = self.pop();

        if (op == .add and left == .string and right == .string) {
            const s = try std.mem.concat(self.allocator, u8, &.{ left.string, right.string });
            try self.push(.{ .string = s });
            return;
        }

        if (left != .number or right != .number) return RuntimeError.TypeMismatch;
        const a = left.number;
        const b = right.number;
        const result = switch (op) {
            .add => a + b,
            .sub => a - b,
            .mul => a * b,
            .div => blk: {
                if (b == 0) return RuntimeError.DivisionByZero;
                break :blk a / b;
            },
            .mod => blk: {
                if (b == 0) return RuntimeError.DivisionByZero;
                break :blk @mod(a, b);
            },
        };
        try self.push(.{ .number = result });
    }

    const CompareOp = enum { eq, ne, lt, le, gt, ge };

    fn compare(self: *VM, op: CompareOp) RuntimeError!void {
        const right = self.pop();
        const left = self.pop();

        const result = switch (op) {
            .eq => valuesEqual(left, right),
            .ne => !valuesEqual(left, right),
            else => if (left == .number and right == .number) numOrder(op, left.number, right.number) else if (left == .string and right == .string) strOrder(op, left.string, right.string) else return RuntimeError.TypeMismatch,
        };
        try self.push(.{ .boolean = result });
    }

    fn numOrder(op: CompareOp, a: f64, b: f64) bool {
        return switch (op) {
            .lt => a < b,
            .le => a <= b,
            .gt => a > b,
            .ge => a >= b,
            else => unreachable,
        };
    }

    fn strOrder(op: CompareOp, a: []const u8, b: []const u8) bool {
        const ord = std.mem.order(u8, a, b);
        return switch (op) {
            .lt => ord == .lt,
            .le => ord != .gt,
            .gt => ord == .gt,
            .ge => ord != .lt,
            else => unreachable,
        };
    }

    fn valuesEqual(a: Value, b: Value) bool {
        return switch (a) {
            .number => |x| b == .number and x == b.number,
            .string => |x| b == .string and std.mem.eql(u8, x, b.string),
            .boolean => |x| b == .boolean and x == b.boolean,
            .list => |x| eq: {
                if (b != .list or x.len != b.list.len) break :eq false;
                for (x, b.list) |ea, eb| {
                    if (!valuesEqual(ea, eb)) break :eq false;
                }
                break :eq true;
            },
            .iterator => unreachable,
        };
    }

    fn buildList(self: *VM, count: u32) RuntimeError!void {
        const n: usize = count;
        const start = self.frame.stack.items.len - n;
        const items = try self.allocator.dupe(Value, self.frame.stack.items[start..]);
        self.frame.stack.shrinkRetainingCapacity(start);
        try self.push(.{ .list = items });
    }

    fn doPrint(self: *VM, count: u32, writer: *std.Io.Writer) RuntimeError!void {
        const n: usize = count;
        const start = self.frame.stack.items.len - n;
        const args = self.frame.stack.items[start..];
        for (args, 0..) |v, i| {
            if (i != 0) try writer.writeByte(' ');
            try v.writeTo(writer, false);
        }
        try writer.writeByte('\n');
        self.frame.stack.shrinkRetainingCapacity(start);
    }

    fn getIter(self: *VM) RuntimeError!void {
        const v = self.pop();
        if (v != .list) return RuntimeError.NotIterable;
        try self.push(.{ .iterator = .{ .items = v.list, .index = 0 } });
    }

    fn forIter(self: *VM, target: u32, ip: *usize) RuntimeError!void {
        const top = &self.frame.stack.items[self.frame.stack.items.len - 1];
        const iter = &top.iterator;
        if (iter.index < iter.items.len) {
            const item = iter.items[iter.index];
            iter.index += 1;
            try self.push(item);
        } else {
            _ = self.pop();
            ip.* = target;
        }
    }
};

const testing = std.testing;
const Tokenizer = @import("../lexer/tokenizer.zig").Tokenizer;
const Parser = @import("../parser/parser.zig").Parser;
const Compiler = @import("compiler.zig").Compiler;

/// Tokenizes, parses, compiles, and runs `src`, returning the captured
/// `print` output. Caller owns the returned slice.
fn runAndCapture(gpa: std.mem.Allocator, src: []const u8) ![]u8 {
    const toks = try Tokenizer.tokenize(gpa, src);
    defer gpa.free(toks);

    var p = Parser.init(gpa, toks);
    defer p.deinit();
    const program = try p.parseProgram();

    var c = Compiler.init(gpa);
    defer c.deinit();
    const code = try c.compile(program);

    var machine = VM.init(gpa);
    defer machine.deinit();

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();

    try machine.run(code, &aw.writer);
    return gpa.dupe(u8, aw.written());
}

test "print arithmetic" {
    const gpa = testing.allocator;
    const out = try runAndCapture(gpa, "print(1 + 2, 3 * 4)\n");
    defer gpa.free(out);
    try testing.expectEqualStrings("3 12\n", out);
}

test "if elif else picks the right branch" {
    const gpa = testing.allocator;
    const src =
        \\x = 5
        \\if x < 1:
        \\    print("a")
        \\elif x == 5:
        \\    print("b")
        \\else:
        \\    print("c")
        \\
    ;
    const out = try runAndCapture(gpa, src);
    defer gpa.free(out);
    try testing.expectEqualStrings("b\n", out);
}

test "for loop over a list" {
    const gpa = testing.allocator;
    const out = try runAndCapture(gpa, "for i in [1, 2, 3]:\n    print(i)\n");
    defer gpa.free(out);
    try testing.expectEqualStrings("1\n2\n3\n", out);
}

test "while loop" {
    const gpa = testing.allocator;
    const src = "x = 0\nwhile x < 3:\n    print(x)\n    x = x + 1\n";
    const out = try runAndCapture(gpa, src);
    defer gpa.free(out);
    try testing.expectEqualStrings("0\n1\n2\n", out);
}

test "break exits a for loop early" {
    const gpa = testing.allocator;
    const src = "for i in [1, 2, 3, 4]:\n    if i == 3:\n        break\n    print(i)\n";
    const out = try runAndCapture(gpa, src);
    defer gpa.free(out);
    try testing.expectEqualStrings("1\n2\n", out);
}

test "continue skips an iteration in a for loop" {
    const gpa = testing.allocator;
    const src = "for i in [1, 2, 3, 4]:\n    if i == 2:\n        continue\n    print(i)\n";
    const out = try runAndCapture(gpa, src);
    defer gpa.free(out);
    try testing.expectEqualStrings("1\n3\n4\n", out);
}

test "break only exits the innermost loop" {
    const gpa = testing.allocator;
    const src =
        \\for i in [1, 2]:
        \\    for j in [1, 2, 3]:
        \\        if j == 2:
        \\            break
        \\        print(i, j)
        \\
    ;
    const out = try runAndCapture(gpa, src);
    defer gpa.free(out);
    try testing.expectEqualStrings("1 1\n2 1\n", out);
}

test "break in a while loop leaves no stray stack value" {
    const gpa = testing.allocator;
    const src =
        \\x = 0
        \\while x < 10:
        \\    x = x + 1
        \\    if x == 3:
        \\        break
        \\print(x)
        \\
    ;
    const out = try runAndCapture(gpa, src);
    defer gpa.free(out);
    try testing.expectEqualStrings("3\n", out);
}

test "string concatenation and comparison" {
    const gpa = testing.allocator;
    const src = "a = \"foo\" + \"bar\"\nprint(a, a == \"foobar\")\n";
    const out = try runAndCapture(gpa, src);
    defer gpa.free(out);
    try testing.expectEqualStrings("foobar True\n", out);
}
