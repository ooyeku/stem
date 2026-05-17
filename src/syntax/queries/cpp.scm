; Minimal tree-sitter highlight query for C++. One pattern per line so the
; truncate-on-error fallback in SyntaxManager can drop only the offending
; keyword rather than the entire bracketed list.

(comment) @comment

(string_literal) @string
(system_lib_string) @string
(char_literal) @string
(raw_string_literal) @string

(number_literal) @number

"#include" @keyword
"#define" @keyword
"#if" @keyword
"#ifdef" @keyword
"#ifndef" @keyword
"#else" @keyword
"#elif" @keyword
"#endif" @keyword

"break" @keyword
"case" @keyword
"catch" @keyword
"class" @keyword
"const" @keyword
"constexpr" @keyword
"continue" @keyword
"default" @keyword
"delete" @keyword
"do" @keyword
"else" @keyword
"enum" @keyword
"explicit" @keyword
"export" @keyword
"extern" @keyword
"for" @keyword
"friend" @keyword
"if" @keyword
"inline" @keyword
"namespace" @keyword
"new" @keyword
"noexcept" @keyword
"operator" @keyword
"private" @keyword
"protected" @keyword
"public" @keyword
"return" @keyword
"sizeof" @keyword
"static" @keyword
"struct" @keyword
"switch" @keyword
"template" @keyword
"throw" @keyword
"try" @keyword
"typedef" @keyword
"typename" @keyword
"union" @keyword
"using" @keyword
"virtual" @keyword
"volatile" @keyword
"while" @keyword

(primitive_type) @builtin
(type_identifier) @type_name
(namespace_identifier) @type_name
(sized_type_specifier) @type_name

(field_identifier) @property

(function_declarator
  declarator: (identifier) @function)
(call_expression
  function: (identifier) @function)

(identifier) @variable
