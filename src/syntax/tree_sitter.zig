const std = @import("std");

pub const c = @cImport({
    @cInclude("tree_sitter/api.h");
});

extern fn tree_sitter_zig() ?*const c.TSLanguage;
extern fn tree_sitter_python() ?*const c.TSLanguage;
extern fn tree_sitter_javascript() ?*const c.TSLanguage;
extern fn tree_sitter_typescript() ?*const c.TSLanguage;
extern fn tree_sitter_tsx() ?*const c.TSLanguage;
extern fn tree_sitter_json() ?*const c.TSLanguage;
extern fn tree_sitter_bash() ?*const c.TSLanguage;
extern fn tree_sitter_go() ?*const c.TSLanguage;

extern fn tree_sitter_html() ?*const c.TSLanguage;
extern fn tree_sitter_css() ?*const c.TSLanguage;
extern fn tree_sitter_rust() ?*const c.TSLanguage;
extern fn tree_sitter_c() ?*const c.TSLanguage;
extern fn tree_sitter_cpp() ?*const c.TSLanguage;
extern fn tree_sitter_java() ?*const c.TSLanguage;
extern fn tree_sitter_ruby() ?*const c.TSLanguage;
extern fn tree_sitter_c_sharp() ?*const c.TSLanguage;

extern fn tree_sitter_php() ?*const c.TSLanguage;
extern fn tree_sitter_swift() ?*const c.TSLanguage;
extern fn tree_sitter_kotlin() ?*const c.TSLanguage;
extern fn tree_sitter_lua() ?*const c.TSLanguage;
extern fn tree_sitter_dart() ?*const c.TSLanguage;
extern fn tree_sitter_elixir() ?*const c.TSLanguage;
extern fn tree_sitter_haskell() ?*const c.TSLanguage;
extern fn tree_sitter_ocaml() ?*const c.TSLanguage;
extern fn tree_sitter_scala() ?*const c.TSLanguage;
extern fn tree_sitter_r() ?*const c.TSLanguage;
extern fn tree_sitter_perl() ?*const c.TSLanguage;
extern fn tree_sitter_erlang() ?*const c.TSLanguage;

pub const zig_language = tree_sitter_zig;
pub const python_language = tree_sitter_python;
pub const javascript_language = tree_sitter_javascript;
pub const typescript_language = tree_sitter_typescript;
pub const tsx_language = tree_sitter_tsx;
pub const json_language = tree_sitter_json;
pub const bash_language = tree_sitter_bash;
pub const go_language = tree_sitter_go;
pub const html_language = tree_sitter_html;
pub const css_language = tree_sitter_css;
pub const rust_language = tree_sitter_rust;
pub const c_language = tree_sitter_c;
pub const cpp_language = tree_sitter_cpp;
pub const java_language = tree_sitter_java;
pub const ruby_language = tree_sitter_ruby;
pub const csharp_language = tree_sitter_c_sharp;

pub const php_language = tree_sitter_php;
pub const swift_language = tree_sitter_swift;
pub const kotlin_language = tree_sitter_kotlin;
pub const lua_language = tree_sitter_lua;
pub const dart_language = tree_sitter_dart;
pub const elixir_language = tree_sitter_elixir;
pub const haskell_language = tree_sitter_haskell;
pub const ocaml_language = tree_sitter_ocaml;
pub const scala_language = tree_sitter_scala;
pub const r_language = tree_sitter_r;
pub const perl_language = tree_sitter_perl;
pub const erlang_language = tree_sitter_erlang;

test "tree-sitter basic" {
    const parser = c.ts_parser_new();
    defer c.ts_parser_delete(parser);

    const lang = tree_sitter_zig();
    const success = c.ts_parser_set_language(parser, lang);
    try std.testing.expect(success);

    const source_code = "const x = 1;";
    const tree = c.ts_parser_parse_string(
        parser,
        null,
        source_code,
        source_code.len,
    );
    defer c.ts_tree_delete(tree);

    const root_node = c.ts_tree_root_node(tree);
    const node_type = c.ts_node_type(root_node);

    try std.testing.expect(std.mem.eql(u8, std.mem.span(node_type), "source_file"));
}

test "javascript language and query loading" {
    const lang = tree_sitter_javascript() orelse return error.LanguageNotFound;

    const parser = c.ts_parser_new();
    defer c.ts_parser_delete(parser);
    const success = c.ts_parser_set_language(parser, lang);
    try std.testing.expect(success);

    const simple_query = "(comment) @comment\n(string) @string\n(number) @number\n(identifier) @variable";

    var error_offset: u32 = 0;
    var error_type: c.TSQueryError = undefined;

    const query = c.ts_query_new(
        lang,
        simple_query.ptr,
        @intCast(simple_query.len),
        &error_offset,
        &error_type,
    );

    if (query == null) return error.QueryParseFailed;
    defer c.ts_query_delete(query);

    const js_code = "// comment\nconst x = 42;";
    const tree = c.ts_parser_parse_string(parser, null, js_code.ptr, @intCast(js_code.len));
    defer c.ts_tree_delete(tree);

    const cursor = c.ts_query_cursor_new();
    defer c.ts_query_cursor_delete(cursor);

    const root = c.ts_tree_root_node(tree);
    c.ts_query_cursor_exec(cursor, query, root);

    var match: c.TSQueryMatch = undefined;
    var count: usize = 0;
    while (c.ts_query_cursor_next_match(cursor, &match)) {
        count += 1;
    }

    try std.testing.expect(count > 0);
}

test "javascript embedded query loading" {
    const lang = tree_sitter_javascript() orelse return error.LanguageNotFound;

    const query_source = @embedFile("queries/javascript.scm");

    var error_offset: u32 = 0;
    var error_type: c.TSQueryError = undefined;

    const query = c.ts_query_new(
        lang,
        query_source.ptr,
        @intCast(query_source.len),
        &error_offset,
        &error_type,
    );

    if (query == null) return error.QueryParseFailed;
    defer c.ts_query_delete(query);

    try std.testing.expect(c.ts_query_pattern_count(query) > 0);
}

test "python language loading" {
    const lang = tree_sitter_python() orelse return error.LanguageNotFound;

    const parser = c.ts_parser_new();
    defer c.ts_parser_delete(parser);
    const success = c.ts_parser_set_language(parser, lang);
    try std.testing.expect(success);
}

test "python embedded query loading" {
    const lang = tree_sitter_python() orelse return error.LanguageNotFound;

    const query_source = @embedFile("queries/python.scm");

    var error_offset: u32 = 0;
    var error_type: c.TSQueryError = undefined;

    const query = c.ts_query_new(
        lang,
        query_source.ptr,
        @intCast(query_source.len),
        &error_offset,
        &error_type,
    );

    if (query == null) return error.QueryParseFailed;
    defer c.ts_query_delete(query);

    try std.testing.expect(c.ts_query_pattern_count(query) > 0);
}

test "typescript language loading" {
    const lang = tree_sitter_typescript() orelse return error.LanguageNotFound;

    const parser = c.ts_parser_new();
    defer c.ts_parser_delete(parser);
    const success = c.ts_parser_set_language(parser, lang);
    try std.testing.expect(success);
}

test "go language loading" {
    const lang = tree_sitter_go() orelse return error.LanguageNotFound;

    const parser = c.ts_parser_new();
    defer c.ts_parser_delete(parser);
    const success = c.ts_parser_set_language(parser, lang);
    try std.testing.expect(success);

    const query_source = @embedFile("queries/go.scm");

    var error_offset: u32 = 0;
    var error_type: c.TSQueryError = undefined;

    const query = c.ts_query_new(
        lang,
        query_source.ptr,
        @intCast(query_source.len),
        &error_offset,
        &error_type,
    );

    if (query == null) return error.QueryParseFailed;
    defer c.ts_query_delete(query);
}
