const std = @import("std");

pub const TokenType = enum {
    // literals
    name,
    number,
    string,

    // keywords
    kw_print,
    kw_for,
    kw_while,
    kw_if,
    kw_elif,
    kw_else,
    kw_in,
    kw_break,
    kw_continue,

    // operators
    plus, // +
    minus, // -
    star, // *
    slash, // /
    percent, // %
    equal, // =
    eq_eq, // ==
    not_eq, // !=
    less, // <
    less_eq, // <=
    greater, // >
    greater_eq, // >=

    // delimiters
    lparen,
    rparen,
    lbracket,
    rbracket,
    comma,
    colon,

    // structure
    newline,
    indent,
    dedent,
    eof,
};

pub const keywords = std.StaticStringMap(TokenType).initComptime(.{
    .{ "print", .kw_print },
    .{ "for", .kw_for },
    .{ "while", .kw_while },
    .{ "if", .kw_if },
    .{ "elif", .kw_elif },
    .{ "else", .kw_else },
    .{ "in", .kw_in },
    .{ "break", .kw_break },
    .{ "continue", .kw_continue },
});

pub const Token = struct {
    type: TokenType,
    lexeme: []const u8,
    line: usize,
};
