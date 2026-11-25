//! The `tagOrId` argument of the canvas: an item id, `all`, one tag, or
//! a tag expression with `!`, `&&`, `^`, `||`, and parentheses. A text
//! with none of the characters `!&|^()` is one tag. An expression
//! compiles to a postfix program. `!` binds the tightest, then `&&`, then
//! `^`, then `||`, as in C. A tag in double quotes can have each of these
//! characters.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");

pub const Op = union(enum) {
    tag: []const u8,
    not,
    @"and",
    xor,
    @"or",
};

pub const Query = union(enum) {
    all,
    id: u32,
    tag: []const u8,
    expr: []const Op,
};

pub const Error = error{ MissingTag, Unbalanced, BadOperator, MissingQuote, OutOfMemory };

pub fn message(e: Error) []const u8 {
    return switch (e) {
        error.MissingTag => "missing tag in tag search expression",
        error.Unbalanced => "unbalanced parentheses in tag search expression",
        error.BadOperator => "invalid boolean operator in tag search expression",
        error.MissingQuote => "missing endquote in tag search expression",
        error.OutOfMemory => "out of memory",
    };
}

fn isExpr(text: []const u8) bool {
    for (text) |c| switch (c) {
        '!', '&', '|', '^', '(', ')', '"' => return true,
        else => {},
    };
    return false;
}

/// Parses a `tagOrId`. The tags point into `text` or into `a`.
pub fn parse(a: std.mem.Allocator, text: []const u8) Error!Query {
    if (text.len > 0 and std.ascii.isDigit(text[0])) {
        if (std.fmt.parseInt(u32, text, 10)) |id| return .{ .id = id } else |_| {}
    }
    if (std.mem.eql(u8, text, "all")) return .all;
    if (!isExpr(text)) return .{ .tag = text };
    var p: Parser = .{ .a = a, .s = text };
    try p.orExpr();
    p.skip();
    // A close parenthesis with no open one.
    if (p.i < p.s.len) return error.Unbalanced;
    return .{ .expr = try p.out.toOwnedSlice(a) };
}

const Parser = struct {
    a: std.mem.Allocator,
    s: []const u8,
    i: usize = 0,
    out: std.ArrayListUnmanaged(Op) = .empty,
    depth: u32 = 0,

    fn skip(p: *Parser) void {
        while (p.i < p.s.len and std.ascii.isWhitespace(p.s[p.i])) p.i += 1;
    }

    fn peek2(p: *Parser, two: []const u8) bool {
        return std.mem.startsWith(u8, p.s[p.i..], two);
    }

    fn orExpr(p: *Parser) Error!void {
        try p.xorExpr();
        while (true) {
            p.skip();
            if (p.peek2("||")) {
                p.i += 2;
                try p.xorExpr();
                try p.out.append(p.a, .@"or");
            } else if (p.i < p.s.len and p.s[p.i] == '|') return error.BadOperator else return;
        }
    }

    fn xorExpr(p: *Parser) Error!void {
        try p.andExpr();
        while (true) {
            p.skip();
            if (p.i < p.s.len and p.s[p.i] == '^') {
                p.i += 1;
                try p.andExpr();
                try p.out.append(p.a, .xor);
            } else return;
        }
    }

    fn andExpr(p: *Parser) Error!void {
        try p.unary();
        while (true) {
            p.skip();
            if (p.peek2("&&")) {
                p.i += 2;
                try p.unary();
                try p.out.append(p.a, .@"and");
            } else if (p.i < p.s.len and p.s[p.i] == '&') return error.BadOperator else return;
        }
    }

    fn unary(p: *Parser) Error!void {
        p.skip();
        if (p.i >= p.s.len) return error.MissingTag;
        const c = p.s[p.i];
        if (c == '!') {
            p.i += 1;
            try p.unary();
            try p.out.append(p.a, .not);
            return;
        }
        if (c == '(') {
            p.i += 1;
            p.depth += 1;
            try p.orExpr();
            p.skip();
            // `wish` accepts the end of the text as the close of an open parenthesis.
            if (p.i < p.s.len) {
                if (p.s[p.i] != ')') return error.Unbalanced;
                p.i += 1;
            }
            p.depth -= 1;
            return;
        }
        if (c == '"') {
            const end = std.mem.indexOfScalarPos(u8, p.s, p.i + 1, '"') orelse return error.MissingQuote;
            try p.out.append(p.a, .{ .tag = p.s[p.i + 1 .. end] });
            p.i = end + 1;
            return;
        }
        if (c == ')' or c == '&' or c == '|' or c == '^') return error.MissingTag;
        const start = p.i;
        while (p.i < p.s.len) : (p.i += 1) switch (p.s[p.i]) {
            '!', '&', '|', '^', '(', ')', '"' => break,
            else => {},
        };
        const tag = std.mem.trim(u8, p.s[start..p.i], " \t\n");
        if (tag.len == 0) return error.MissingTag;
        try p.out.append(p.a, .{ .tag = tag });
    }
};

/// Runs a compiled expression. `has` tells if the item has a tag.
pub fn eval(prog: []const Op, ctx: anytype, comptime has: fn (@TypeOf(ctx), []const u8) bool) bool {
    var stack: [64]bool = undefined;
    var n: usize = 0;
    for (prog) |op| switch (op) {
        .tag => |t| {
            if (n == stack.len) return false;
            stack[n] = has(ctx, t);
            n += 1;
        },
        .not => {
            if (n < 1) return false;
            stack[n - 1] = !stack[n - 1];
        },
        else => {
            if (n < 2) return false;
            const b = stack[n - 1];
            const x = stack[n - 2];
            n -= 1;
            stack[n - 1] = switch (op) {
                .@"and" => x and b,
                .@"or" => x or b,
                .xor => x != b,
                else => unreachable,
            };
        },
    };
    return n == 1 and stack[0];
}

const testing = std.testing;

fn hasIn(set: []const []const u8, t: []const u8) bool {
    for (set) |x| if (std.mem.eql(u8, x, t)) return true;
    return false;
}

test "canvas tags: expressions" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const item: []const []const u8 = &.{ "foo", "bar" };
    const cases = [_]struct { []const u8, bool }{
        .{ "foo&&bar", true },  .{ "foo&&!bar", false }, .{ "foo^bar", false },
        .{ "foo^baz", true },   .{ "!(foo||baz)", false }, .{ "baz||bar", true },
        .{ "(baz||foo)&&bar", true }, .{ "baz || bar && !foo", false }, .{ "\"foo\"&&bar", true },
    };
    for (cases) |c| {
        const q = try parse(a, c[0]);
        try testing.expectEqual(c[1], eval(q.expr, item, hasIn));
    }
    try testing.expectError(error.MissingTag, parse(a, "a &&"));
    try testing.expectError(error.MissingTag, parse(a, "!"));
    try testing.expectError(error.BadOperator, parse(a, "a & b"));
    try testing.expectError(error.Unbalanced, parse(a, "a)"));
    try testing.expectEqual(Query{ .id = 12 }, try parse(a, "12"));
}
