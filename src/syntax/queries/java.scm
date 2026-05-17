; Minimal tree-sitter highlight query for Java. One pattern per line so
; the truncate-on-error fallback drops only the offending keyword.

(line_comment) @comment
(block_comment) @comment

(string_literal) @string
(character_literal) @string

(decimal_integer_literal) @number
(hex_integer_literal) @number
(octal_integer_literal) @number
(binary_integer_literal) @number
(decimal_floating_point_literal) @number
(hex_floating_point_literal) @number

"abstract" @keyword
"assert" @keyword
"break" @keyword
"case" @keyword
"catch" @keyword
"class" @keyword
"continue" @keyword
"default" @keyword
"do" @keyword
"else" @keyword
"enum" @keyword
"extends" @keyword
"final" @keyword
"finally" @keyword
"for" @keyword
"if" @keyword
"implements" @keyword
"import" @keyword
"instanceof" @keyword
"interface" @keyword
"native" @keyword
"new" @keyword
"package" @keyword
"private" @keyword
"protected" @keyword
"public" @keyword
"return" @keyword
"static" @keyword
"switch" @keyword
"synchronized" @keyword
"throw" @keyword
"throws" @keyword
"transient" @keyword
"try" @keyword
"volatile" @keyword
"while" @keyword
"yield" @keyword

(type_identifier) @type_name
(scoped_type_identifier) @type_name

(method_declaration name: (identifier) @function)
(method_invocation name: (identifier) @function)
(constructor_declaration name: (identifier) @function)

(field_access field: (identifier) @property)

(annotation name: (identifier) @attribute)
(marker_annotation name: (identifier) @attribute)

(identifier) @variable
