; Minimal tree-sitter highlight query for C#. One pattern per line so the
; truncate-on-error fallback drops only the offending keyword.

(comment) @comment

(string_literal) @string
(verbatim_string_literal) @string
(character_literal) @string

(integer_literal) @number
(real_literal) @number

"abstract" @keyword
"as" @keyword
"async" @keyword
"await" @keyword
"base" @keyword
"break" @keyword
"case" @keyword
"catch" @keyword
"class" @keyword
"const" @keyword
"continue" @keyword
"default" @keyword
"delegate" @keyword
"do" @keyword
"else" @keyword
"enum" @keyword
"event" @keyword
"explicit" @keyword
"extern" @keyword
"finally" @keyword
"fixed" @keyword
"for" @keyword
"foreach" @keyword
"goto" @keyword
"if" @keyword
"implicit" @keyword
"in" @keyword
"interface" @keyword
"internal" @keyword
"is" @keyword
"lock" @keyword
"namespace" @keyword
"new" @keyword
"operator" @keyword
"out" @keyword
"override" @keyword
"params" @keyword
"private" @keyword
"protected" @keyword
"public" @keyword
"readonly" @keyword
"ref" @keyword
"return" @keyword
"sealed" @keyword
"sizeof" @keyword
"stackalloc" @keyword
"static" @keyword
"struct" @keyword
"switch" @keyword
"this" @keyword
"throw" @keyword
"try" @keyword
"typeof" @keyword
"unchecked" @keyword
"unsafe" @keyword
"using" @keyword
"virtual" @keyword
"volatile" @keyword
"while" @keyword
"yield" @keyword

(predefined_type) @builtin

(class_declaration name: (identifier) @type_name)
(interface_declaration name: (identifier) @type_name)
(enum_declaration name: (identifier) @type_name)
(struct_declaration (identifier) @type_name)
(record_declaration (identifier) @type_name)

(method_declaration name: (identifier) @function)
(local_function_statement name: (identifier) @function)
(invocation_expression function: (identifier) @function)

(attribute name: (identifier) @attribute)

(identifier) @variable
