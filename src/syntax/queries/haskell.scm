; Minimal tree-sitter highlight query for Haskell.

(comment) @comment

(string) @string
(char) @string

(integer) @number
(float) @number

"case" @keyword
"class" @keyword
"data" @keyword
"default" @keyword
"deriving" @keyword
"do" @keyword
"else" @keyword
"family" @keyword
"forall" @keyword
"foreign" @keyword
"hiding" @keyword
"if" @keyword
"import" @keyword
"in" @keyword
"infix" @keyword
"infixl" @keyword
"infixr" @keyword
"instance" @keyword
"let" @keyword
"module" @keyword
"newtype" @keyword
"of" @keyword
"qualified" @keyword
"then" @keyword
"type" @keyword
"where" @keyword

(variable) @variable
(constructor) @type_name
