; Minimal tree-sitter highlight query for Ruby. One pattern per line so
; the truncate-on-error fallback drops only the offending keyword/node.

(comment) @comment

(string) @string
(string_content) @string
(simple_symbol) @string

(integer) @number
(float) @number

"alias" @keyword
"and" @keyword
"begin" @keyword
"break" @keyword
"case" @keyword
"class" @keyword
"def" @keyword
"do" @keyword
"else" @keyword
"elsif" @keyword
"end" @keyword
"ensure" @keyword
"for" @keyword
"if" @keyword
"in" @keyword
"module" @keyword
"next" @keyword
"not" @keyword
"or" @keyword
"redo" @keyword
"rescue" @keyword
"retry" @keyword
"return" @keyword
"then" @keyword
"unless" @keyword
"until" @keyword
"when" @keyword
"while" @keyword
"yield" @keyword


(constant) @type_name

(method name: (identifier) @function)
(call method: (identifier) @function)

(instance_variable) @property
(class_variable) @property
(global_variable) @property

(identifier) @variable
