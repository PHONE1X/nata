# Адаптер окна и раскладки. Hyprland — полный (отслеживание окна-получателя,
# фокус, раскладка). Остальные Wayland-окружения: окно не отслеживается,
# текст вставляется в то окно, которое активно в момент вставки.

function wd_wm_hyprland
    test -n "$HYPRLAND_INSTANCE_SIGNATURE"; and command -q hyprctl
end

# "address\ttitle\tclass" активного окна или пусто
function wd_wm_active_window
    wd_wm_hyprland; or return 0
    hyprctl activewindow -j 2>/dev/null | jq -r '[(.address // ""), (.title // ""), (.class // "")] | @tsv' 2>/dev/null
end

function wd_wm_active_address
    wd_wm_hyprland; or return 0
    hyprctl activewindow -j 2>/dev/null | jq -r '.address // empty' 2>/dev/null
end

function wd_wm_keymap
    wd_wm_hyprland; or return 0
    hyprctl devices -j 2>/dev/null \
        | jq -r '([.keyboards[] | select(.main == true) | .active_keymap] | first) // .keyboards[0].active_keymap // empty' 2>/dev/null
end

# "address\tkeymap" одним запросом (для опроса раскладки)
function wd_wm_snapshot
    wd_wm_hyprland; or return 0
    hyprctl --batch "j/activewindow;j/devices" 2>/dev/null \
        | jq -s -r '[(.[0].address // ""), (([.[1].keyboards[] | select(.main == true) | .active_keymap] | first) // .[1].keyboards[0].active_keymap // "")] | @tsv' 2>/dev/null
end

# JSON-массив адресов открытых окон; без WM — пусто
function wd_wm_live_addresses
    wd_wm_hyprland; or return 0
    hyprctl clients -j 2>/dev/null | jq -c '[.[].address]' 2>/dev/null
end

# Без WM проверить нельзя, поэтому считаем окно живым
function wd_wm_window_exists --argument-names addr
    wd_wm_hyprland; or return 0
    set -l n (hyprctl clients -j 2>/dev/null | jq -r --arg a "$addr" '[.[] | select(.address == $a)] | length' 2>/dev/null)
    test "$n" != "0"; and test -n "$n"
end

function wd_wm_focus --argument-names addr
    wd_wm_hyprland; or return 1
    # Lua-форк Hyprland (hl.dsp.*, см. ~/.config/hypr/hyprland/keybinds.lua):
    # классический `dispatch focuswindow address:...` не парсится.
    hyprctl dispatch "hl.dsp.focus({ window = \"address:$addr\" })" 2>&1
end

function wd_wm_send_ctrl_v
    wd_wm_hyprland; or return 1
    hyprctl dispatch 'hl.dsp.send_shortcut({ mods = "CTRL", key = "V" })' 2>&1
end
