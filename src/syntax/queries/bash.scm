; Bash/Shell syntax highlighting queries for tree-sitter
; Based on official tree-sitter-bash highlights.scm

; Strings
[
  (string)
  (raw_string)
  (heredoc_body)
  (heredoc_start)
] @string

; Commands
(command_name) @function

; Variables
(variable_name) @variable

; Keywords
[
  "case"
  "do"
  "done"
  "elif"
  "else"
  "esac"
  "export"
  "fi"
  "for"
  "function"
  "if"
  "in"
  "select"
  "then"
  "unset"
  "until"
  "while"
] @keyword

; Comments
(comment) @comment

; Function definitions
(function_definition 
  name: (word) @function)

; File descriptors as numbers
(file_descriptor) @number

; Operators
[
  "$"
  "&&"
  ">"
  ">>"
  "<"
  "|"
] @operator
