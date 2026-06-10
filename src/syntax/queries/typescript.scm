; TypeScript/TSX syntax highlighting queries for tree-sitter
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

; Method calls
(call_expression
  function: (member_expression
    property: (property_identifier) @function))

; Class definitions
(class_declaration
  name: (type_identifier) @type_name)

; Interface definitions
(interface_declaration
  name: (type_identifier) @type_name)

; Type alias definitions
(type_alias_declaration
  name: (type_identifier) @type_name)

; Type annotations
(type_identifier) @type_name
(predefined_type) @type_name

; Property access
(member_expression
  property: (property_identifier) @property)

; Object property keys
(pair
  key: (property_identifier) @property)
(shorthand_property_identifier) @property

; Property signatures in interfaces/types
(property_signature
  name: (property_identifier) @property)

; Parameters
(required_parameter
  pattern: (identifier) @parameter)
(optional_parameter
  pattern: (identifier) @parameter)

; Variables
(identifier) @variable

; Decorators
(decorator
  (identifier) @builtin)
