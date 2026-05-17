# Shell completions for `stem`

## bash

```bash
# Add to ~/.bashrc:
source /path/to/stem/scripts/completions/bash/stem
```

Or copy the file to `~/.local/share/bash-completion/completions/stem`.

## zsh

```zsh
# Add to ~/.zshrc, before `compinit`:
fpath=(/path/to/stem/scripts/completions/zsh $fpath)
autoload -Uz compinit && compinit
```

Or symlink `_stem` into any directory already on `$fpath` (e.g.
`/usr/local/share/zsh/site-functions`).

## fish

```fish
cp scripts/completions/fish/stem.fish ~/.config/fish/completions/
```

Reload the shell or run `source` on the file.
