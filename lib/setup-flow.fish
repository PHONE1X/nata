# Интерактивный мастер: общий сценарий поверх ui_* (tui/cli).
# Требует: setup-core.fish и один из ui-*.fish.

function wd_flow_capture --argument-names title
    set -l out (eval (string escape -- $argv[2..-1] | string join ' ') 2>&1 | string collect)
    ui_info $title "$out"
end

function wd_flow_keys
    set -l pick (ui_menu "API-ключи" \
        openrouter "OpenRouter — облачное распознавание и перевод" \
        deepl "DeepL — перевод" \
        gemini "Google Gemini — перевод" \
        back "Назад")
    test -n "$pick"; and test "$pick" != back; or return 0
    set -l v (ui_secret "Ключ $pick")
    test -n "$v"; or return 0
    set -l where keyring
    wd_keyring_available; or set where env
    if printf '%s' $v | wd_key_store $pick $where >/dev/null 2>&1
        ui_info "Готово" "Ключ '$pick' сохранён ("(test $where = keyring; and echo libsecret; or echo "$WD_SECRETS_ENV")")."
    else
        ui_info "Ошибка" "Не удалось сохранить ключ '$pick'."
    end
end

function wd_flow_stt
    set -l pick (ui_menu "Распознавание речи" \
        local "Только локально (whisper.cpp)" \
        or_gpt4o "Облако: OpenRouter openai/gpt-4o-transcribe" \
        custom "Облако: другая модель OpenRouter…" \
        back "Назад")
    switch "$pick"
        case local; wd_conf_set STT local
        case or_gpt4o; wd_conf_set STT openrouter:openai/gpt-4o-transcribe
        case custom
            set -l m (ui_input "Модель OpenRouter (vendor/model)" openai/gpt-4o-transcribe)
            test -n "$m"; and wd_conf_set STT openrouter:$m
        case '*'; return 0
    end
    ui_info "Готово" "Режим распознавания записан в $WD_USER_CONF."
end

function wd_flow_translate
    set -l pick (ui_menu "Перевод (когда раскладка не русская)" \
        gemini "Google Gemini" \
        deepl "DeepL" \
        local "Локальный (нужен TRANSLATE_SCRIPT)" \
        back "Назад")
    test -n "$pick"; and test "$pick" != back; or return 0
    wd_conf_set TRANSLATE_PROVIDER $pick
    ui_info "Готово" "Провайдер перевода: $pick."
end

function wd_flow_models
    set -l pick (ui_menu "Модели whisper" \
        model "Файл основной модели (ggml-*.bin)" \
        vad "Файл VAD-модели (silero)" \
        back "Назад")
    switch "$pick"
        case model
            set -l path (ui_input "Полный путь к ggml-*.bin" (wd_conf MODEL ""))
            test -n "$path"; and wd_conf_set MODEL $path
        case vad
            set -l path (ui_input "Полный путь к VAD-модели" (wd_conf VAD_MODEL ""))
            test -n "$path"; and wd_conf_set VAD_MODEL $path
        case '*'; return 0
    end
end

function wd_flow_qs --argument-names target
    if python3 $WD_QS_PY $target status >/dev/null 2>&1
        ui_confirm "Модуль уже подключён. Удалить?"; or return 0
        ui_info "Quickshell" (python3 $WD_QS_PY $target remove 2>&1 | string collect)
    else
        ui_confirm "Подключить модуль диктовки?"; or return 0
        ui_info "Quickshell" (python3 $WD_QS_PY $target install 2>&1 | string collect)
    end
end

function wd_flow_bind
    if not wd_wm_hyprland
        ui_info "Горячая клавиша" "Автоматическая привязка есть только для Hyprland.\n\nЗадайте сочетание клавиш в настройках вашего окружения для команды:\n  whisper-dictate\nKDE: Параметры системы → Сочетания клавиш → Добавить команду.\nGNOME: Параметры → Клавиатура → Настраиваемые сочетания."
        return 0
    end
    set -l key (ui_input "Сочетание клавиш Hyprland" "SUPER + U")
    test -n "$key"; or return 0
    set -l out (wd_bind apply --key "$key" 2>&1 | string collect)
    set -l rc $status
    if test $rc -eq 2
        ui_info "Конфликт" "$out"
        if string match -q '*replace-legacy*' -- $out
            ui_confirm "Закомментировать старый бинд dictate.fish и записать новый?"; or return 0
            ui_info "Бинд" (wd_bind apply --key "$key" --replace-legacy 2>&1 | string collect)
        else if ui_confirm "Всё равно записать (--force)? Оба бинда будут срабатывать."
            ui_info "Бинд" (wd_bind apply --key "$key" --force 2>&1 | string collect)
        end
    else
        ui_info "Бинд" "$out"
    end
end

function wd_flow_doctor
    set -l out (wd_doctor 2>&1 | string collect)
    set -l rc $status
    ui_info "Кейринг" "$out"
    if test $rc -eq 3
        ui_confirm "Слить дубли в одну запись? (резервная копия будет создана)"; or return 0
        ui_info "Кейринг" (wd_doctor --fix --yes 2>&1 | string collect)
    end
end

function wd_flow_main
    while true
        set -l pick (ui_menu "Whisper Dictate — настройка" \
            test "Проверка установки" \
            keys "API-ключи" \
            stt "Распознавание речи (локально / облако)" \
            translate "Провайдер перевода" \
            models "Модели whisper (пути к файлам)" \
            bind "Горячая клавиша" \
            qs-ii "Интеграция с Logical Impulse (ii)" \
            qs-standalone "Виджет Quickshell (отдельный)" \
            doctor "Диагностика кейринга (дубли)" \
            quit "Выход")
        switch "$pick"
            case test; wd_flow_capture "Проверка" wd_selftest
            case keys; wd_flow_keys
            case stt; wd_flow_stt
            case translate; wd_flow_translate
            case models; wd_flow_models
            case bind; wd_flow_bind
            case qs-ii; wd_flow_qs ii
            case qs-standalone; wd_flow_qs standalone
            case doctor; wd_flow_doctor
            case '*'; return 0
        end
    end
end
