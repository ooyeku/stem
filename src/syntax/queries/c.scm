; Minimal tree-sitter highlight query for C. Maps the most common nodes
; onto yap's small capture vocabulary (see SyntaxManager.mapCaptureToType).
; Based on tree-sitter-c's upstream highlights.scm.

(comment) @comment

(string_literal) @string
(system_lib_string) @string
(char_literal) @string

(number_literal) @number

"#include" @keyword
"#define" @keyword
"#if" @keyword
"#ifdef" @keyword
"#ifndef" @keyword
"#else" @keyword
"#elif" @keyword
"#endif" @keyword
(preproc_directive) @keyword

"break" @keyword
"case" @keyword
"const" @keyword
"continue" @keyword
"default" @keyword
"do" @keyword
"else" @keyword
"enum" @keyword
"extern" @keyword
"for" @keyword
"if" @keyword
"inline" @keyword
"return" @keyword
"sizeof" @keyword
"static" @keyword
"struct" @keyword
"switch" @keyword
"typedef" @keyword
"union" @keyword
"volatile" @keyword
"while" @keyword

(primitive_type) @builtin
(sized_type_specifier) @type_name
(type_identifier) @type_name

(field_identifier) @property

(call_expression
  function: (identifier) @function)
(function_declarator
  declarator: (identifier) @function)

(identifier) @variable
