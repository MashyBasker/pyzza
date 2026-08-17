const std = @import("std");
const ast = @import("../parser/ast.zig");
const tokens_mod = @import("../lexer/tokens.zig");
const TokenType = tokens_mod.TokenType;
const chunk_mod = @import("chunk.zig");
const Instruction = chunk_mod.Instruction;
const Chunk = chunk_mod.Chunk;

pub const CompileError = error{
    InvalidNumberLiteral,
    UnsupportedExpression,
} || std.mem.Allocator.Error;

pub const Compiler = struct {
    arena: std.heap.ArenaAllocator,
    code: std.ArrayList(Instruction) = .empty,

    pub fn init(gpa: std.mem.Allocator) Compiler {
        return .{ .arena = std.heap.ArenaAllocator.init(gpa) };
    }

    pub fn deinit(self: *Compiler) void {
        self.arena.deinit();
    }

    pub fn compile(self: *Compiler, program: ast.Program) CompileError!Chunk {
        const allocator = self.arena.allocator();
        for (program.body) |stmt| {
            try self.compileStmt(allocator, stmt);
        }
        return .{ .code = try self.code.toOwnedSlice(allocator) };
    }

    fn emit(self: *Compiler, allocator: std.mem.Allocator, instr: Instruction) !void {
        try self.code.append(allocator, instr);
    }

    /// Returns the index of the just-emitted instruction, for later patching.
    fn emitJump(self: *Compiler, allocator: std.mem.Allocator, instr: Instruction) !usize {
        try self.code.append(allocator, instr);
        return self.code.items.len - 1;
    }

    fn patchJumpToHere(self: *Compiler, idx: usize) void {
        const here: u32 = @intCast(self.code.items.len);
        switch (self.code.items[idx]) {
            .jump => self.code.items[idx] = .{ .jump = here },
            .jump_if_false => self.code.items[idx] = .{ .jump_if_false = here },
            .for_iter => self.code.items[idx] = .{ .for_iter = here },
            else => unreachable,
        }
    }

    fn compileStmt(self: *Compiler, allocator: std.mem.Allocator, stmt: *ast.Stmt) CompileError!void {
        switch (stmt.*) {
            .assign => |a| {
                try self.compileExpr(allocator, a.value);
                try self.emit(allocator, .{ .store_name = a.target });
            },
            .print => |p| {
                for (p.args) |arg| try self.compileExpr(allocator, arg);
                try self.emit(allocator, .{ .print = @intCast(p.args.len) });
            },
            .if_stmt => |s| try self.compileIf(allocator, s),
            .for_stmt => |s| try self.compileFor(allocator, s),
        }
    }

    fn compileIf(self: *Compiler, allocator: std.mem.Allocator, s: anytype) CompileError!void {
        var end_jumps: std.ArrayList(usize) = .empty;

        for (s.branches) |branch| {
            try self.compileExpr(allocator, branch.cond);
            const skip_idx = try self.emitJump(allocator, .{ .jump_if_false = 0 });

            for (branch.body) |body_stmt| try self.compileStmt(allocator, body_stmt);

            const end_idx = try self.emitJump(allocator, .{ .jump = 0 });
            try end_jumps.append(allocator, end_idx);

            self.patchJumpToHere(skip_idx);
        }

        if (s.else_body) |else_body| {
            for (else_body) |body_stmt| try self.compileStmt(allocator, body_stmt);
        }

        for (end_jumps.items) |idx| self.patchJumpToHere(idx);
    }

    fn compileFor(self: *Compiler, allocator: std.mem.Allocator, s: anytype) CompileError!void {
        try self.compileExpr(allocator, s.iter);
        try self.emit(allocator, .get_iter);

        const loop_start: u32 = @intCast(self.code.items.len);
        const for_iter_idx = try self.emitJump(allocator, .{ .for_iter = 0 });

        try self.emit(allocator, .{ .store_name = s.target });
        for (s.body) |body_stmt| try self.compileStmt(allocator, body_stmt);
        try self.emit(allocator, .{ .jump = loop_start });

        self.patchJumpToHere(for_iter_idx);
    }

    fn compileExpr(self: *Compiler, allocator: std.mem.Allocator, expr: *ast.Expr) CompileError!void {
        switch (expr.*) {
            .number => |lexeme| {
                const n = std.fmt.parseFloat(f64, lexeme) catch return CompileError.InvalidNumberLiteral;
                try self.emit(allocator, .{ .push_number = n });
            },
            .string => |s| try self.emit(allocator, .{ .push_string = s }),
            .name => |n| try self.emit(allocator, .{ .load_name = n }),
            .list => |items| {
                for (items) |item| try self.compileExpr(allocator, item);
                try self.emit(allocator, .{ .build_list = @intCast(items.len) });
            },
            .unary => |u| {
                try self.compileExpr(allocator, u.operand);
                switch (u.op) {
                    .minus => try self.emit(allocator, .neg),
                    .plus => {}, // unary plus is a no-op
                    else => unreachable,
                }
            },
            .binary => |b| {
                try self.compileExpr(allocator, b.left);
                try self.compileExpr(allocator, b.right);
                try self.emit(allocator, binaryOp(b.op));
            },
            .call => {
                // No callable expressions are supported yet -- `print(...)`
                // is parsed as a dedicated `Stmt.print`, not a call, so any
                // `Expr.call` reaching here is out of scope for now.
                return CompileError.UnsupportedExpression;
            },
        }
    }

    fn binaryOp(op: TokenType) Instruction {
        return switch (op) {
            .plus => .add,
            .minus => .sub,
            .star => .mul,
            .slash => .div,
            .percent => .mod,
            .eq_eq => .eq,
            .not_eq => .ne,
            .less => .lt,
            .less_eq => .le,
            .greater => .gt,
            .greater_eq => .ge,
            else => unreachable,
        };
    }
};
