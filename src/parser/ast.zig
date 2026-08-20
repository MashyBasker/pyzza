const tokens_mod = @import("../lexer/tokens.zig");
const TokenType = tokens_mod.TokenType;

pub const Expr = union(enum) {
    number: []const u8,
    string: []const u8,
    name: []const u8,
    list: []*Expr,
    unary: struct {
        op: TokenType,
        operand: *Expr,
    },
    binary: struct {
        op: TokenType,
        left: *Expr,
        right: *Expr,
    },
    call: struct {
        callee: *Expr,
        args: []*Expr,
    },
};

pub const Branch = struct {
    cond: *Expr,
    body: []*Stmt,
};

pub const Stmt = union(enum) {
    assign: struct {
        target: []const u8,
        value: *Expr,
    },
    print: struct {
        args: []*Expr,
    },
    if_stmt: struct {
        branches: []Branch,
        else_body: ?[]*Stmt,
    },
    for_stmt: struct {
        target: []const u8,
        iter: *Expr,
        body: []*Stmt,
    },
    while_stmt: struct {
        cond: *Expr,
        body: []*Stmt,
    },
    break_stmt,
    continue_stmt,
};

pub const Program = struct {
    body: []*Stmt,
};
