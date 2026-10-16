hl.bind("CTRL+SUPER+ALT+Slash", hl.dsp.exec_cmd("xdg-open ~/.config/hypr/custom/keybinds.lua"), {description = "Изменить свои сочетания клавиш"} )

hl.unbind("SUPER + A")
hl.unbind("SUPER + N")

-- void acses
hl.bind("SUPER + U", hl.dsp.exec_cmd("~/.local/bin/dictate.fish"), { description = "Утилиты: Голосовой ввод" })

hl.bind("SUPER + A", hl.dsp.global("quickshell:searchToggle"), { description = "Оболочка: Поиск" })
hl.bind("SUPER + E", hl.dsp.exec_cmd("kitty -e fish -ic 'y'"), { description = "Программы: Терминал" })
hl.bind("SUPER + SHIFT + mouse_up", hl.dsp.window.move({ workspace = "-1" }))
