const std = @import("std");
const tokens_mod = @import("../lexer/tokens.zig");
const Token = tokens_mod.Token;
const TokenType = tokens_mod.TokenType;
const ast = @import("ast.zig");
const Expr = ast.Expr;
const Stmt = ast.Stmt;
const Branch = ast.Branch;
const Program = ast.Program;

pub const ParseError = error{
    UnexpectedToken,
    ExpectedExpression,
} || std.mem.Allocator.Error;

pub const Parser = struct {
    tokens: []const Token,
    pos: usize = 0,
    arena: std.heap.ArenaAllocator,

    pub fn init(gpa: std.mem.Allocator, tokens: []const Token) Parser {
        return .{ .tokens = tokens, .arena = std.heap.ArenaAllocator.init(gpa) };
    }

    pub fn deinit(self: *Parser) void {
        self.arena.deinit();
    }

    pub fn parseProgram(self: *Parser) ParseError!Program {
        const allocr = self.arena.allocator();
        var stmts: std.ArrayList(*Stmt) = .empty;
        while (!self.check(.eof)) {
            if (self.match(.newline)) continue;
            try stmts.append(allocr, try self.parseStmt());
        }
        return .{ .body = try stmts.toOwnedSlice(allocr) };
    }

    fn allocator(self: *Parser) std.mem.Allocator {
        return self.arena.allocator();
    }

    fn peek(self: *Parser) Token {
        return self.tokens[self.pos];
    }

    fn check(self: *Parser, ttype: TokenType) bool {
        return self.peek().type == ttype;
    }

    fn advance(self: *Parser) Token {
        const tok = self.tokens[self.pos];
        if (tok.type != .eof) self.pos += 1;
        return tok;
    }

    fn match(self: *Parser, ttype: TokenType) bool {
        if (!self.check(ttype)) return false;
        _ = self.advance();
        return true;
    }

    fn expect(self: *Parser, ttype: TokenType) ParseError!Token {
        if (!self.check(ttype)) return ParseError.UnexpectedToken;
        return self.advance();
    }

    fn newExpr(self: *Parser, e: Expr) ParseError!*Expr {
        const ptr = try self.allocator().create(Expr);
        ptr.* = e;
        return ptr;
    }

    fn newStmt(self: *Parser, s: Stmt) ParseError!*Stmt {
        const ptr = try self.allocator().create(Stmt);
        ptr.* = s;
        return ptr;
    }

    // ---- statements ----

    fn parseStmt(self: *Parser) ParseError!*Stmt {
        return switch (self.peek().type) {
            .kw_if => self.parseIf(),
            .kw_for => self.parseFor(),
            .kw_while => self.parseWhile(),
            .kw_print => self.parsePrint(),
            .kw_break => self.parseBreak(),
            .kw_continue => self.parseContinue(),
            .name => self.parseAssign(),
            else => ParseError.UnexpectedToken,
        };
    }

    fn parseBlock(self: *Parser) ParseError![]*Stmt {
        _ = try self.expect(.newline);
        _ = try self.expect(.indent);
        var stmts: std.ArrayList(*Stmt) = .empty;
        while (!self.check(.dedent) and !self.check(.eof)) {
            try stmts.append(self.allocator(), try self.parseStmt());
        }
        _ = try self.expect(.dedent);
        return stmts.toOwnedSlice(self.allocator());
    }

    fn parseAssign(self: *Parser) ParseError!*Stmt {
        const name_tok = try self.expect(.name);
        _ = try self.expect(.equal);
        const value = try self.parseExpr();
        _ = try self.expect(.newline);
        return self.newStmt(.{ .assign = .{ .target = name_tok.lexeme, .value = value } });
    }

    fn parsePrint(self: *Parser) ParseError!*Stmt {
        _ = try self.expect(.kw_print);
        _ = try self.expect(.lparen);
        var args: std.ArrayList(*Expr) = .empty;
        if (!self.check(.rparen)) {
            try args.append(self.allocator(), try self.parseExpr());
            while (self.match(.comma)) {
                try args.append(self.allocator(), try self.parseExpr());
            }
        }
        _ = try self.expect(.rparen);
        _ = try self.expect(.newline);
        return self.newStmt(.{ .print = .{ .args = try args.toOwnedSlice(self.allocator()) } });
    }

    fn parseIf(self: *Parser) ParseError!*Stmt {
        _ = try self.expect(.kw_if);
        var branches: std.ArrayList(Branch) = .empty;

        const first_cond = try self.parseExpr();
        _ = try self.expect(.colon);
        const first_body = try self.parseBlock();
        try branches.append(self.allocator(), .{ .cond = first_cond, .body = first_body });

        while (self.check(.kw_elif)) {
            _ = self.advance();
            const cond = try self.parseExpr();
            _ = try self.expect(.colon);
            const body = try self.parseBlock();
            try branches.append(self.allocator(), .{ .cond = cond, .body = body });
        }

        var else_body: ?[]*Stmt = null;
        if (self.match(.kw_else)) {
            _ = try self.expect(.colon);
            else_body = try self.parseBlock();
        }

        return self.newStmt(.{ .if_stmt = .{
            .branches = try branches.toOwnedSlice(self.allocator()),
            .else_body = else_body,
        } });
    }

    fn parseWhile(self: *Parser) ParseError!*Stmt {
        _ = try self.expect(.kw_while);
        const cond_expr = try self.parseExpr();
        _ = try self.expect(.colon);
        const body = try self.parseBlock();

        return self.newStmt(.{ .while_stmt = .{
            .cond = cond_expr,
            .body = body,
        } });
    }

    fn parseFor(self: *Parser) ParseError!*Stmt {
        _ = try self.expect(.kw_for);
        const name_tok = try self.expect(.name);
        _ = try self.expect(.kw_in);
        const iter = try self.parseExpr();
        _ = try self.expect(.colon);
        const body = try self.parseBlock();
        return self.newStmt(.{ .for_stmt = .{ .target = name_tok.lexeme, .iter = iter, .body = body } });
    }

    fn parseBreak(self: *Parser) ParseError!*Stmt {
        _ = try self.expect(.kw_break);
        _ = try self.expect(.newline);
        return self.newStmt(.break_stmt);
    }

    fn parseContinue(self: *Parser) ParseError!*Stmt {
        _ = try self.expect(.kw_continue);
        _ = try self.expect(.newline);
        return self.newStmt(.continue_stmt);
    }

    // ---- expressions ----
    // precedence, low to high: comparison < additive < multiplicative < unary < call/primary

    fn parseExpr(self: *Parser) ParseError!*Expr {
        return self.parseComparison();
    }

    fn parseComparison(self: *Parser) ParseError!*Expr {
        var left = try self.parseAdditive();
        while (true) {
            const op = self.peek().type;
            switch (op) {
                .eq_eq, .not_eq, .less, .less_eq, .greater, .greater_eq => {
                    _ = self.advance();
                    const right = try self.parseAdditive();
                    left = try self.newExpr(.{ .binary = .{ .op = op, .left = left, .right = right } });
                },
                else => break,
            }
        }
        return left;
    }

    fn parseAdditive(self: *Parser) ParseError!*Expr {
        var left = try self.parseMultiplicative();
        while (true) {
            const op = self.peek().type;
            switch (op) {
                .plus, .minus => {
                    _ = self.advance();
                    const right = try self.parseMultiplicative();
                    left = try self.newExpr(.{ .binary = .{ .op = op, .left = left, .right = right } });
                },
                else => break,
            }
        }
        return left;
    }

    fn parseMultiplicative(self: *Parser) ParseError!*Expr {
        var left = try self.parseUnary();
        while (true) {
            const op = self.peek().type;
            switch (op) {
                .star, .slash, .percent => {
                    _ = self.advance();
                    const right = try self.parseUnary();
                    left = try self.newExpr(.{ .binary = .{ .op = op, .left = left, .right = right } });
                },
                else => break,
            }
        }
        return left;
    }

    fn parseUnary(self: *Parser) ParseError!*Expr {
        const op = self.peek().type;
        if (op == .minus or op == .plus) {
            _ = self.advance();
            const operand = try self.parseUnary();
            return self.newExpr(.{ .unary = .{ .op = op, .operand = operand } });
        }
        return self.parseCall();
    }

    fn parseCall(self: *Parser) ParseError!*Expr {
        var expr = try self.parsePrimary();
        while (self.check(.lparen)) {
            _ = self.advance();
            var args: std.ArrayList(*Expr) = .empty;
            if (!self.check(.rparen)) {
                try args.append(self.allocator(), try self.parseExpr());
                while (self.match(.comma)) {
                    try args.append(self.allocator(), try self.parseExpr());
                }
            }
            _ = try self.expect(.rparen);
            expr = try self.newExpr(.{ .call = .{ .callee = expr, .args = try args.toOwnedSlice(self.allocator()) } });
        }
        return expr;
    }

    fn parsePrimary(self: *Parser) ParseError!*Expr {
        const tok = self.peek();
        switch (tok.type) {
            .number => {
                _ = self.advance();
                return self.newExpr(.{ .number = tok.lexeme });
            },
            .string => {
                _ = self.advance();
                return self.newExpr(.{ .string = tok.lexeme });
            },
            .name => {
                _ = self.advance();
                return self.newExpr(.{ .name = tok.lexeme });
            },
            .lparen => {
                _ = self.advance();
                const inner = try self.parseExpr();
                _ = try self.expect(.rparen);
                return inner;
            },
            .lbracket => {
                _ = self.advance();
                var items: std.ArrayList(*Expr) = .empty;
                if (!self.check(.rbracket)) {
                    try items.append(self.allocator(), try self.parseExpr());
                    while (self.match(.comma)) {
                        try items.append(self.allocator(), try self.parseExpr());
                    }
                }
                _ = try self.expect(.rbracket);
                return self.newExpr(.{ .list = try items.toOwnedSlice(self.allocator()) });
            },
            else => return ParseError.ExpectedExpression,
        }
    }
};

const testing = std.testing;
const Tokenizer = @import("../lexer/tokenizer.zig").Tokenizer;

test "parse assignment" {
    const gpa = testing.allocator;
    const toks = try Tokenizer.tokenize(gpa, "x = 1 + 2\n");
    defer gpa.free(toks);
    var p = Parser.init(gpa, toks);
    defer p.deinit();
    const program = try p.parseProgram();

    try testing.expectEqual(@as(usize, 1), program.body.len);
    const stmt = program.body[0];
    try testing.expect(stmt.* == .assign);
    try testing.expectEqualStrings("x", stmt.assign.target);
    try testing.expect(stmt.assign.value.* == .binary);
    try testing.expectEqual(TokenType.plus, stmt.assign.value.binary.op);
}

test "parse print with multiple args" {
    const gpa = testing.allocator;
    const toks = try Tokenizer.tokenize(gpa, "print(x, 1, \"hi\")\n");
    defer gpa.free(toks);
    var p = Parser.init(gpa, toks);
    defer p.deinit();
    const program = try p.parseProgram();

    try testing.expectEqual(@as(usize, 1), program.body.len);
    const stmt = program.body[0];
    try testing.expect(stmt.* == .print);
    try testing.expectEqual(@as(usize, 3), stmt.print.args.len);
}

test "parse if elif else" {
    const gpa = testing.allocator;
    const src =
        \\if x < 1:
        \\    print(x)
        \\elif x == 1:
        \\    print(x)
        \\else:
        \\    print(x)
        \\
    ;
    const toks = try Tokenizer.tokenize(gpa, src);
    defer gpa.free(toks);
    var p = Parser.init(gpa, toks);
    defer p.deinit();
    const program = try p.parseProgram();

    try testing.expectEqual(@as(usize, 1), program.body.len);
    const stmt = program.body[0];
    try testing.expect(stmt.* == .if_stmt);
    try testing.expectEqual(@as(usize, 2), stmt.if_stmt.branches.len);
    try testing.expect(stmt.if_stmt.else_body != null);
}

test "parse while loop" {
    const gpa = testing.allocator;
    const src = "while x < 10:\n    print(x)\n    x = x + 1\n";
    const toks = try Tokenizer.tokenize(gpa, src);
    defer gpa.free(toks);
    var p = Parser.init(gpa, toks);
    defer p.deinit();
    const program = try p.parseProgram();

    try testing.expectEqual(@as(usize, 1), program.body.len);
    const stmt = program.body[0];
    try testing.expect(stmt.* == .while_stmt);
    try testing.expect(stmt.while_stmt.cond.* == .binary);
    try testing.expectEqual(@as(usize, 2), stmt.while_stmt.body.len);
}

test "parse break and continue" {
    const gpa = testing.allocator;
    const src = "while x < 10:\n    break\n    continue\n";
    const toks = try Tokenizer.tokenize(gpa, src);
    defer gpa.free(toks);
    var p = Parser.init(gpa, toks);
    defer p.deinit();
    const program = try p.parseProgram();

    const body = program.body[0].while_stmt.body;
    try testing.expectEqual(@as(usize, 2), body.len);
    try testing.expect(body[0].* == .break_stmt);
    try testing.expect(body[1].* == .continue_stmt);
}

test "parse for loop over list" {
    const gpa = testing.allocator;
    const src = "for i in [1, 2, 3]:\n    print(i)\n";
    const toks = try Tokenizer.tokenize(gpa, src);
    defer gpa.free(toks);
    var p = Parser.init(gpa, toks);
    defer p.deinit();
    const program = try p.parseProgram();

    try testing.expectEqual(@as(usize, 1), program.body.len);
    const stmt = program.body[0];
    try testing.expect(stmt.* == .for_stmt);
    try testing.expectEqualStrings("i", stmt.for_stmt.target);
    try testing.expect(stmt.for_stmt.iter.* == .list);
    try testing.expectEqual(@as(usize, 3), stmt.for_stmt.iter.list.len);
    try testing.expectEqual(@as(usize, 1), stmt.for_stmt.body.len);
}
