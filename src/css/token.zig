//! The CSS tokenizer. It follows the token rules of CSS Syntax Level 3
//! for the tokens that the parser needs. It skips comments, folds each
//! run of white space into one token, and never fails: a character that
//! starts no other token is a `delim`. A string with escapes needs memory
//! for its resolved text, so the tokenizer has an optional allocator. With
//! no allocator, a string keeps its raw text.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");

pub const Token = union(enum) {
    ident: []const u8,
    /// The name before "(".
    function: []const u8,
    /// The name after "@".
    at_keyword: []const u8,
    /// The text after "#".
    hash: []const u8,
    /// The text between quotes, escapes resolved.
    string: []const u8,
    number: f32,
    dimension: struct { value: f32, unit: []const u8 },
    percentage: f32,
    /// One other character, for example '>' or '.'.
    delim: u8,
    colon,
    semicolon,
    comma,
    lbrace,
    rbrace,
    lparen,
    rparen,
    lbracket,
    rbracket,
    whitespace,
    eof,
};

fn isNameStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_' or c >= 0x80;
}

fn isNameChar(c: u8) bool {
    return isNameStart(c) or std.ascii.isDigit(c) or c == '-';
}

pub const Tokenizer = struct {
    src: []const u8,
    pos: usize = 0,
    line: u32 = 1,
    /// For the resolved text of strings with escapes.
    alloc: ?std.mem.Allocator = null,

    fn peek(t: *const Tokenizer, off: usize) u8 {
        return if (t.pos + off < t.src.len) t.src[t.pos + off] else 0;
    }

    /// A backslash starts a valid escape when a character follows it and that character is not a newline.
    fn validEscape(t: *const Tokenizer, off: usize) bool {
        return t.peek(off) == '\\' and t.pos + off + 1 < t.src.len and t.src[t.pos + off + 1] != '\n';
    }

    fn startsIdent(t: *const Tokenizer, off: usize) bool {
        const c = t.peek(off);
        if (isNameStart(c) or t.validEscape(off)) return true;
        if (c == '-') {
            const d = t.peek(off + 1);
            return isNameStart(d) or d == '-' or t.validEscape(off + 1);
        }
        return false;
    }

    fn consumeName(t: *Tokenizer) []const u8 {
        const start = t.pos;
        while (t.pos < t.src.len) {
            const c = t.src[t.pos];
            if (isNameChar(c)) {
                t.pos += 1;
            } else if (c == '\\' and t.pos + 1 < t.src.len and t.src[t.pos + 1] != '\n') {
                t.pos += 2;
            } else break;
        }
        return t.src[start..t.pos];
    }

    fn consumeNumber(t: *Tokenizer) f32 {
        const start = t.pos;
        if (t.peek(0) == '+' or t.peek(0) == '-') t.pos += 1;
        while (std.ascii.isDigit(t.peek(0))) t.pos += 1;
        if (t.peek(0) == '.' and std.ascii.isDigit(t.peek(1))) {
            t.pos += 1;
            while (std.ascii.isDigit(t.peek(0))) t.pos += 1;
        }
        if ((t.peek(0) == 'e' or t.peek(0) == 'E') and (std.ascii.isDigit(t.peek(1)) or ((t.peek(1) == '+' or t.peek(1) == '-') and std.ascii.isDigit(t.peek(2))))) {
            t.pos += 2;
            while (std.ascii.isDigit(t.peek(0))) t.pos += 1;
        }
        const v = std.fmt.parseFloat(f32, t.src[start..t.pos]) catch 0;
        return if (std.math.isFinite(v)) v else 0;
    }

    fn consumeString(t: *Tokenizer, quote: u8) Token {
        t.pos += 1;
        const start = t.pos;
        var has_escape = false;
        while (t.pos < t.src.len) {
            const c = t.src[t.pos];
            if (c == quote) break;
            if (c == '\n') t.line += 1;
            if (c == '\\' and t.pos + 1 < t.src.len) {
                has_escape = true;
                t.pos += 2;
                continue;
            }
            t.pos += 1;
        }
        const raw = t.src[start..t.pos];
        if (t.pos < t.src.len) t.pos += 1; // the closing quote
        if (!has_escape or t.alloc == null) return .{ .string = raw };
        var out: std.ArrayListUnmanaged(u8) = .empty;
        var i: usize = 0;
        while (i < raw.len) : (i += 1) {
            if (raw[i] == '\\' and i + 1 < raw.len) {
                i += 1;
                out.append(t.alloc.?, raw[i]) catch return .{ .string = raw };
            } else out.append(t.alloc.?, raw[i]) catch return .{ .string = raw };
        }
        return .{ .string = out.items };
    }

    pub fn next(t: *Tokenizer) Token {
        // Skip comments, keep the count of lines.
        while (true) {
            if (t.peek(0) == '/' and t.peek(1) == '*') {
                t.pos += 2;
                while (t.pos < t.src.len and !(t.src[t.pos] == '*' and t.peek(1) == '/')) : (t.pos += 1) {
                    if (t.src[t.pos] == '\n') t.line += 1;
                }
                t.pos = @min(t.pos + 2, t.src.len);
                continue;
            }
            break;
        }
        if (t.pos >= t.src.len) return .eof;
        const c = t.src[t.pos];
        if (std.ascii.isWhitespace(c)) {
            while (t.pos < t.src.len) {
                const w = t.src[t.pos];
                if (std.ascii.isWhitespace(w)) {
                    if (w == '\n') t.line += 1;
                    t.pos += 1;
                } else if (w == '/' and t.peek(1) == '*') {
                    t.pos += 2;
                    while (t.pos < t.src.len and !(t.src[t.pos] == '*' and t.peek(1) == '/')) : (t.pos += 1) {
                        if (t.src[t.pos] == '\n') t.line += 1;
                    }
                    t.pos = @min(t.pos + 2, t.src.len);
                } else break;
            }
            return .whitespace;
        }
        switch (c) {
            '"', '\'' => return t.consumeString(c),
            '#' => {
                if (isNameChar(t.peek(1)) or t.validEscape(1)) {
                    t.pos += 1;
                    return .{ .hash = t.consumeName() };
                }
                t.pos += 1;
                return .{ .delim = '#' };
            },
            '@' => {
                if (t.startsIdent(1)) {
                    t.pos += 1;
                    return .{ .at_keyword = t.consumeName() };
                }
                t.pos += 1;
                return .{ .delim = '@' };
            },
            ':' => {
                t.pos += 1;
                return .colon;
            },
            ';' => {
                t.pos += 1;
                return .semicolon;
            },
            ',' => {
                t.pos += 1;
                return .comma;
            },
            '{' => {
                t.pos += 1;
                return .lbrace;
            },
            '}' => {
                t.pos += 1;
                return .rbrace;
            },
            '(' => {
                t.pos += 1;
                return .lparen;
            },
            ')' => {
                t.pos += 1;
                return .rparen;
            },
            '[' => {
                t.pos += 1;
                return .lbracket;
            },
            ']' => {
                t.pos += 1;
                return .rbracket;
            },
            else => {},
        }
        const num_start = std.ascii.isDigit(c) or
            ((c == '+' or c == '-') and (std.ascii.isDigit(t.peek(1)) or (t.peek(1) == '.' and std.ascii.isDigit(t.peek(2))))) or
            (c == '.' and std.ascii.isDigit(t.peek(1)));
        if (num_start) {
            const v = t.consumeNumber();
            if (t.peek(0) == '%') {
                t.pos += 1;
                return .{ .percentage = v };
            }
            if (t.startsIdent(0)) return .{ .dimension = .{ .value = v, .unit = t.consumeName() } };
            return .{ .number = v };
        }
        if (t.startsIdent(0)) {
            const name = t.consumeName();
            if (t.peek(0) == '(') {
                t.pos += 1;
                return .{ .function = name };
            }
            return .{ .ident = name };
        }
        t.pos += 1;
        return .{ .delim = c };
    }
};
