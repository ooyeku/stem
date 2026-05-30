//! Pure-Zig WebAssembly interpreter.
//!
//! Scope: enough of the wasm 1.0 core spec to run stem plugins.
//! Plugins are compiled `zig build -Dtarget=wasm32-freestanding`,
//! call a small surface of host imports (`stem_log`,
//! `stem_register_command`, etc.), and export an `activate` function
//! plus one entry point per registered command. We don't aim for full
//! spec conformance — `f32`/`f64` arithmetic, `i64` ops, SIMD,
//! tables, reference types, multi-memory, and threads are all out of
//! scope for now. They can be added incrementally if a real plugin
//! needs them.
//!
//! What IS implemented:
//!   - Module decoding (sections: type, import, function, memory,
//!     global, export, start, code, data).
//!   - Linear memory (one instance, no growth across the limits).
//!   - Globals (mutable + immutable, all sizes but only i32 init).
//!   - Function calls (both imported host functions and wasm-defined).
//!   - Block / loop / if / else / end / br / br_if / return — full
//!     control flow with the canonical "label stack" model.
//!   - i32 / i64 arithmetic, comparisons, conversions, loads/stores.
//!   - drop, select, local.get/set/tee, global.get/set, i32.const,
//!     i64.const, memory.size, memory.grow.
//!
//! On hitting an instruction we don't implement, execution aborts
//! with `error.UnsupportedOp` and the opcode is logged — that's
//! deliberately load-bearing: it surfaces gaps as plugin failures
//! rather than silent miscompiles.
//!
//! Design notes:
//!   - Value stack is `std.ArrayListUnmanaged(u64)`. We store all
//!     scalar values as u64; the verifier elsewhere knows the type.
//!   - Control stack tracks open blocks/loops/ifs so `br` can pop
//!     N labels and rewind the value stack.
//!   - Memory is a single owned slice. Growth uses
//!     `allocator.realloc` capped at the declared maximum (default 64
//!     pages = 4 MiB).
//!   - Host imports are bound by name at instantiate-time.

const std = @import("std");
const log = std.log.scoped(.wasm);

pub const Error = error{
    InvalidModule,
    InvalidSection,
    UnsupportedOp,
    StackUnderflow,
    OutOfBounds,
    UnknownImport,
    Trap,
    DivideByZero,
    IntegerOverflow,
} || std.mem.Allocator.Error;

pub const PAGE_SIZE: u32 = 64 * 1024;
pub const DEFAULT_MAX_PAGES: u32 = 64; // 4 MiB cap

// ---------------------------------------------------------------------------
// Value types & wire-format constants
// ---------------------------------------------------------------------------

pub const ValueType = enum(u8) {
    i32 = 0x7F,
    i64 = 0x7E,
    f32 = 0x7D,
    f64 = 0x7C,
    _,
};

const SECTION_CUSTOM: u8 = 0;
const SECTION_TYPE: u8 = 1;
const SECTION_IMPORT: u8 = 2;
const SECTION_FUNCTION: u8 = 3;
const SECTION_TABLE: u8 = 4;
const SECTION_MEMORY: u8 = 5;
const SECTION_GLOBAL: u8 = 6;
const SECTION_EXPORT: u8 = 7;
const SECTION_START: u8 = 8;
const SECTION_ELEMENT: u8 = 9;
const SECTION_CODE: u8 = 10;
const SECTION_DATA: u8 = 11;
const SECTION_DATA_COUNT: u8 = 12;

// ---------------------------------------------------------------------------
// Decoded module
// ---------------------------------------------------------------------------

pub const FuncType = struct {
    params: []ValueType,
    results: []ValueType,
};

pub const ImportKind = enum { func, table, memory, global };

pub const Import = struct {
    module_name: []const u8,
    field_name: []const u8,
    kind: ImportKind,
    /// For func imports: the type index. For others: ignored.
    type_index: u32 = 0,
};

pub const MemoryLimits = struct {
    min_pages: u32,
    max_pages: u32,
};

pub const Global = struct {
    value_type: ValueType,
    mutable: bool,
    /// Decoded init expression result. Only i32/i64 const supported.
    init_value: u64,
};

pub const ExportKind = enum { func, table, memory, global };

pub const Export = struct {
    name: []const u8,
    kind: ExportKind,
    index: u32,
};

pub const FunctionBody = struct {
    /// Local declarations after the function's params, flattened.
    /// For now we track *count and type* only; the interpreter widens
    /// every local to u64 so the runtime layout is uniform.
    locals: []ValueType,
    /// Raw bytecode body, excluding the size prefix but including the
    /// terminating `end` byte.
    body: []const u8,
};

pub const DataSegment = struct {
    memory_index: u32,
    offset: u32,
    bytes: []const u8,
    /// Passive data segments aren't copied into linear memory at
    /// instance init — they sit dormant until a `memory.init` op
    /// pulls bytes from them. `data.drop` then marks them
    /// unreachable.
    passive: bool = false,
};

pub const Module = struct {
    /// Heap-allocated so its address (and therefore the allocator
    /// pointer captured by `aa = arena.allocator()`) is stable
    /// across the value-return of `decode()`. Moving the arena by
    /// value would invalidate the captured state pointer and leak
    /// every allocation made into it.
    arena: *std.heap.ArenaAllocator,
    types: []FuncType = &.{},
    imports: []Import = &.{},
    /// One entry per non-imported function; value is its type index.
    function_types: []u32 = &.{},
    memory: ?MemoryLimits = null,
    globals: []Global = &.{},
    exports: []Export = &.{},
    start_func: ?u32 = null,
    code: []FunctionBody = &.{},
    data_segments: []DataSegment = &.{},
    /// Cached count of imported functions — they occupy the low
    /// indices of the function index space.
    imported_func_count: u32 = 0,

    pub fn deinit(self: *Module) void {
        const child = self.arena.child_allocator;
        self.arena.deinit();
        child.destroy(self.arena);
    }

    pub fn findExport(self: *const Module, name: []const u8, kind: ExportKind) ?u32 {
        for (self.exports) |e| {
            if (e.kind == kind and std.mem.eql(u8, e.name, name)) return e.index;
        }
        return null;
    }
};

// ---------------------------------------------------------------------------
// LEB128 helpers
// ---------------------------------------------------------------------------

pub const Cursor = struct {
    bytes: []const u8,
    pos: usize = 0,

    pub fn remaining(self: Cursor) usize {
        return self.bytes.len - self.pos;
    }

    pub fn readByte(self: *Cursor) !u8 {
        if (self.pos >= self.bytes.len) return error.InvalidModule;
        const b = self.bytes[self.pos];
        self.pos += 1;
        return b;
    }

    pub fn readSlice(self: *Cursor, n: usize) ![]const u8 {
        if (self.pos + n > self.bytes.len) return error.InvalidModule;
        const s = self.bytes[self.pos .. self.pos + n];
        self.pos += n;
        return s;
    }

    pub fn readU32(self: *Cursor) !u32 {
        var result: u32 = 0;
        var shift: u5 = 0;
        while (true) {
            const byte = try self.readByte();
            // At the final group (shift 28) only the low 4 bits fit in a
            // u32; bits 4-6 would shift past bit 31 and trip the left-
            // shift-overflow safety check (a panic / DoS on malformed
            // input). Reject the bad LEB128 with a typed error instead.
            if (shift == 28 and (byte & 0x70) != 0) return error.InvalidModule;
            result |= (@as(u32, byte & 0x7F)) << shift;
            if ((byte & 0x80) == 0) return result;
            if (shift >= 28) return error.InvalidModule;
            shift += 7;
        }
    }

    pub fn readI32(self: *Cursor) !i32 {
        var result: i32 = 0;
        var shift: u5 = 0;
        var byte: u8 = 0;
        while (true) {
            byte = try self.readByte();
            result |= @as(i32, @intCast(byte & 0x7F)) << shift;
            if ((byte & 0x80) == 0) break;
            if (shift >= 28) return error.InvalidModule;
            shift += 7;
        }
        if (shift < 32 and (byte & 0x40) != 0) {
            // Sign-extend.
            result |= @as(i32, -1) << (shift + 7);
        }
        return result;
    }

    pub fn readI64(self: *Cursor) !i64 {
        var result: i64 = 0;
        var shift: u6 = 0;
        var byte: u8 = 0;
        while (true) {
            byte = try self.readByte();
            result |= @as(i64, @intCast(byte & 0x7F)) << shift;
            if ((byte & 0x80) == 0) break;
            if (shift >= 56) return error.InvalidModule;
            shift += 7;
        }
        if (shift < 57 and (byte & 0x40) != 0) {
            const ext_shift: u6 = @intCast(@as(u8, shift) + 7);
            result |= @as(i64, -1) << ext_shift;
        }
        return result;
    }

    pub fn readName(self: *Cursor) ![]const u8 {
        const len = try self.readU32();
        return try self.readSlice(len);
    }

    pub fn readValueType(self: *Cursor) !ValueType {
        const b = try self.readByte();
        return @enumFromInt(b);
    }
};

// ---------------------------------------------------------------------------
// Decoder
// ---------------------------------------------------------------------------

pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !Module {
    if (bytes.len < 8) return error.InvalidModule;
    if (!std.mem.eql(u8, bytes[0..4], &[_]u8{ 0x00, 0x61, 0x73, 0x6D })) return error.InvalidModule;
    const version = std.mem.readInt(u32, bytes[4..8], .little);
    if (version != 1) return error.InvalidModule;

    const arena = try allocator.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(allocator);
    errdefer {
        arena.deinit();
        allocator.destroy(arena);
    }
    const aa = arena.allocator();

    var module: Module = .{ .arena = arena };

    var cursor: Cursor = .{ .bytes = bytes, .pos = 8 };
    while (cursor.remaining() > 0) {
        const section_id = try cursor.readByte();
        const section_size = try cursor.readU32();
        if (cursor.pos + section_size > bytes.len) return error.InvalidSection;
        const section_bytes = bytes[cursor.pos .. cursor.pos + section_size];
        cursor.pos += section_size;

        var sc: Cursor = .{ .bytes = section_bytes };
        switch (section_id) {
            SECTION_CUSTOM => {}, // skip custom sections (name, producers, etc.)
            SECTION_TYPE => try decodeTypeSection(aa, &sc, &module),
            SECTION_IMPORT => try decodeImportSection(aa, &sc, &module),
            SECTION_FUNCTION => try decodeFunctionSection(aa, &sc, &module),
            SECTION_TABLE => {}, // table imports/exports recognized; bodies ignored
            SECTION_MEMORY => try decodeMemorySection(&sc, &module),
            SECTION_GLOBAL => try decodeGlobalSection(aa, &sc, &module),
            SECTION_EXPORT => try decodeExportSection(aa, &sc, &module),
            SECTION_START => {
                module.start_func = try sc.readU32();
            },
            SECTION_ELEMENT => {}, // tables not used for plugin entry yet
            SECTION_CODE => try decodeCodeSection(aa, &sc, &module),
            SECTION_DATA => try decodeDataSection(aa, &sc, &module),
            SECTION_DATA_COUNT => {},
            else => return error.InvalidSection,
        }
    }
    return module;
}

/// Read a LEB128 element count and reject it if it exceeds the bytes
/// left in the section. Every element costs at least one byte, so a
/// count larger than `remaining()` is necessarily malformed. This is
/// the guard that stops a forged count (e.g. 0xFFFFFFFF) from driving a
/// multi-gigabyte `alloc` before a single element is read — without it
/// a hostile plugin `.wasm` OOM-kills the host at load time.
fn readBoundedCount(sc: *Cursor) !u32 {
    const count = try sc.readU32();
    if (count > sc.remaining()) return error.InvalidSection;
    return count;
}

/// Upper bound on a single function's flattened local count. A local
/// declaration is `(count, type)`, where `count` is a virtual LEB128
/// value *not* backed by section bytes — so one entry can claim
/// billions. Far beyond any real function; exists only to bound that
/// allocation. See `decodeCodeSection`.
const MAX_FUNCTION_LOCALS: u32 = 1 << 20;

fn decodeTypeSection(aa: std.mem.Allocator, sc: *Cursor, module: *Module) !void {
    const count = try readBoundedCount(sc);
    const types = try aa.alloc(FuncType, count);
    for (types) |*ft| {
        const form = try sc.readByte();
        if (form != 0x60) return error.InvalidModule;
        const n_params = try readBoundedCount(sc);
        const params = try aa.alloc(ValueType, n_params);
        for (params) |*p| p.* = try sc.readValueType();
        const n_results = try readBoundedCount(sc);
        const results = try aa.alloc(ValueType, n_results);
        for (results) |*r| r.* = try sc.readValueType();
        ft.* = .{ .params = params, .results = results };
    }
    module.types = types;
}

fn decodeImportSection(aa: std.mem.Allocator, sc: *Cursor, module: *Module) !void {
    const count = try readBoundedCount(sc);
    const imports = try aa.alloc(Import, count);
    var func_imports: u32 = 0;
    for (imports) |*imp| {
        const mod_name = try sc.readName();
        const field_name = try sc.readName();
        const kind_byte = try sc.readByte();
        const mod_dup = try aa.dupe(u8, mod_name);
        const field_dup = try aa.dupe(u8, field_name);
        switch (kind_byte) {
            0x00 => {
                const type_idx = try sc.readU32();
                imp.* = .{
                    .module_name = mod_dup,
                    .field_name = field_dup,
                    .kind = .func,
                    .type_index = type_idx,
                };
                func_imports += 1;
            },
            0x01 => {
                // table: skip element_type + limits
                _ = try sc.readByte();
                try skipLimits(sc);
                imp.* = .{ .module_name = mod_dup, .field_name = field_dup, .kind = .table };
            },
            0x02 => {
                try skipLimits(sc);
                imp.* = .{ .module_name = mod_dup, .field_name = field_dup, .kind = .memory };
            },
            0x03 => {
                _ = try sc.readByte(); // value type
                _ = try sc.readByte(); // mutability
                imp.* = .{ .module_name = mod_dup, .field_name = field_dup, .kind = .global };
            },
            else => return error.InvalidModule,
        }
    }
    module.imports = imports;
    module.imported_func_count = func_imports;
}

fn skipLimits(sc: *Cursor) !void {
    const flag = try sc.readByte();
    _ = try sc.readU32();
    if (flag == 0x01) _ = try sc.readU32();
}

fn decodeFunctionSection(aa: std.mem.Allocator, sc: *Cursor, module: *Module) !void {
    const count = try readBoundedCount(sc);
    const ft = try aa.alloc(u32, count);
    for (ft) |*idx| idx.* = try sc.readU32();
    module.function_types = ft;
}

fn decodeMemorySection(sc: *Cursor, module: *Module) !void {
    const count = try readBoundedCount(sc);
    if (count == 0) return;
    // Read the first; ignore extras.
    const flag = try sc.readByte();
    const min_pages = try sc.readU32();
    const max_pages: u32 = if (flag == 0x01) try sc.readU32() else DEFAULT_MAX_PAGES;
    module.memory = .{ .min_pages = min_pages, .max_pages = max_pages };
    // Skip the rest (should be 0 for wasm 1.0).
    var i: u32 = 1;
    while (i < count) : (i += 1) {
        const f = try sc.readByte();
        _ = try sc.readU32();
        if (f == 0x01) _ = try sc.readU32();
    }
}

fn decodeGlobalSection(aa: std.mem.Allocator, sc: *Cursor, module: *Module) !void {
    const count = try readBoundedCount(sc);
    const gs = try aa.alloc(Global, count);
    for (gs) |*g| {
        const vt = try sc.readValueType();
        const mut = try sc.readByte();
        // init expression: i32.const N end  (or i64.const)
        const op = try sc.readByte();
        var init_val: u64 = 0;
        switch (op) {
            0x41 => { // i32.const
                const v = try sc.readI32();
                init_val = @as(u64, @bitCast(@as(i64, v)));
            },
            0x42 => { // i64.const
                const v = try sc.readI64();
                init_val = @as(u64, @bitCast(v));
            },
            else => return error.UnsupportedOp,
        }
        const terminator = try sc.readByte();
        if (terminator != 0x0B) return error.InvalidModule;
        g.* = .{ .value_type = vt, .mutable = mut == 1, .init_value = init_val };
    }
    module.globals = gs;
}

fn decodeExportSection(aa: std.mem.Allocator, sc: *Cursor, module: *Module) !void {
    const count = try readBoundedCount(sc);
    const exports = try aa.alloc(Export, count);
    for (exports) |*e| {
        const name = try sc.readName();
        const kind = try sc.readByte();
        const idx = try sc.readU32();
        const k: ExportKind = switch (kind) {
            0x00 => .func,
            0x01 => .table,
            0x02 => .memory,
            0x03 => .global,
            else => return error.InvalidModule,
        };
        e.* = .{ .name = try aa.dupe(u8, name), .kind = k, .index = idx };
    }
    module.exports = exports;
}

fn decodeCodeSection(aa: std.mem.Allocator, sc: *Cursor, module: *Module) !void {
    const count = try readBoundedCount(sc);
    const bodies = try aa.alloc(FunctionBody, count);
    for (bodies) |*body| {
        const body_size = try sc.readU32();
        const body_start = sc.pos;
        const body_end = body_start + body_size;
        if (body_end > sc.bytes.len) return error.InvalidModule;

        const n_locals = try readBoundedCount(sc);
        // Each local entry is (count, type). Flatten so the interpreter
        // can just index by local position. `count` is a virtual LEB128
        // value, so the running total is checked for overflow and capped
        // — otherwise one entry claiming billions drives a giant alloc.
        var total_locals: u32 = 0;
        const save_pos = sc.pos;
        var i: u32 = 0;
        while (i < n_locals) : (i += 1) {
            const c = try sc.readU32();
            _ = try sc.readByte();
            total_locals = std.math.add(u32, total_locals, c) catch return error.InvalidModule;
            if (total_locals > MAX_FUNCTION_LOCALS) return error.InvalidModule;
        }
        sc.pos = save_pos;
        const locals_flat = try aa.alloc(ValueType, total_locals);
        var li: usize = 0;
        i = 0;
        while (i < n_locals) : (i += 1) {
            const c = try sc.readU32();
            const t = try sc.readValueType();
            var j: u32 = 0;
            while (j < c) : (j += 1) {
                locals_flat[li] = t;
                li += 1;
            }
        }

        const raw_body = sc.bytes[sc.pos..body_end];
        // Dupe into the module's arena so the body outlives the input
        // byte slice the caller passed to `decode`.
        body.* = .{ .locals = locals_flat, .body = try aa.dupe(u8, raw_body) };
        sc.pos = body_end;
    }
    module.code = bodies;
}

fn decodeDataSection(aa: std.mem.Allocator, sc: *Cursor, module: *Module) !void {
    const count = try readBoundedCount(sc);
    const segs = try aa.alloc(DataSegment, count);
    for (segs) |*ds| {
        const flag = try sc.readU32();
        var mem_idx: u32 = 0;
        if (flag == 0x02) mem_idx = try sc.readU32();
        const active = flag != 0x01;
        var offset: u32 = 0;
        if (active) {
            // Init expression for offset: i32.const N end
            const op = try sc.readByte();
            if (op != 0x41) return error.UnsupportedOp;
            offset = @bitCast(try sc.readI32());
            const terminator = try sc.readByte();
            if (terminator != 0x0B) return error.InvalidModule;
        }
        const len = try sc.readU32();
        const data = try sc.readSlice(len);
        ds.* = .{
            .memory_index = mem_idx,
            .offset = offset,
            .bytes = try aa.dupe(u8, data),
            .passive = !active,
        };
    }
    module.data_segments = segs;
}

// ---------------------------------------------------------------------------
// Host import binding
// ---------------------------------------------------------------------------

/// Host function signature. `instance` lets the host poke at memory.
/// `args` are the wasm operands popped right-to-left and presented
/// left-to-right (i.e. the first wasm parameter is `args[0]`).
/// Return one or zero u64 values via `result`.
pub const HostFn = *const fn (instance: *Instance, args: []const u64, result: *u64) Error!void;

pub const HostImport = struct {
    module_name: []const u8,
    field_name: []const u8,
    func: HostFn,
};

// ---------------------------------------------------------------------------
// Instance (runtime state)
// ---------------------------------------------------------------------------

pub const Instance = struct {
    allocator: std.mem.Allocator,
    module: *const Module,
    /// Linear memory bytes. Owned.
    memory: []u8 = &.{},
    memory_pages: u32 = 0,
    memory_max_pages: u32 = DEFAULT_MAX_PAGES,
    /// Mutable globals + host-bound imported globals.
    globals: []u64 = &.{},
    /// Resolved host functions in import order — one per imported func.
    host_funcs: []?HostFn = &.{},
    /// User pointer passed through to host functions (we make it
    /// accessible via `Instance` to keep the HostFn signature small).
    user_data: ?*anyopaque = null,

    /// Per-segment "dropped" flag — one bool per `module.data_segments`
    /// entry. `data.drop` flips a segment's entry to true; further
    /// `memory.init` against a dropped segment traps. Per-instance
    /// rather than on `Module` because two instances of the same
    /// module track drops independently.
    dropped_data: []bool = &.{},

    pub fn deinit(self: *Instance) void {
        if (self.memory.len > 0) self.allocator.free(self.memory);
        if (self.globals.len > 0) self.allocator.free(self.globals);
        if (self.host_funcs.len > 0) self.allocator.free(self.host_funcs);
        if (self.dropped_data.len > 0) self.allocator.free(self.dropped_data);
    }

    /// Copy `len` bytes at wasm linear-memory offset `off` into a
    /// host-side slice. Caller owns.
    pub fn readBytes(self: *Instance, allocator: std.mem.Allocator, off: u32, len: u32) ![]u8 {
        if (@as(u64, off) + len > self.memory.len) return error.OutOfBounds;
        return allocator.dupe(u8, self.memory[off .. off + len]);
    }

    /// Borrow a slice of wasm linear memory. Valid until the next
    /// `memory.grow`.
    pub fn slice(self: *Instance, off: u32, len: u32) ![]u8 {
        if (@as(u64, off) + len > self.memory.len) return error.OutOfBounds;
        return self.memory[off .. off + len];
    }

    /// Look up the type signature of a defined function by index in
    /// the function index space (imports + locals).
    pub fn funcType(self: *Instance, func_idx: u32) ?*const FuncType {
        const m = self.module;
        if (func_idx < m.imported_func_count) {
            // Imported func: find its type via the imports list.
            var idx: u32 = 0;
            for (m.imports) |imp| {
                if (imp.kind == .func) {
                    if (idx == func_idx) {
                        if (imp.type_index >= m.types.len) return null;
                        return &m.types[imp.type_index];
                    }
                    idx += 1;
                }
            }
            return null;
        }
        const local_idx = func_idx - m.imported_func_count;
        if (local_idx >= m.function_types.len) return null;
        const t_idx = m.function_types[local_idx];
        if (t_idx >= m.types.len) return null;
        return &m.types[t_idx];
    }
};

pub fn instantiate(
    allocator: std.mem.Allocator,
    module: *const Module,
    host_imports: []const HostImport,
    user_data: ?*anyopaque,
) !Instance {
    var inst: Instance = .{
        .allocator = allocator,
        .module = module,
        .user_data = user_data,
    };
    errdefer inst.deinit();

    // Memory.
    if (module.memory) |mem_def| {
        inst.memory_pages = mem_def.min_pages;
        inst.memory_max_pages = mem_def.max_pages;
        inst.memory = try allocator.alloc(u8, @as(usize, mem_def.min_pages) * PAGE_SIZE);
        @memset(inst.memory, 0);
    }

    // Per-instance "is this segment unreachable?" bitmap. Active
    // segments are pre-marked as dropped: per the bulk-memory spec,
    // active segments are implicitly dropped right after their
    // initialisation copy, so any `memory.init` referencing them
    // post-instantiation must trap. Passive segments start alive and
    // flip true when `data.drop` runs against them.
    inst.dropped_data = try allocator.alloc(bool, module.data_segments.len);
    for (module.data_segments, 0..) |ds, i| {
        inst.dropped_data[i] = !ds.passive;
    }

    // Apply active data segments at their declared offsets. Passive
    // segments stay dormant until a `memory.init` op references them
    // (or `data.drop` marks them unreachable).
    for (module.data_segments) |ds| {
        if (ds.passive) continue;
        if (ds.offset + ds.bytes.len > inst.memory.len) return error.OutOfBounds;
        @memcpy(inst.memory[ds.offset .. ds.offset + ds.bytes.len], ds.bytes);
    }

    // Globals.
    inst.globals = try allocator.alloc(u64, module.globals.len);
    for (module.globals, 0..) |g, i| inst.globals[i] = g.init_value;

    // Resolve imports.
    inst.host_funcs = try allocator.alloc(?HostFn, module.imported_func_count);
    @memset(inst.host_funcs, null);
    var imp_func_idx: u32 = 0;
    for (module.imports) |imp| {
        if (imp.kind != .func) continue;
        var resolved = false;
        for (host_imports) |h| {
            if (std.mem.eql(u8, h.module_name, imp.module_name) and
                std.mem.eql(u8, h.field_name, imp.field_name))
            {
                inst.host_funcs[imp_func_idx] = h.func;
                resolved = true;
                break;
            }
        }
        if (!resolved) {
            log.warn("unresolved import: {s}.{s}", .{ imp.module_name, imp.field_name });
            return error.UnknownImport;
        }
        imp_func_idx += 1;
    }

    return inst;
}

// ---------------------------------------------------------------------------
// Interpreter
// ---------------------------------------------------------------------------

const Frame = struct {
    func_idx: u32,
    body: []const u8,
    pc: usize,
    /// Locals = params + declared locals, flattened to u64.
    locals: []u64,
    /// Number of values on the value stack at entry — used to
    /// determine how many results to return.
    value_stack_base: usize,
    /// Number of control entries on the control stack at entry.
    control_base: usize,
    /// Number of result values this function returns.
    result_count: u32,
};

const Label = struct {
    kind: enum { block, loop, @"if" },
    /// PC of the matching `end` (block/if) or the loop's start (loop).
    /// Resolved lazily on first encounter.
    branch_target: ?usize = null,
    /// Number of values to pop after a `br` to this label.
    arity: u32,
    /// Value stack height when this label was opened.
    stack_height: usize,
    /// For `if`, the position of the `else` byte, if any.
    else_pc: ?usize = null,
    /// PC immediately after the matching `end`.
    end_pc: ?usize = null,
};

const MAX_STACK = 16 * 1024;
const MAX_FRAMES = 512;

pub fn invoke(
    inst: *Instance,
    func_idx: u32,
    args: []const u64,
    results: []u64,
) Error!u32 {
    var value_stack: std.ArrayListUnmanaged(u64) = .empty;
    defer value_stack.deinit(inst.allocator);
    try value_stack.ensureTotalCapacity(inst.allocator, 256);

    var frames: std.ArrayListUnmanaged(Frame) = .empty;
    defer frames.deinit(inst.allocator);

    var labels: std.ArrayListUnmanaged(Label) = .empty;
    defer labels.deinit(inst.allocator);

    // Push the initial call.
    try pushCall(inst, &value_stack, &frames, &labels, func_idx, args);

    while (frames.items.len > 0) {
        try step(inst, &value_stack, &frames, &labels);
    }

    // Copy out top-of-stack results (already in the right order — pushes happened in order).
    if (value_stack.items.len < results.len) return error.StackUnderflow;
    const start = value_stack.items.len - results.len;
    @memcpy(results, value_stack.items[start..]);
    return @intCast(results.len);
}

fn pushCall(
    inst: *Instance,
    vs: *std.ArrayListUnmanaged(u64),
    frames: *std.ArrayListUnmanaged(Frame),
    labels: *std.ArrayListUnmanaged(Label),
    func_idx: u32,
    args: []const u64,
) !void {
    if (frames.items.len >= MAX_FRAMES) return error.Trap;
    const m = inst.module;
    if (func_idx < m.imported_func_count) {
        // Host call.
        const host = inst.host_funcs[func_idx] orelse return error.UnknownImport;
        var result: u64 = 0;
        try host(inst, args, &result);
        // Determine if the host fn returns a value (per type).
        const ft = inst.funcType(func_idx) orelse return error.InvalidModule;
        if (ft.results.len > 0) try vs.append(inst.allocator, result);
        return;
    }
    const local_idx = func_idx - m.imported_func_count;
    if (local_idx >= m.code.len) return error.InvalidModule;
    const body = m.code[local_idx];
    const t_idx = m.function_types[local_idx];
    const ft = m.types[t_idx];

    // Build the locals array: params + declared locals (zero-init).
    const total_locals = ft.params.len + body.locals.len;
    const locals = try inst.allocator.alloc(u64, total_locals);
    @memcpy(locals[0..args.len], args);
    if (args.len < ft.params.len) {
        // Missing args: zero-fill.
        @memset(locals[args.len..ft.params.len], 0);
    }
    @memset(locals[ft.params.len..], 0);

    try frames.append(inst.allocator, .{
        .func_idx = func_idx,
        .body = body.body,
        .pc = 0,
        .locals = locals,
        .value_stack_base = vs.items.len,
        .control_base = labels.items.len,
        .result_count = @intCast(ft.results.len),
    });
}

fn popFrame(
    inst: *Instance,
    vs: *std.ArrayListUnmanaged(u64),
    frames: *std.ArrayListUnmanaged(Frame),
    labels: *std.ArrayListUnmanaged(Label),
) !void {
    const frame = frames.pop() orelse return error.StackUnderflow;
    defer inst.allocator.free(frame.locals);
    // Move result_count values from the top to value_stack_base.
    const rc = frame.result_count;
    if (vs.items.len < frame.value_stack_base + rc) return error.StackUnderflow;
    if (rc > 0) {
        const top_start = vs.items.len - rc;
        // Slide results down to value_stack_base.
        std.mem.copyForwards(u64, vs.items[frame.value_stack_base .. frame.value_stack_base + rc], vs.items[top_start .. top_start + rc]);
    }
    vs.shrinkRetainingCapacity(frame.value_stack_base + rc);
    // Clear any labels left dangling.
    while (labels.items.len > frame.control_base) _ = labels.pop();
}

fn step(
    inst: *Instance,
    vs: *std.ArrayListUnmanaged(u64),
    frames: *std.ArrayListUnmanaged(Frame),
    labels: *std.ArrayListUnmanaged(Label),
) !void {
    var frame = &frames.items[frames.items.len - 1];
    if (frame.pc >= frame.body.len) {
        // Implicit function end — return.
        try popFrame(inst, vs, frames, labels);
        return;
    }
    const opcode = frame.body[frame.pc];
    frame.pc += 1;

    switch (opcode) {
        0x00 => return error.Trap, // unreachable
        0x01 => {}, // nop
        0x02 => { // block
            const bt = try readBlockType(frame);
            try labels.append(inst.allocator, .{
                .kind = .block,
                .arity = blockArity(inst, bt),
                .stack_height = vs.items.len,
            });
        },
        0x03 => { // loop
            const bt = try readBlockType(frame);
            _ = bt; // loop branches go to start, no result arity for branches
            try labels.append(inst.allocator, .{
                .kind = .loop,
                .branch_target = frame.pc,
                .arity = 0,
                .stack_height = vs.items.len,
            });
        },
        0x04 => { // if
            const bt = try readBlockType(frame);
            const cond = try pop(vs);
            try labels.append(inst.allocator, .{
                .kind = .@"if",
                .arity = blockArity(inst, bt),
                .stack_height = vs.items.len,
            });
            if (@as(i32, @bitCast(@as(u32, @truncate(cond)))) == 0) {
                // Skip to `else` or matching `end`.
                try skipToElseOrEnd(frame, labels);
            }
        },
        0x05 => { // else
            // Skip from else to matching end.
            try skipToEnd(frame, labels);
        },
        0x0B => { // end
            if (labels.items.len > frame.control_base) {
                _ = labels.pop();
            } else {
                // End of function body.
                try popFrame(inst, vs, frames, labels);
            }
        },
        0x0C => { // br
            const depth = try readU32Body(frame);
            try doBranch(inst, vs, frames, labels, depth);
        },
        0x0D => { // br_if
            const depth = try readU32Body(frame);
            const cond = try pop(vs);
            if (@as(i32, @bitCast(@as(u32, @truncate(cond)))) != 0) {
                try doBranch(inst, vs, frames, labels, depth);
            }
        },
        0x0E => { // br_table
            const n = try readU32Body(frame);
            const targets = try inst.allocator.alloc(u32, n);
            defer inst.allocator.free(targets);
            var i: u32 = 0;
            while (i < n) : (i += 1) targets[i] = try readU32Body(frame);
            const default = try readU32Body(frame);
            const idx_v: i32 = @bitCast(@as(u32, @truncate(try pop(vs))));
            const chosen: u32 = if (idx_v >= 0 and @as(u32, @bitCast(idx_v)) < n)
                targets[@as(u32, @bitCast(idx_v))]
            else
                default;
            try doBranch(inst, vs, frames, labels, chosen);
        },
        0x0F => { // return
            // Truncate to outer frame results.
            try popFrame(inst, vs, frames, labels);
        },
        0x10 => { // call
            const callee = try readU32Body(frame);
            try callFunction(inst, vs, frames, labels, callee);
        },
        0x11 => { // call_indirect (tables not supported)
            _ = try readU32Body(frame);
            _ = try readU32Body(frame);
            return error.UnsupportedOp;
        },
        0x1A => _ = try pop(vs), // drop
        0x1B => { // select
            const c = try pop(vs);
            const b = try pop(vs);
            const a = try pop(vs);
            try push(inst, vs, if (@as(i32, @bitCast(@as(u32, @truncate(c)))) != 0) a else b);
        },
        0x20 => { // local.get
            const idx = try readU32Body(frame);
            if (idx >= frame.locals.len) return error.InvalidModule;
            try push(inst, vs, frame.locals[idx]);
        },
        0x21 => { // local.set
            const idx = try readU32Body(frame);
            if (idx >= frame.locals.len) return error.InvalidModule;
            frame.locals[idx] = try pop(vs);
        },
        0x22 => { // local.tee
            const idx = try readU32Body(frame);
            if (idx >= frame.locals.len) return error.InvalidModule;
            const v = vs.items[vs.items.len - 1];
            frame.locals[idx] = v;
        },
        0x23 => { // global.get
            const idx = try readU32Body(frame);
            if (idx >= inst.globals.len) return error.InvalidModule;
            try push(inst, vs, inst.globals[idx]);
        },
        0x24 => { // global.set
            const idx = try readU32Body(frame);
            if (idx >= inst.globals.len) return error.InvalidModule;
            inst.globals[idx] = try pop(vs);
        },

        // Memory loads. The format is `align imm | offset imm`.
        0x28 => try memLoad(inst, vs, frame, 4, .i32, false), // i32.load
        0x29 => try memLoad(inst, vs, frame, 8, .i64, false), // i64.load
        0x2C => try memLoad(inst, vs, frame, 1, .i32, true), // i32.load8_s
        0x2D => try memLoad(inst, vs, frame, 1, .i32, false), // i32.load8_u
        0x2E => try memLoad(inst, vs, frame, 2, .i32, true), // i32.load16_s
        0x2F => try memLoad(inst, vs, frame, 2, .i32, false), // i32.load16_u
        0x30 => try memLoad(inst, vs, frame, 1, .i64, true), // i64.load8_s
        0x31 => try memLoad(inst, vs, frame, 1, .i64, false), // i64.load8_u
        0x32 => try memLoad(inst, vs, frame, 2, .i64, true), // i64.load16_s
        0x33 => try memLoad(inst, vs, frame, 2, .i64, false), // i64.load16_u
        0x34 => try memLoad(inst, vs, frame, 4, .i64, true), // i64.load32_s
        0x35 => try memLoad(inst, vs, frame, 4, .i64, false), // i64.load32_u

        0x36 => try memStore(inst, vs, frame, 4), // i32.store
        0x37 => try memStore(inst, vs, frame, 8), // i64.store
        0x3A => try memStore(inst, vs, frame, 1), // i32.store8
        0x3B => try memStore(inst, vs, frame, 2), // i32.store16
        0x3C => try memStore(inst, vs, frame, 1), // i64.store8
        0x3D => try memStore(inst, vs, frame, 2), // i64.store16
        0x3E => try memStore(inst, vs, frame, 4), // i64.store32

        0x3F => { // memory.size
            _ = try readByteBody(frame);
            try push(inst, vs, @as(u64, inst.memory_pages));
        },
        0x40 => { // memory.grow
            _ = try readByteBody(frame);
            const delta: u32 = @truncate(try pop(vs));
            const old = inst.memory_pages;
            const want = old + delta;
            if (want > inst.memory_max_pages) {
                try push(inst, vs, @as(u64, @bitCast(@as(i64, -1))));
            } else {
                const new_bytes = inst.allocator.realloc(inst.memory, @as(usize, want) * PAGE_SIZE) catch {
                    try push(inst, vs, @as(u64, @bitCast(@as(i64, -1))));
                    return;
                };
                @memset(new_bytes[inst.memory.len..], 0);
                inst.memory = new_bytes;
                inst.memory_pages = want;
                try push(inst, vs, @as(u64, old));
            }
        },

        0x41 => { // i32.const
            const v = try readI32Body(frame);
            try push(inst, vs, @as(u64, @as(u32, @bitCast(v))));
        },
        0x42 => { // i64.const
            const v = try readI64Body(frame);
            try push(inst, vs, @as(u64, @bitCast(v)));
        },

        // i32 unary/comparisons
        0x45 => { // i32.eqz
            const a: u32 = @truncate(try pop(vs));
            try push(inst, vs, if (a == 0) 1 else 0);
        },
        0x46 => try i32Cmp(inst, vs, .eq),
        0x47 => try i32Cmp(inst, vs, .ne),
        0x48 => try i32Cmp(inst, vs, .lt_s),
        0x49 => try i32Cmp(inst, vs, .lt_u),
        0x4A => try i32Cmp(inst, vs, .gt_s),
        0x4B => try i32Cmp(inst, vs, .gt_u),
        0x4C => try i32Cmp(inst, vs, .le_s),
        0x4D => try i32Cmp(inst, vs, .le_u),
        0x4E => try i32Cmp(inst, vs, .ge_s),
        0x4F => try i32Cmp(inst, vs, .ge_u),

        0x50 => { // i64.eqz
            const a = try pop(vs);
            try push(inst, vs, if (a == 0) 1 else 0);
        },
        0x51 => try i64Cmp(inst, vs, .eq),
        0x52 => try i64Cmp(inst, vs, .ne),
        0x53 => try i64Cmp(inst, vs, .lt_s),
        0x54 => try i64Cmp(inst, vs, .lt_u),
        0x55 => try i64Cmp(inst, vs, .gt_s),
        0x56 => try i64Cmp(inst, vs, .gt_u),
        0x57 => try i64Cmp(inst, vs, .le_s),
        0x58 => try i64Cmp(inst, vs, .le_u),
        0x59 => try i64Cmp(inst, vs, .ge_s),
        0x5A => try i64Cmp(inst, vs, .ge_u),

        // i32 bit/arith ops
        0x67 => try i32Clz(inst, vs),
        0x68 => try i32Ctz(inst, vs),
        0x69 => try i32Popcnt(inst, vs),
        0x6A => try i32Binop(inst, vs, .add),
        0x6B => try i32Binop(inst, vs, .sub),
        0x6C => try i32Binop(inst, vs, .mul),
        0x6D => try i32Binop(inst, vs, .div_s),
        0x6E => try i32Binop(inst, vs, .div_u),
        0x6F => try i32Binop(inst, vs, .rem_s),
        0x70 => try i32Binop(inst, vs, .rem_u),
        0x71 => try i32Binop(inst, vs, .@"and"),
        0x72 => try i32Binop(inst, vs, .@"or"),
        0x73 => try i32Binop(inst, vs, .xor),
        0x74 => try i32Binop(inst, vs, .shl),
        0x75 => try i32Binop(inst, vs, .shr_s),
        0x76 => try i32Binop(inst, vs, .shr_u),
        0x77 => try i32Binop(inst, vs, .rotl),
        0x78 => try i32Binop(inst, vs, .rotr),

        // i64 arith
        0x7C => try i64Binop(inst, vs, .add),
        0x7D => try i64Binop(inst, vs, .sub),
        0x7E => try i64Binop(inst, vs, .mul),
        0x7F => try i64Binop(inst, vs, .div_s),
        0x80 => try i64Binop(inst, vs, .div_u),
        0x81 => try i64Binop(inst, vs, .rem_s),
        0x82 => try i64Binop(inst, vs, .rem_u),
        0x83 => try i64Binop(inst, vs, .@"and"),
        0x84 => try i64Binop(inst, vs, .@"or"),
        0x85 => try i64Binop(inst, vs, .xor),
        0x86 => try i64Binop(inst, vs, .shl),
        0x87 => try i64Binop(inst, vs, .shr_s),
        0x88 => try i64Binop(inst, vs, .shr_u),

        // Conversions
        0xA7 => { // i32.wrap_i64
            const v = try pop(vs);
            try push(inst, vs, @as(u64, @as(u32, @truncate(v))));
        },
        0xAC => { // i64.extend_i32_s
            const v: i32 = @bitCast(@as(u32, @truncate(try pop(vs))));
            try push(inst, vs, @as(u64, @bitCast(@as(i64, v))));
        },
        0xAD => { // i64.extend_i32_u
            const v: u32 = @truncate(try pop(vs));
            try push(inst, vs, @as(u64, v));
        },

        // Sign-extension ops (post-MVP, but Zig emits them freely).
        0xC0 => { // i32.extend8_s
            const v: i8 = @bitCast(@as(u8, @truncate(try pop(vs))));
            try push(inst, vs, @as(u64, @as(u32, @bitCast(@as(i32, v)))));
        },
        0xC1 => { // i32.extend16_s
            const v: i16 = @bitCast(@as(u16, @truncate(try pop(vs))));
            try push(inst, vs, @as(u64, @as(u32, @bitCast(@as(i32, v)))));
        },
        0xC2 => { // i64.extend8_s
            const v: i8 = @bitCast(@as(u8, @truncate(try pop(vs))));
            try push(inst, vs, @as(u64, @bitCast(@as(i64, v))));
        },
        0xC3 => { // i64.extend16_s
            const v: i16 = @bitCast(@as(u16, @truncate(try pop(vs))));
            try push(inst, vs, @as(u64, @bitCast(@as(i64, v))));
        },
        0xC4 => { // i64.extend32_s
            const v: i32 = @bitCast(@as(u32, @truncate(try pop(vs))));
            try push(inst, vs, @as(u64, @bitCast(@as(i64, v))));
        },

        // 0xfc-prefixed family: bulk memory + saturating truncations.
        // The next byte is the sub-opcode; we only implement the
        // subops Zig actually emits for our plugins (`memory.copy`
        // and `memory.fill`).
        0xFC => try stepFC(inst, vs, frame),

        else => {
            log.warn("unsupported opcode 0x{x:0>2} at pc={d}", .{ opcode, frame.pc - 1 });
            return error.UnsupportedOp;
        },
    }
}

fn stepFC(inst: *Instance, vs: *std.ArrayListUnmanaged(u64), frame: *Frame) !void {
    const sub = try readU32Body(frame);
    switch (sub) {
        // memory.init: copy from a passive data segment into linear
        // memory. Immediates: `data_idx` (u32), `mem_idx` (u8). Pops
        // n, src_offset, dst (i32 each).
        0x08 => {
            const data_idx = try readU32Body(frame);
            _ = try readByteBody(frame); // memory index — only 0 in MVP
            const n: u32 = @truncate(try pop(vs));
            const src: u32 = @truncate(try pop(vs));
            const dst: u32 = @truncate(try pop(vs));
            if (data_idx >= inst.module.data_segments.len) return error.Trap;
            if (data_idx >= inst.dropped_data.len or inst.dropped_data[data_idx]) return error.Trap;
            const ds = inst.module.data_segments[data_idx];
            const end_src = @as(u64, src) + n;
            const end_dst = @as(u64, dst) + n;
            if (end_src > ds.bytes.len or end_dst > inst.memory.len) return error.Trap;
            if (n == 0) return;
            @memcpy(inst.memory[dst .. dst + n], ds.bytes[src .. src + n]);
        },
        // data.drop: mark a passive data segment as no longer
        // available. Further `memory.init` against it traps.
        0x09 => {
            const data_idx = try readU32Body(frame);
            if (data_idx < inst.dropped_data.len) {
                inst.dropped_data[data_idx] = true;
            }
        },
        // memory.copy: immediates are two memory indices (both 0 in
        // the MVP). Pops n, src, dst (i32 each), then copies n bytes
        // from `memory[src..]` to `memory[dst..]`. Handles overlap by
        // direction-sensitive copy.
        0x0A => {
            _ = try readByteBody(frame); // dst memory index
            _ = try readByteBody(frame); // src memory index
            const n: u32 = @truncate(try pop(vs));
            const src: u32 = @truncate(try pop(vs));
            const dst: u32 = @truncate(try pop(vs));
            if (n == 0) return;
            const end_src = @as(u64, src) + n;
            const end_dst = @as(u64, dst) + n;
            if (end_src > inst.memory.len or end_dst > inst.memory.len) return error.Trap;
            // Forward-or-backward to handle overlap correctly.
            if (dst <= src) {
                std.mem.copyForwards(u8, inst.memory[dst .. dst + n], inst.memory[src .. src + n]);
            } else {
                std.mem.copyBackwards(u8, inst.memory[dst .. dst + n], inst.memory[src .. src + n]);
            }
        },
        // memory.fill: immediate is one memory index. Pops n, value,
        // dst — fills `memory[dst..dst+n]` with `value & 0xff`.
        0x0B => {
            _ = try readByteBody(frame); // memory index
            const n: u32 = @truncate(try pop(vs));
            const value: u8 = @truncate(try pop(vs));
            const dst: u32 = @truncate(try pop(vs));
            if (n == 0) return;
            const end_dst = @as(u64, dst) + n;
            if (end_dst > inst.memory.len) return error.Trap;
            @memset(inst.memory[dst .. dst + n], value);
        },
        else => {
            log.warn("unsupported 0xfc subop 0x{x:0>2} at pc={d}", .{ sub, frame.pc - 1 });
            return error.UnsupportedOp;
        },
    }
}

// ---------------------------------------------------------------------------
// Body-cursor helpers (read directly from frame.body @ frame.pc)
// ---------------------------------------------------------------------------

const FrameBodyExt = struct {};

fn readByteBody(frame: *Frame) !u8 {
    if (frame.pc >= frame.body.len) return error.InvalidModule;
    const b = frame.body[frame.pc];
    frame.pc += 1;
    return b;
}

fn readU32Body(frame: *Frame) !u32 {
    var result: u32 = 0;
    var shift: u5 = 0;
    while (true) {
        const byte = try readByteBody(frame);
        result |= (@as(u32, byte & 0x7F)) << shift;
        if ((byte & 0x80) == 0) return result;
        if (shift >= 28) return error.InvalidModule;
        shift += 7;
    }
}

fn readI32Body(frame: *Frame) !i32 {
    var result: i32 = 0;
    var shift: u5 = 0;
    var byte: u8 = 0;
    while (true) {
        byte = try readByteBody(frame);
        result |= @as(i32, @intCast(byte & 0x7F)) << shift;
        if ((byte & 0x80) == 0) break;
        if (shift >= 28) return error.InvalidModule;
        shift += 7;
    }
    if (shift < 32 and (byte & 0x40) != 0) {
        result |= @as(i32, -1) << (shift + 7);
    }
    return result;
}

fn readI64Body(frame: *Frame) !i64 {
    var result: i64 = 0;
    var shift: u6 = 0;
    var byte: u8 = 0;
    while (true) {
        byte = try readByteBody(frame);
        result |= @as(i64, @intCast(byte & 0x7F)) << shift;
        if ((byte & 0x80) == 0) break;
        if (shift >= 56) return error.InvalidModule;
        shift += 7;
    }
    if (shift < 57 and (byte & 0x40) != 0) {
        const ext_shift: u6 = @intCast(@as(u8, shift) + 7);
        result |= @as(i64, -1) << ext_shift;
    }
    return result;
}

// ---------------------------------------------------------------------------
// Block / branch helpers
// ---------------------------------------------------------------------------

const BlockType = union(enum) {
    empty,
    value: ValueType,
    type_idx: u32,
};

fn readBlockType(frame: *Frame) !BlockType {
    const b = try readByteBody(frame);
    if (b == 0x40) return .empty;
    if (b == 0x7F or b == 0x7E or b == 0x7D or b == 0x7C) return .{ .value = @enumFromInt(b) };
    // SLEB128 type index — we put back the byte and re-read.
    frame.pc -= 1;
    const idx = try readI32Body(frame);
    if (idx < 0) return error.InvalidModule;
    return .{ .type_idx = @intCast(idx) };
}

fn blockArity(inst: *Instance, bt: BlockType) u32 {
    return switch (bt) {
        .empty => 0,
        .value => 1,
        .type_idx => |i| if (i < inst.module.types.len) @intCast(inst.module.types[i].results.len) else 0,
    };
}

fn doBranch(
    inst: *Instance,
    vs: *std.ArrayListUnmanaged(u64),
    frames: *std.ArrayListUnmanaged(Frame),
    labels: *std.ArrayListUnmanaged(Label),
    depth: u32,
) !void {
    const frame = &frames.items[frames.items.len - 1];
    const frame_label_count = labels.items.len - frame.control_base;
    if (depth >= frame_label_count) {
        // Branch to the implicit function-level label = return.
        try popFrame(inst, vs, frames, labels);
        return;
    }
    const label_idx = labels.items.len - 1 - depth;
    const label = labels.items[label_idx];
    switch (label.kind) {
        .loop => {
            frame.pc = label.branch_target.?;
            vs.shrinkRetainingCapacity(label.stack_height);
            while (labels.items.len > label_idx + 1) _ = labels.pop();
        },
        .block, .@"if" => {
            // For `br depth=N` to a block/if, control jumps to just
            // past that label's `end` byte. We're currently inside
            // it AND inside `depth` more nested labels — so we need
            // to consume (depth + 1) end bytes in total. Each
            // scanToEnd call advances past exactly one matching end;
            // the next call starts inside the next-outer label and
            // walks to that one's end.
            const skips = labels.items.len - label_idx;
            var k: usize = 0;
            while (k < skips) : (k += 1) {
                try scanToEnd(frame, label_idx, labels);
            }
            while (labels.items.len > label_idx) _ = labels.pop();
            if (label.arity > 0 and vs.items.len >= label.arity) {
                const keep_from = vs.items.len - label.arity;
                std.mem.copyForwards(u64, vs.items[label.stack_height .. label.stack_height + label.arity], vs.items[keep_from .. keep_from + label.arity]);
                vs.shrinkRetainingCapacity(label.stack_height + label.arity);
            } else {
                vs.shrinkRetainingCapacity(label.stack_height);
            }
        },
    }
}

/// Forward-scan the body to find the matching `end` for the
/// currently-pending label and advance `frame.pc` past it.
fn scanToEnd(frame: *Frame, _: usize, _: *std.ArrayListUnmanaged(Label)) !void {
    var depth: u32 = 0;
    while (frame.pc < frame.body.len) {
        const op = frame.body[frame.pc];
        frame.pc += 1;
        switch (op) {
            0x02, 0x03, 0x04 => { // block, loop, if
                _ = try readBlockType(frame);
                depth += 1;
            },
            0x0B => { // end
                if (depth == 0) return;
                depth -= 1;
            },
            // Skip args of opcodes that have immediates.
            0x0C, 0x0D, 0x10, 0x20, 0x21, 0x22, 0x23, 0x24, 0x3F, 0x40, 0x41 => {
                _ = try readU32Body(frame);
            },
            0x42 => _ = try readI64Body(frame),
            0x44 => frame.pc += 8, // f64.const
            0x43 => frame.pc += 4, // f32.const
            0x0E => { // br_table
                const n = try readU32Body(frame);
                var i: u32 = 0;
                while (i < n) : (i += 1) _ = try readU32Body(frame);
                _ = try readU32Body(frame); // default
            },
            0x11 => { // call_indirect
                _ = try readU32Body(frame);
                _ = try readU32Body(frame);
            },
            // Memory ops: align imm, offset imm
            0x28...0x3E => {
                _ = try readU32Body(frame);
                _ = try readU32Body(frame);
            },
            // 0xfc family: sub-opcode + variable immediates.
            0xFC => try skipFCImmediates(frame),
            else => {},
        }
    }
    return error.InvalidModule;
}

fn skipToElseOrEnd(frame: *Frame, labels: *std.ArrayListUnmanaged(Label)) !void {
    var depth: u32 = 0;
    while (frame.pc < frame.body.len) {
        const op = frame.body[frame.pc];
        frame.pc += 1;
        switch (op) {
            0x02, 0x03, 0x04 => {
                _ = try readBlockType(frame);
                depth += 1;
            },
            0x05 => { // else
                if (depth == 0) return;
            },
            0x0B => { // end
                if (depth == 0) {
                    // Pop the if-label since we consumed its end.
                    _ = labels.pop();
                    return;
                }
                depth -= 1;
            },
            0x0C, 0x0D, 0x10, 0x20, 0x21, 0x22, 0x23, 0x24, 0x3F, 0x40, 0x41 => _ = try readU32Body(frame),
            0x42 => _ = try readI64Body(frame),
            0x44 => frame.pc += 8,
            0x43 => frame.pc += 4,
            0x0E => {
                const n = try readU32Body(frame);
                var i: u32 = 0;
                while (i < n) : (i += 1) _ = try readU32Body(frame);
                _ = try readU32Body(frame);
            },
            0x11 => {
                _ = try readU32Body(frame);
                _ = try readU32Body(frame);
            },
            0x28...0x3E => {
                _ = try readU32Body(frame);
                _ = try readU32Body(frame);
            },
            0xFC => try skipFCImmediates(frame),
            else => {},
        }
    }
    return error.InvalidModule;
}

/// Skip past the immediates of a 0xfc-prefixed instruction when
/// fast-forwarding through unreachable code (br, if/else, etc).
/// Only the subops we actually decode in `stepFC` need a precise
/// arity here.
fn skipFCImmediates(frame: *Frame) !void {
    const sub = try readU32Body(frame);
    switch (sub) {
        0x00...0x07 => {}, // saturating truncations: no immediates
        0x08 => { // memory.init: data_idx (u32), mem_idx (byte)
            _ = try readU32Body(frame);
            _ = try readByteBody(frame);
        },
        0x09 => _ = try readU32Body(frame), // data.drop: data_idx
        0x0A => { // memory.copy: two memory indices
            _ = try readByteBody(frame);
            _ = try readByteBody(frame);
        },
        0x0B => _ = try readByteBody(frame), // memory.fill: mem_idx
        else => return error.UnsupportedOp,
    }
}

fn skipToEnd(frame: *Frame, labels: *std.ArrayListUnmanaged(Label)) !void {
    var depth: u32 = 0;
    while (frame.pc < frame.body.len) {
        const op = frame.body[frame.pc];
        frame.pc += 1;
        switch (op) {
            0x02, 0x03, 0x04 => {
                _ = try readBlockType(frame);
                depth += 1;
            },
            0x0B => {
                if (depth == 0) {
                    _ = labels.pop();
                    return;
                }
                depth -= 1;
            },
            0x0C, 0x0D, 0x10, 0x20, 0x21, 0x22, 0x23, 0x24, 0x3F, 0x40, 0x41 => _ = try readU32Body(frame),
            0x42 => _ = try readI64Body(frame),
            0x44 => frame.pc += 8,
            0x43 => frame.pc += 4,
            0x0E => {
                const n = try readU32Body(frame);
                var i: u32 = 0;
                while (i < n) : (i += 1) _ = try readU32Body(frame);
                _ = try readU32Body(frame);
            },
            0x11 => {
                _ = try readU32Body(frame);
                _ = try readU32Body(frame);
            },
            0x28...0x3E => {
                _ = try readU32Body(frame);
                _ = try readU32Body(frame);
            },
            0xFC => try skipFCImmediates(frame),
            else => {},
        }
    }
    return error.InvalidModule;
}

// ---------------------------------------------------------------------------
// Call / value-stack helpers
// ---------------------------------------------------------------------------

fn callFunction(
    inst: *Instance,
    vs: *std.ArrayListUnmanaged(u64),
    frames: *std.ArrayListUnmanaged(Frame),
    labels: *std.ArrayListUnmanaged(Label),
    func_idx: u32,
) !void {
    const ft = inst.funcType(func_idx) orelse return error.InvalidModule;
    const n_params = ft.params.len;
    if (vs.items.len < n_params) return error.StackUnderflow;
    const args_start = vs.items.len - n_params;
    // Take a copy — pushCall expects an owned slice we don't mutate.
    var arg_buf: [32]u64 = undefined;
    if (n_params > arg_buf.len) return error.UnsupportedOp;
    @memcpy(arg_buf[0..n_params], vs.items[args_start..]);
    vs.shrinkRetainingCapacity(args_start);
    try pushCall(inst, vs, frames, labels, func_idx, arg_buf[0..n_params]);
}

fn push(inst: *Instance, vs: *std.ArrayListUnmanaged(u64), v: u64) !void {
    if (vs.items.len >= MAX_STACK) return error.Trap;
    try vs.append(inst.allocator, v);
}

fn pop(vs: *std.ArrayListUnmanaged(u64)) !u64 {
    if (vs.items.len == 0) return error.StackUnderflow;
    return vs.pop() orelse return error.StackUnderflow;
}

// ---------------------------------------------------------------------------
// Memory ops
// ---------------------------------------------------------------------------

fn memLoad(
    inst: *Instance,
    vs: *std.ArrayListUnmanaged(u64),
    frame: *Frame,
    width: u32,
    target: enum { i32, i64 },
    signed: bool,
) !void {
    _ = try readU32Body(frame); // align
    const offset = try readU32Body(frame);
    const base: u32 = @truncate(try pop(vs));
    const addr = @as(u64, base) + @as(u64, offset);
    if (addr + width > inst.memory.len) return error.OutOfBounds;
    var raw: u64 = 0;
    var i: usize = 0;
    while (i < width) : (i += 1) raw |= @as(u64, inst.memory[addr + i]) << @as(u6, @intCast(i * 8));

    if (signed) {
        // Sign-extend from the `width` bytes worth of bits.
        const bit_width: u6 = @intCast(width * 8);
        const sign_bit_mask: u64 = @as(u64, 1) << (bit_width - 1);
        if ((raw & sign_bit_mask) != 0) {
            const high_mask: u64 = (~@as(u64, 0)) << bit_width;
            raw |= high_mask;
        }
        if (target == .i32) raw = @as(u64, @as(u32, @bitCast(@as(i32, @truncate(@as(i64, @bitCast(raw)))))));
    }
    try push(inst, vs, raw);
}

fn memStore(
    inst: *Instance,
    vs: *std.ArrayListUnmanaged(u64),
    frame: *Frame,
    width: u32,
) !void {
    _ = try readU32Body(frame); // align
    const offset = try readU32Body(frame);
    const val = try pop(vs);
    const base: u32 = @truncate(try pop(vs));
    const addr = @as(u64, base) + @as(u64, offset);
    if (addr + width > inst.memory.len) return error.OutOfBounds;
    var i: usize = 0;
    while (i < width) : (i += 1) inst.memory[addr + i] = @truncate(val >> @as(u6, @intCast(i * 8)));
}

// ---------------------------------------------------------------------------
// i32 / i64 ALU helpers
// ---------------------------------------------------------------------------

const CmpOp = enum { eq, ne, lt_s, lt_u, gt_s, gt_u, le_s, le_u, ge_s, ge_u };
const BinOp = enum {
    add,
    sub,
    mul,
    div_s,
    div_u,
    rem_s,
    rem_u,
    @"and",
    @"or",
    xor,
    shl,
    shr_s,
    shr_u,
    rotl,
    rotr,
};

fn i32Cmp(inst: *Instance, vs: *std.ArrayListUnmanaged(u64), op: CmpOp) !void {
    const b: u32 = @truncate(try pop(vs));
    const a: u32 = @truncate(try pop(vs));
    const ai: i32 = @bitCast(a);
    const bi: i32 = @bitCast(b);
    const r: u32 = switch (op) {
        .eq => @intFromBool(a == b),
        .ne => @intFromBool(a != b),
        .lt_s => @intFromBool(ai < bi),
        .lt_u => @intFromBool(a < b),
        .gt_s => @intFromBool(ai > bi),
        .gt_u => @intFromBool(a > b),
        .le_s => @intFromBool(ai <= bi),
        .le_u => @intFromBool(a <= b),
        .ge_s => @intFromBool(ai >= bi),
        .ge_u => @intFromBool(a >= b),
    };
    try push(inst, vs, @as(u64, r));
}

fn i64Cmp(inst: *Instance, vs: *std.ArrayListUnmanaged(u64), op: CmpOp) !void {
    const b = try pop(vs);
    const a = try pop(vs);
    const ai: i64 = @bitCast(a);
    const bi: i64 = @bitCast(b);
    const r: u32 = switch (op) {
        .eq => @intFromBool(a == b),
        .ne => @intFromBool(a != b),
        .lt_s => @intFromBool(ai < bi),
        .lt_u => @intFromBool(a < b),
        .gt_s => @intFromBool(ai > bi),
        .gt_u => @intFromBool(a > b),
        .le_s => @intFromBool(ai <= bi),
        .le_u => @intFromBool(a <= b),
        .ge_s => @intFromBool(ai >= bi),
        .ge_u => @intFromBool(a >= b),
    };
    try push(inst, vs, @as(u64, r));
}

fn i32Binop(inst: *Instance, vs: *std.ArrayListUnmanaged(u64), op: BinOp) !void {
    const b_raw: u32 = @truncate(try pop(vs));
    const a_raw: u32 = @truncate(try pop(vs));
    const a: i32 = @bitCast(a_raw);
    const b: i32 = @bitCast(b_raw);
    const r: u32 = switch (op) {
        .add => a_raw +% b_raw,
        .sub => a_raw -% b_raw,
        .mul => a_raw *% b_raw,
        .div_s => blk: {
            if (b == 0) return error.DivideByZero;
            if (a == std.math.minInt(i32) and b == -1) return error.IntegerOverflow;
            break :blk @bitCast(@divTrunc(a, b));
        },
        .div_u => blk: {
            if (b_raw == 0) return error.DivideByZero;
            break :blk a_raw / b_raw;
        },
        .rem_s => blk: {
            if (b == 0) return error.DivideByZero;
            if (a == std.math.minInt(i32) and b == -1) break :blk 0;
            break :blk @bitCast(@rem(a, b));
        },
        .rem_u => blk: {
            if (b_raw == 0) return error.DivideByZero;
            break :blk a_raw % b_raw;
        },
        .@"and" => a_raw & b_raw,
        .@"or" => a_raw | b_raw,
        .xor => a_raw ^ b_raw,
        .shl => a_raw << @as(u5, @intCast(b_raw & 0x1F)),
        .shr_s => @bitCast(a >> @as(u5, @intCast(b_raw & 0x1F))),
        .shr_u => a_raw >> @as(u5, @intCast(b_raw & 0x1F)),
        .rotl => std.math.rotl(u32, a_raw, b_raw & 0x1F),
        .rotr => std.math.rotr(u32, a_raw, b_raw & 0x1F),
    };
    try push(inst, vs, @as(u64, r));
}

fn i64Binop(inst: *Instance, vs: *std.ArrayListUnmanaged(u64), op: BinOp) !void {
    const b_raw = try pop(vs);
    const a_raw = try pop(vs);
    const a: i64 = @bitCast(a_raw);
    const b: i64 = @bitCast(b_raw);
    const r: u64 = switch (op) {
        .add => a_raw +% b_raw,
        .sub => a_raw -% b_raw,
        .mul => a_raw *% b_raw,
        .div_s => blk: {
            if (b == 0) return error.DivideByZero;
            if (a == std.math.minInt(i64) and b == -1) return error.IntegerOverflow;
            break :blk @bitCast(@divTrunc(a, b));
        },
        .div_u => blk: {
            if (b_raw == 0) return error.DivideByZero;
            break :blk a_raw / b_raw;
        },
        .rem_s => blk: {
            if (b == 0) return error.DivideByZero;
            if (a == std.math.minInt(i64) and b == -1) break :blk 0;
            break :blk @bitCast(@rem(a, b));
        },
        .rem_u => blk: {
            if (b_raw == 0) return error.DivideByZero;
            break :blk a_raw % b_raw;
        },
        .@"and" => a_raw & b_raw,
        .@"or" => a_raw | b_raw,
        .xor => a_raw ^ b_raw,
        .shl => a_raw << @as(u6, @intCast(b_raw & 0x3F)),
        .shr_s => @bitCast(a >> @as(u6, @intCast(b_raw & 0x3F))),
        .shr_u => a_raw >> @as(u6, @intCast(b_raw & 0x3F)),
        .rotl => std.math.rotl(u64, a_raw, b_raw & 0x3F),
        .rotr => std.math.rotr(u64, a_raw, b_raw & 0x3F),
    };
    try push(inst, vs, r);
}

fn i32Clz(inst: *Instance, vs: *std.ArrayListUnmanaged(u64)) !void {
    const v: u32 = @truncate(try pop(vs));
    try push(inst, vs, @as(u64, @clz(v)));
}
fn i32Ctz(inst: *Instance, vs: *std.ArrayListUnmanaged(u64)) !void {
    const v: u32 = @truncate(try pop(vs));
    try push(inst, vs, @as(u64, @ctz(v)));
}
fn i32Popcnt(inst: *Instance, vs: *std.ArrayListUnmanaged(u64)) !void {
    const v: u32 = @truncate(try pop(vs));
    try push(inst, vs, @as(u64, @popCount(v)));
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "decode: empty module header" {
    const a = std.testing.allocator;
    // Magic + version, no sections.
    const bytes = [_]u8{ 0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00 };
    var m = try decode(a, &bytes);
    defer m.deinit();
    try std.testing.expectEqual(@as(usize, 0), m.types.len);
}

test "decode: rejects bad magic" {
    const a = std.testing.allocator;
    const bytes = [_]u8{ 0xFF, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00 };
    try std.testing.expectError(error.InvalidModule, decode(a, &bytes));
}

test "LEB128 u32 round-trip via Cursor" {
    var c: Cursor = .{ .bytes = &[_]u8{ 0xE5, 0x8E, 0x26 } };
    try std.testing.expectEqual(@as(u32, 624485), try c.readU32());
}

test "LEB128 i32 signed round-trip" {
    var c: Cursor = .{ .bytes = &[_]u8{ 0xC0, 0xBB, 0x78 } };
    try std.testing.expectEqual(@as(i32, -123456), try c.readI32());
}

test "br depth>0 walks past multiple end bytes (regression)" {
    // Minimal hand-rolled wasm module that reproduces the pattern
    // we hit while running git-wasm's `handle_command`: an outer
    // block containing a loop with `br_if 1` to the outer block.
    // Before the fix, scanToEnd consumed only the loop's `end` byte
    // and the next `end` (the outer block's) was mistaken for the
    // function-implicit end — leaving stale state on the value
    // stack and tripping `popFrame`'s underflow check.
    //
    // The function returns i32: 42 if the br_if path executed
    // cleanly, anything else if not.
    const a = std.testing.allocator;
    const bytes = [_]u8{
        // ---- header ----
        0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00,
        // ---- type section: one type, () -> i32 ----
        0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7F,
        // ---- function section: 1 function, type 0 ----
        0x03,
        0x02, 0x01, 0x00,
        // ---- export section: one func "f" idx 0 ----
        0x07, 0x05, 0x01, 0x01, 0x66,
        0x00, 0x00,
        // ---- code section ----
        // section size = 1 (count) + 1 (body-size LEB) + body bytes (14)
        0x0A, 0x10,
        0x01, // 1 body
        0x0E, // body size = 14 bytes that follow:
        0x00, // 0 local decls
        // (block
        0x02,
        0x40,
        //   (loop
        0x03,
        0x40,
        //     i32.const 1
        0x41,
        0x01,
        //     br_if 1  -- target = outer block
        0x0D,
        0x01,
        //   end loop)  -- never reached after the branch
        0x0B,
        // end block)
        0x0B,
        // i32.const 42
        0x41,
        0x2A,
        // end function
        0x0B,
    };

    var module = try decode(a, &bytes);
    defer module.deinit();
    var instance = try instantiate(a, &module, &.{}, null);
    defer instance.deinit();

    var results: [1]u64 = undefined;
    const n = try invoke(&instance, 0, &.{}, &results);
    try std.testing.expectEqual(@as(u32, 1), n);
    try std.testing.expectEqual(@as(u64, 42), results[0]);
}
