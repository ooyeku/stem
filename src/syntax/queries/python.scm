; Python syntax highlighting - testing class and decorator patterns

; Comments
(comment) @comment

; Strings
(string) @string

; Numbers
(integer) @number
(float) @number

; Function definitions
(function_definition
  name: (identifier) @function)

; Class definitions
(class_definition
  name: (identifier) @type_name)

; Decorators - may cause issues
(decorator
  (identifier) @builtin)

; Identifiers
(identifier) @variable
