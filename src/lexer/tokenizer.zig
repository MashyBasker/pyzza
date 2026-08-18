const std = @import("std");
const tokens_mod = @import("tokens.zig");
const Token = tokens_mod.Token;
const TokenType = tokens_mod.TokenType;
const keywords = tokens_mod.keywords;

pub const TokenizeError = error{
    UnexpectedCharacter,
    UnterminatedString,
    InconsistentIndentation,
} || std.mem.Allocator.Error;

pub const Tokenizer = struct {
    source: []const u8,
    pos: usize = 0,
    line: usize = 1,
    at_line_start: bool = true,
    paren_depth: usize = 0,
    indent_stack: std.ArrayList(usize),
    out: std.ArrayList(Token),

    pub fn init(allocator: std.mem.Allocator, source: []const u8) !Tokenizer {
        var indent_stack: std.ArrayList(usize) = .empty;
        try indent_stack.append(allocator, 0);
        return .{
            .source = source,
            .indent_stack = indent_stack,
            .out = .empty,
        };
    }

    pub fn deinit(self: *Tokenizer, allocator: std.mem.Allocator) void {
        self.indent_stack.deinit(allocator);
        self.out.deinit(allocator);
    }

    fn peek(self: *Tokenizer) u8 {
        if (self.pos >= self.source.len) return 0;
        return self.source[self.pos];
    }

    fn peekAt(self: *Tokenizer, offset: usize) u8 {
        const i = self.pos + offset;
        if (i >= self.source.len) return 0;
        return self.source[i];
    }

    fn advance(self: *Tokenizer) u8 {
        const c = self.source[self.pos];
        self.pos += 1;
        return c;
    }

    fn isAtEnd(self: *Tokenizer) bool {
        return self.pos >= self.source.len;
    }

    fn push(self: *Tokenizer, allocator: std.mem.Allocator, ttype: TokenType, lexeme: []const u8) !void {
        try self.out.append(allocator, .{ .type = ttype, .lexeme = lexeme, .line = self.line });
    }

    pub fn tokenize(allocator: std.mem.Allocator, source: []const u8) TokenizeError![]Token {
        var t = try Tokenizer.init(allocator, source);
        defer t.deinit(allocator);

        while (true) {
            if (t.at_line_start and t.paren_depth == 0) {
                if (!try t.handleIndentation(allocator)) continue;
            }
            t.at_line_start = false;

            if (t.isAtEnd()) break;

            const c = t.peek();

            if (c == ' ' or c == '\t') {
                _ = t.advance();
                continue;
            }

            if (c == '#') {
                while (!t.isAtEnd() and t.peek() != '\n') _ = t.advance();
                continue;
            }

            if (c == '\n') {
                _ = t.advance();
                if (t.paren_depth == 0) {
                    // don't emit newline for blank/comment-only lines
                    if (t.out.items.len > 0 and t.out.items[t.out.items.len - 1].type != .newline) {
                        try t.push(allocator, .newline, "\n");
                    }
                    t.line += 1;
                    t.at_line_start = true;
                } else {
                    t.line += 1;
                }
                continue;
            }

            if (c == '\r') {
                _ = t.advance();
                continue;
            }

            if (isNameStart(c)) {
                try t.scanName(allocator);
                continue;
            }

            if (isDigit(c)) {
                try t.scanNumber(allocator);
                continue;
            }

            if (c == '"' or c == '\'') {
                try t.scanString(allocator);
                continue;
            }

            try t.scanOperator(allocator);
        }

        // final newline before dedents, if the last real token isn't already one
        if (t.out.items.len > 0) {
            const last = t.out.items[t.out.items.len - 1].type;
            if (last != .newline) {
                try t.push(allocator, .newline, "\n");
            }
        }

        // unwind remaining indentation levels
        while (t.indent_stack.items.len > 1) {
            _ = t.indent_stack.pop();
            try t.push(allocator, .dedent, "");
        }

        try t.push(allocator, .eof, "");

        return t.out.toOwnedSlice(allocator);
    }

    /// Consumes leading whitespace on a fresh line and emits indent/dedent
    /// tokens. Returns false if the line was blank/comment-only and should
    /// be skipped entirely (caller should `continue`), true otherwise.
    fn handleIndentation(self: *Tokenizer, allocator: std.mem.Allocator) TokenizeError!bool {
        var col: usize = 0;
        const start = self.pos;
        while (!self.isAtEnd()) {
            const c = self.peek();
            if (c == ' ') {
                col += 1;
                _ = self.advance();
            } else if (c == '\t') {
                col += 8 - (col % 8);
                _ = self.advance();
            } else {
                break;
            }
        }
        _ = start;

        // blank line or comment-only line: no indent/dedent tracking
        if (self.isAtEnd()) return true;
        if (self.peek() == '\n' or self.peek() == '#' or self.peek() == '\r') {
            self.at_line_start = false;
            return false;
        }

        const current = self.indent_stack.items[self.indent_stack.items.len - 1];
        if (col > current) {
            try self.indent_stack.append(allocator, col);
            try self.push(allocator, .indent, "");
        } else if (col < current) {
            while (self.indent_stack.items.len > 1 and self.indent_stack.items[self.indent_stack.items.len - 1] > col) {
                _ = self.indent_stack.pop();
                try self.push(allocator, .dedent, "");
            }
            if (self.indent_stack.items[self.indent_stack.items.len - 1] != col) {
                return TokenizeError.InconsistentIndentation;
            }
        }

        self.at_line_start = false;
        return true;
    }

    fn scanName(self: *Tokenizer, allocator: std.mem.Allocator) !void {
        const start = self.pos;
        while (!self.isAtEnd() and isNameContinue(self.peek())) _ = self.advance();
        const lexeme = self.source[start..self.pos];
        if (keywords.get(lexeme)) |kw| {
            try self.push(allocator, kw, lexeme);
        } else {
            try self.push(allocator, .name, lexeme);
        }
    }

    fn scanNumber(self: *Tokenizer, allocator: std.mem.Allocator) !void {
        const start = self.pos;
        while (!self.isAtEnd() and isDigit(self.peek())) _ = self.advance();
        if (self.peek() == '.' and isDigit(self.peekAt(1))) {
            _ = self.advance();
            while (!self.isAtEnd() and isDigit(self.peek())) _ = self.advance();
        }
        try self.push(allocator, .number, self.source[start..self.pos]);
    }

    fn scanString(self: *Tokenizer, allocator: std.mem.Allocator) !void {
        const quote = self.advance();
        const start = self.pos;
        while (true) {
            if (self.isAtEnd() or self.peek() == '\n') return TokenizeError.UnterminatedString;
            const c = self.peek();
            if (c == quote) break;
            if (c == '\\') {
                _ = self.advance();
                if (self.isAtEnd()) return TokenizeError.UnterminatedString;
            }
            _ = self.advance();
        }
        const lexeme = self.source[start..self.pos];
        _ = self.advance(); // closing quote
        try self.push(allocator, .string, lexeme);
    }

    fn scanOperator(self: *Tokenizer, allocator: std.mem.Allocator) !void {
        const start = self.pos;
        const c = self.advance();
        switch (c) {
            '+' => try self.push(allocator, .plus, self.source[start..self.pos]),
            '-' => try self.push(allocator, .minus, self.source[start..self.pos]),
            '*' => try self.push(allocator, .star, self.source[start..self.pos]),
            '/' => try self.push(allocator, .slash, self.source[start..self.pos]),
            '%' => try self.push(allocator, .percent, self.source[start..self.pos]),
            ',' => try self.push(allocator, .comma, self.source[start..self.pos]),
            ':' => try self.push(allocator, .colon, self.source[start..self.pos]),
            '(' => {
                self.paren_depth += 1;
                try self.push(allocator, .lparen, self.source[start..self.pos]);
            },
            ')' => {
                if (self.paren_depth > 0) self.paren_depth -= 1;
                try self.push(allocator, .rparen, self.source[start..self.pos]);
            },
            '[' => {
                self.paren_depth += 1;
                try self.push(allocator, .lbracket, self.source[start..self.pos]);
            },
            ']' => {
                if (self.paren_depth > 0) self.paren_depth -= 1;
                try self.push(allocator, .rbracket, self.source[start..self.pos]);
            },
            '=' => {
                if (self.peek() == '=') {
                    _ = self.advance();
                    try self.push(allocator, .eq_eq, self.source[start..self.pos]);
                } else {
                    try self.push(allocator, .equal, self.source[start..self.pos]);
                }
            },
            '!' => {
                if (self.peek() == '=') {
                    _ = self.advance();
                    try self.push(allocator, .not_eq, self.source[start..self.pos]);
                } else {
                    return TokenizeError.UnexpectedCharacter;
                }
            },
            '<' => {
                if (self.peek() == '=') {
                    _ = self.advance();
                    try self.push(allocator, .less_eq, self.source[start..self.pos]);
                } else {
                    try self.push(allocator, .less, self.source[start..self.pos]);
                }
            },
            '>' => {
                if (self.peek() == '=') {
                    _ = self.advance();
                    try self.push(allocator, .greater_eq, self.source[start..self.pos]);
                } else {
                    try self.push(allocator, .greater, self.source[start..self.pos]);
                }
            },
            else => return TokenizeError.UnexpectedCharacter,
        }
    }
};

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn isNameStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
}

fn isNameContinue(c: u8) bool {
    return isNameStart(c) or isDigit(c);
}

const testing = std.testing;

test "assignment and print" {
    const src = "x = 1\nprint(x)\n";
    const toks = try Tokenizer.tokenize(testing.allocator, src);
    defer testing.allocator.free(toks);

    const expected = [_]TokenType{
        .name,     .equal,  .number, .newline,
        .kw_print, .lparen, .name,   .rparen,
        .newline,  .eof,
    };
    try testing.expectEqual(expected.len, toks.len);
    for (expected, 0..) |e, i| {
        try testing.expectEqual(e, toks[i].type);
    }
}

test "if elif else with indentation" {
    const src =
        \\if x < 1:
        \\    print(x)
        \\elif x == 1:
        \\    print(x)
        \\else:
        \\    print(x)
        \\
    ;
    const toks = try Tokenizer.tokenize(testing.allocator, src);
    defer testing.allocator.free(toks);

    var saw_indent: usize = 0;
    var saw_dedent: usize = 0;
    for (toks) |tok| {
        if (tok.type == .indent) saw_indent += 1;
        if (tok.type == .dedent) saw_dedent += 1;
    }
    try testing.expectEqual(@as(usize, 3), saw_indent);
    try testing.expectEqual(@as(usize, 3), saw_dedent);
    try testing.expectEqual(TokenType.eof, toks[toks.len - 1].type);
}

test "for loop" {
    const src = "for i in x:\n    print(i)\n";
    const toks = try Tokenizer.tokenize(testing.allocator, src);
    defer testing.allocator.free(toks);

    const expected = [_]TokenType{
        .kw_for, .name,     .kw_in,  .name, .colon,  .newline,
        .indent, .kw_print, .lparen, .name, .rparen, .newline,
        .dedent, .eof,
    };
    try testing.expectEqual(expected.len, toks.len);
    for (expected, 0..) |e, i| {
        try testing.expectEqual(e, toks[i].type);
    }
}

test "while loop" {
    const src = "i = 0\nwhile i < 10:\n   i = i + 1\n";
    const toks = try Tokenizer.tokenize(testing.allocator, src);
    defer testing.allocator.free(toks);

    const expected = [_]TokenType{
        .name,     .equal,   .number, .newline,
        .kw_while, .name,    .less,   .number,
        .colon,    .newline, .indent, .name,
        .equal,    .name,    .plus,   .number,
        .newline,  .dedent,  .eof,
    };
    try testing.expectEqual(expected.len, toks.len);
    for (expected, 0..) |e, i| {
        try testing.expectEqual(e, toks[i].type);
    }
}

test "break statement" {
    const src = "if d > 0:\n    break\n";
    const toks = try Tokenizer.tokenize(testing.allocator, src);
    defer testing.allocator.free(toks);

    const expected = [_]TokenType{
        .kw_if,  .name,     .greater, .number, .colon, .newline,
        .indent, .kw_break, .newline, .dedent, .eof,
    };

    try testing.expectEqual(expected.len, toks.len);
    for (expected, 0..) |e, i| {
        try testing.expectEqual(e, toks[i].type);
    }
}

test "continue statement" {
    const src = "if d > 0:\n    continue\n";
    const toks = try Tokenizer.tokenize(testing.allocator, src);
    defer testing.allocator.free(toks);

    const expected = [_]TokenType{
        .kw_if,  .name,        .greater, .number, .colon, .newline,
        .indent, .kw_continue, .newline, .dedent, .eof,
    };

    try testing.expectEqual(expected.len, toks.len);
    for (expected, 0..) |e, i| {
        try testing.expectEqual(e, toks[i].type);
    }
}
