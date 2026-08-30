const std = @import("std");

pub const TokenType = enum {
    // literals
    ident,
    integer,
    float,
    string,
    char,

    // keywords
    kw_import,
    kw_pub,
    kw_inline,
    kw_func,
    kw_proc,
    kw_extern,
    kw_type,
    kw_struct,
    kw_enum,
    kw_static,
    kw_const,
    kw_var,
    kw_defer,
    kw_unsafe,
    kw_if,
    kw_elif,
    kw_else,
    kw_for,
    kw_in,
    kw_while,
    kw_match,
    kw_case,
    kw_return,
    kw_orelse,
    kw_comptime,
    kw_try,
    kw_end,
    kw_true,
    kw_false,
    kw_break,
    kw_continue,
    kw_nil,

    // operators (single char)
    l_paren, // (
    r_paren, // )
    l_bracket, // [
    r_bracket, // ]
    dot, // .
    comma, // ,
    colon, // :
    semicolon, // ;
    eq, // =
    plus, // +
    minus, // -
    star, // *
    slash, // /
    percent, // %
    amp, // &
    pipe, // |
    caret, // ^
    tilde, // ~
    bang, // !
    lt, // <
    gt, // >
    optional, // ?

    // operators (multiple char)
    arrow, // ->
    eq_eq, // ==
    bang_eq, // !=
    lt_eq, // <=
    gt_eq, // >=
    amp_amp, // &&
    pipe_pipe, // ||
    shl, // <<
    shr, // >>
    shl_eq, // <<=
    shr_eq, // >>=
    plus_eq, // +=
    minus_eq, // -=
    star_eq, // *=
    slash_eq, // /=
    percent_eq, // %=
    amp_eq, // &=
    pipe_eq, // |=
    caret_eq, // ^=
    dot_dot, // .. (range)

    // others
    eof,
    comment,
    unkown,
};

pub const Token = struct {
    type: TokenType,
    val: []const u8,
    line: usize,
    col: usize,
};

pub const keywords = [_]struct { text: []const u8, kind: TokenType }{
    .{ .text = "import", .kind = .kw_import },
    .{ .text = "pub", .kind = .kw_pub },
    .{ .text = "inline", .kind = .kw_inline },
    .{ .text = "func", .kind = .kw_func },
    .{ .text = "proc", .kind = .kw_proc },
    .{ .text = "extern", .kind = .kw_extern },
    .{ .text = "type", .kind = .kw_type },
    .{ .text = "struct", .kind = .kw_struct },
    .{ .text = "enum", .kind = .kw_enum },
    .{ .text = "static", .kind = .kw_static },
    .{ .text = "const", .kind = .kw_const },
    .{ .text = "var", .kind = .kw_var },
    .{ .text = "defer", .kind = .kw_defer },
    .{ .text = "unsafe", .kind = .kw_unsafe },
    .{ .text = "if", .kind = .kw_if },
    .{ .text = "elif", .kind = .kw_elif },
    .{ .text = "else", .kind = .kw_else },
    .{ .text = "for", .kind = .kw_for },
    .{ .text = "in", .kind = .kw_in },
    .{ .text = "while", .kind = .kw_while },
    .{ .text = "match", .kind = .kw_match },
    .{ .text = "case", .kind = .kw_case },
    .{ .text = "return", .kind = .kw_return },
    .{ .text = "orelse", .kind = .kw_orelse },
    .{ .text = "comptime", .kind = .kw_comptime },
    .{ .text = "try", .kind = .kw_try },
    .{ .text = "end", .kind = .kw_end },
    .{ .text = "true", .kind = .kw_true },
    .{ .text = "false", .kind = .kw_false },
    .{ .text = "break", .kind = .kw_break },
    .{ .text = "continue", .kind = .kw_continue },
    .{ .text = "nil", .kind = .kw_nil },
};

pub fn lookup_keyword(text: []const u8) ?TokenType {
    for (keywords) |kw| {
        if (std.mem.eql(u8, kw.text, text)) return kw.kind;
    }
    return null;
}
