; JavaScript syntax highlighting queries for tree-sitter
; Simplified version that only uses node types that exist in the grammar

; Comments
(comment) @comment

; Strings
(string) @string
(template_string) @string

; Numbers
(number) @number

; Regex
(regex) @string

; Function declarations
(function_declaration
  name: (identifier) @function)

; Function expressions
(function_expression
  name: (identifier) @function)

; Arrow functions (named via assignment)
(variable_declarator
  name: (identifier) @function
  value: (arrow_function))

; Method definitions
(method_definition
  name: (property_identifier) @function)

; Function calls
(call_expression
  function: (identifier) @function)

; Method calls - property is the function being called
(call_expression
  function: (member_expression
    property: (property_identifier) @function))

; Class definitions
(class_declaration
  name: (identifier) @type_name)

; Property access
(member_expression
  property: (property_identifier) @property)

; Object property keys
(pair
  key: (property_identifier) @property)
(shorthand_property_identifier) @property

; Parameters
(formal_parameters
  (identifier) @parameter)

; Variables (catch-all, must come last)
(identifier) @variable
