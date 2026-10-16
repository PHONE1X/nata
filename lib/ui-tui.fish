# Терминальный интерфейс: меню через fzf (если есть), остальное как в ui-cli.
source (dirname (status filename))/ui-cli.fish

function ui_menu --argument-names title
    set -l items $argv[2..-1]
    if not command -q fzf
        __ui_cli_menu $argv
        return
    end
    set -l lines
    for i in (seq 1 2 (count $items))
        set -a lines "$items[$i]\t$items[(math $i + 1)]"
    end
    set -l pick (printf '%b\n' $lines | fzf --height=60% --reverse --delimiter='\t' --with-nth=2 \
        --header="$title  (Enter — выбрать, Esc — назад)" --prompt='> ' | string split -f1 \t)
    test -n "$pick"; or return 1
    printf '%s\n' $pick
end
