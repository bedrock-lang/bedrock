const std = @import("std");

const TokenType = enum {
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
    kw_end,
    kw_true,
    kw_false,

    // operators (single char)
    l_paren, // (
    r_paren, // )
    l_bracket, // [
    r_bracket, // ]
    l_brace, // { (reserved, not currently used by any rule but kept for symmetry)
    r_brace, // }
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
    question, // ?

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

    eof,
    unkown,
};
