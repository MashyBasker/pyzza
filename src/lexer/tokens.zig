const std = @import("std");

pub const TokenType = enum {
    // literals
    name,
    number,
    string,

    // keywords
    kw_print,
    kw_for,
    kw_if,
    kw_elif,
    kw_else,
    kw_in,

    // operators
    plus,
    minus,
    star,
    slash,
    percent,
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
    .{ "if", .kw_if },
    .{ "elif", .kw_elif },
    .{ "else", .kw_else },
    .{ "in", .kw_in },
});

pub const Token = struct {
    type: TokenType,
    lexeme: []const u8,
    line: usize,
};
