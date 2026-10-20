# Интерактивный мастер: общий сценарий поверх ui_* (gui/tui/cli).
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
        or_gpt4o "Облако: OpenRouter openai/gpt-4o-transcribe (по умолчанию)" \
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
        large-v3-turbo "large-v3-turbo (≈1.6 ГБ, по умолчанию)" \
        medium "medium (≈1.5 ГБ)" \
        small "small (≈470 МБ)" \
        base "base (≈140 МБ)" \
        vad "Silero VAD (≈1 МБ, нужен всегда)" \
        legacy "Подцепить модели из ~/WORKSPACE/ai/whisper.cpp/models" \
        back "Назад")
    test -n "$pick"; and test "$pick" != back; or return 0
    if test "$pick" = legacy
        wd_flow_capture "Модели" wd_model_link_legacy
        return 0
    end
    ui_confirm "Скачать $pick в "(wd_model_dir)"?"; or return 0
    wd_flow_capture "Загрузка $pick" wd_model_download $pick
    if test "$pick" != vad; and test "$pick" != legacy
        ui_confirm "Сделать $pick моделью по умолчанию?"; and wd_conf_set MODEL (wd_model_file $pick)
    end
end

function wd_flow_bind
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
            models "Модели whisper" \
            bind "Горячая клавиша Hyprland" \
            doctor "Диагностика кейринга (дубли)" \
            quit "Выход")
        switch "$pick"
            case test; wd_flow_capture "Проверка" wd_selftest
            case keys; wd_flow_keys
            case stt; wd_flow_stt
            case translate; wd_flow_translate
            case models; wd_flow_models
            case bind; wd_flow_bind
            case doctor; wd_flow_doctor
            case '*'; return 0
        end
    end
end
