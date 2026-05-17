# fish completion for stem.
#
# Install: copy this file into ~/.config/fish/completions/

# Subcommands (only valid as the first non-flag arg).
function __stem_no_subcmd
    set -l cmd (commandline -opc)
    set -l skip 1 # skip argv[0]
    for w in $cmd[2..-1]
        switch $w
            case 'find' 'vfind' 'scope' 'config' 'logs' 'log' 'lsp' 'help' 'version'
                return 1
            case '*'
                # any non-flag positional means we're past the subcommand slot
                if not string match -q -- '-*' $w
                    return 1
                end
        end
    end
    return 0
end

complete -c stem -n '__stem_no_subcmd' -a 'find'    -d 'Search file contents'
complete -c stem -n '__stem_no_subcmd' -a 'vfind'   -d 'Interactive search'
complete -c stem -n '__stem_no_subcmd' -a 'scope'   -d 'Search in one file'
complete -c stem -n '__stem_no_subcmd' -a 'config'  -d 'Manage config'
complete -c stem -n '__stem_no_subcmd' -a 'logs'    -d 'View / clear logs'
complete -c stem -n '__stem_no_subcmd' -a 'lsp'     -d 'Manage language servers'
complete -c stem -n '__stem_no_subcmd' -a 'help'    -d 'Show help'
complete -c stem -n '__stem_no_subcmd' -a 'version' -d 'Print version'

complete -c stem -s h -l help    -d 'Show help'
complete -c stem -s V -l version -d 'Print version'

# Search flags (find / vfind)
function __stem_using_search
    set -l cmd (commandline -opc)
    contains -- find $cmd; or contains -- vfind $cmd
    or contains -- --find $cmd; or contains -- --vfind $cmd; or contains -- -f $cmd
end
complete -c stem -n '__stem_using_search' -s p -l path    -d 'Restrict to path' -r
complete -c stem -n '__stem_using_search' -s e -l ext     -d 'Filter by extension' -xa 'zig py js ts tsx jsx go rs c cpp h hpp md json yaml yml'
complete -c stem -n '__stem_using_search' -s x -l exclude -d 'Exclude pattern'

# scope flags
function __stem_using_scope
    set -l cmd (commandline -opc)
    contains -- scope $cmd; or contains -- --scope $cmd
end
complete -c stem -n '__stem_using_scope' -s B -l before -d 'Lines of context before'
complete -c stem -n '__stem_using_scope' -s A -l after  -d 'Lines of context after'

# config sub-actions
function __stem_after_config
    set -l cmd (commandline -opc)
    contains -- config $cmd
end
complete -c stem -n '__stem_after_config' -a 'list get set unset'

# logs sub-actions
function __stem_after_logs
    set -l cmd (commandline -opc)
    contains -- logs $cmd; or contains -- log $cmd
end
complete -c stem -n '__stem_after_logs' -a 'view clear'

# lsp sub-actions and languages
function __stem_after_lsp
    set -l cmd (commandline -opc)
    contains -- lsp $cmd
end
complete -c stem -n '__stem_after_lsp' -a 'install list status'

function __stem_after_lsp_install
    set -l cmd (commandline -opc)
    contains -- lsp $cmd; and contains -- install $cmd
end
complete -c stem -n '__stem_after_lsp_install' -a 'python typescript javascript go rust cpp ruby csharp java all'
