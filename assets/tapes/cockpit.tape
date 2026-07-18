# stem control center: the live runtime cockpit.
Output assets/cockpit.gif
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

Type "stem src/services/runtime.zig"
Sleep 500ms
Enter
Sleep 2.5s

# Open the control center from the palette
Space
Type "f"
Sleep 900ms
Type "control center"
Sleep 1s
Enter
Sleep 2.5s

# Scroll through the cockpit
Type "jjjjjjjjjj"
Sleep 1.2s
Type "jjjjjjjjjj"
Sleep 1.5s
Type "gg"
Sleep 1.2s

# Quit
Space
Type "q"
Sleep 1s
