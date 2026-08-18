const Value = @import("value.zig").Value;

/// One bytecode instruction. Operands are stored directly on the variant
/// (jump targets, names, constants) rather than indexing into separate
/// pools -- simpler than byte-packed bytecode + constant tables, and
/// sufficient at this scale.
pub const Instruction = union(enum) {
    push_number: f64,
    push_string: []const u8,
    push_bool: bool,

    load_name: []const u8,
    store_name: []const u8,

    add,
    sub,
    mul,
    div,
    mod,
    neg,

    eq,
    ne,
    lt,
    le,
    gt,
    ge,

    build_list: u32,

    /// Pop `count` values (pushed left-to-right) and print them
    /// space-separated followed by a newline.
    print: u32,

    pop,

    /// Unconditional jump to an absolute instruction index.
    jump: u32,
    /// Pop a value; if falsy, jump to the absolute instruction index.
    jump_if_false: u32,

    /// Pop a list value, push an internal iterator value.
    get_iter,
    /// Peek the iterator on top of stack. If it has a next item, push it
    /// (net effect: stack gains one value) and fall through. If exhausted,
    /// pop the iterator and jump to the absolute instruction index.
    for_iter: u32,
    while_iter: u32,
};

pub const Chunk = struct {
    code: []Instruction,
};
