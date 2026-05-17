; JSON syntax highlighting queries for tree-sitter

; Strings
(string) @string

; Numbers  
(number) @number

; Booleans and null
(true) @keyword
(false) @keyword
(null) @keyword

; Object keys
(pair
  key: (string) @property)

; Arrays and objects are structural, no special highlighting needed
