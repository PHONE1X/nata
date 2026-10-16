# Графический интерфейс: zenity (GTK) или kdialog (Qt).

if command -q zenity
    set -g WD_GUI zenity
else if command -q kdialog
    set -g WD_GUI kdialog
else
    echo "Нужен zenity или kdialog для графического режима (или используйте --tui/--cli)" >&2
    exit 1
end

function ui_info --argument-names title text
    switch $WD_GUI
        case zenity
            printf '%s\n' $text | zenity --text-info --title="$title" --width=760 --height=480 --font="monospace 10"
        case kdialog
            set -l f (mktemp)
            printf '%s\n' $text >$f
            kdialog --title "$title" --textbox $f 760 480
            rm -f $f
    end
    return 0
end

function ui_confirm --argument-names text
    switch $WD_GUI
        case zenity; zenity --question --text="$text" --width=420
        case kdialog; kdialog --yesno "$text"
    end
end

function ui_input --argument-names label default
    switch $WD_GUI
        case zenity; zenity --entry --text="$label" --entry-text="$default" --width=420
        case kdialog; kdialog --inputbox "$label" "$default"
    end
end

function ui_secret --argument-names label
    switch $WD_GUI
        case zenity; zenity --password --title="$label"
        case kdialog; kdialog --password "$label"
    end
end

function ui_menu --argument-names title
    set -l items $argv[2..-1]
    switch $WD_GUI
        case zenity
            zenity --list --title="$title" --text="$title" --column=id --column=Действие \
                --hide-column=1 --print-column=1 --width=520 --height=420 $items
        case kdialog
            kdialog --title "$title" --menu "$title" $items
    end
end
