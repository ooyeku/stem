# stem hero demo: open a real source file, edit, palette, splits.
Output assets/demo.gif
Set FontSize 15
Set Width 1200
Set Height 720
Set Padding 12
Set TypingSpeed 60ms

Hide
Type "export TERM=xterm-256color; clear"
Enter
Sleep 500ms
Show

Type "stem src/kernel/message_bus.zig"
Sleep 500ms
Enter
Sleep 2.5s

# Navigate: down through the file, word motions
Type "jjjjj"
Sleep 800ms
Type "wwww"
Sleep 800ms
Type "}"
Sleep 600ms
Type "}"
Sleep 800ms

# Insert mode: type a comment, then undo it
Type "O"
Sleep 400ms
Type "// stem: every message below runs through a supervised runtime"
Sleep 1.2s
Escape
Sleep 600ms
Space
Type "u"
Sleep 800ms

# Split pane and focus it
Space
Type "|"
Sleep 1s
Space
Right
Sleep 800ms

# Command palette
Space
Type "f"
Sleep 900ms
Type "control"
Sleep 1.2s
Escape
Sleep 500ms

# Quit
Space
Type "q"
Sleep 1s
