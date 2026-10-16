# Интерфейс «просто терминал»: ввод через read, без зависимостей.

function ui_info --argument-names title text
    echo
    echo "== $title =="
    printf '%s\n' $text
end

function ui_confirm --argument-names text
    read -l -P "$text [y/N] " ans
    contains -- (string lower -- $ans) y yes д да
end

function ui_input --argument-names label default
    if test -n "$default"
        read -l -P "$label [$default]: " v
        test -n "$v"; or set v $default
    else
        read -l -P "$label: " v
    end
    printf '%s\n' $v
end

# Значение не эхо-ится и не попадает в argv.
function ui_secret --argument-names label
    read -l -s -P "$label (ввод скрыт): " v
    echo >&2
    printf '%s' $v
end

# ui_menu TITLE tag label [tag label ...] -> печатает tag; код 1 — отмена
function __ui_cli_menu --argument-names title
    set -l items $argv[2..-1]
    echo >&2
    echo "== $title ==" >&2
    for i in (seq 1 2 (count $items))
        printf ' %d) %s\n' (math "($i + 1) / 2") $items[(math $i + 1)] >&2
    end
    read -l -P "Выбор (Enter — выход): " n
    string match -qr '^[0-9]+$' -- $n; or return 1
    set -l idx (math "$n * 2 - 1")
    test $idx -ge 1; and test $idx -le (count $items); or return 1
    printf '%s\n' $items[$idx]
end

function ui_menu
    __ui_cli_menu $argv
end
