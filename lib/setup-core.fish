# Ядро мастера настройки whisper-dictate. Подключается из whisper-dictate-setup
# и из `whisper-dictate --test`; сам ничего не рисует — вывод идёт через обычный
# stdout, а интерактив обеспечивают lib/ui-*.fish.
#
# Состав: запись конфига и секретов, ключи в libsecret (слияние под flock,
# значение только через stdin), загрузка моделей, бинд Hyprland, самопроверка и
# порт бывшего set-api-key.fish (список моделей и проверка ключей провайдеров).

source (dirname (status filename))/common.fish

set -g WD_LIBDIR (dirname (realpath (status filename)))
set -g WD_KEYRING_PY $WD_LIBDIR/keyring-doctor.py
set -g WD_BIND_PY $WD_LIBDIR/hypr-bind.py
set -g WD_QS_PY $WD_LIBDIR/qs-integrate.py
set -g WD_MT_PY $WD_LIBDIR/mt-models.py
source $WD_LIBDIR/wm.fish

# ───────────────────────────── конфиг и секреты ────────────────────────────

function wd_conf_set --argument-names key value
    string match -qr '^[A-Z][A-Z0-9_]*$' -- $key; or begin
        echo "Недопустимое имя ключа: $key" >&2
        return 1
    end
    if string match -q '*'\n'*' -- "$value"
        echo "Значение не может содержать перевод строки" >&2
        return 1
    end
    mkdir -p $WD_USER_DIR
    set -l tmp (mktemp $WD_USER_DIR/.dictate.conf.XXXXXX)
    set -l done 0
    if test -f $WD_USER_CONF
        for line in (cat $WD_USER_CONF)
            if string match -qr '^\s*'$key'\s*=' -- $line
                test $done -eq 0; and printf '%s=%s\n' $key $value >>$tmp
                set done 1
            else
                printf '%s\n' $line >>$tmp
            end
        end
    end
    test $done -eq 1; or printf '%s=%s\n' $key $value >>$tmp
    chmod 644 $tmp
    mv $tmp $WD_USER_CONF
end

# Значение секрета — со stdin; в argv внешних команд оно не попадает.
function wd_secrets_env_set --argument-names name
    string match -qr '^[A-Z][A-Z0-9_]*$' -- $name; or return 1
    set -l v (cat | string collect)
    test -n "$v"; or begin
        echo "Пустое значение — ничего не записано" >&2
        return 1
    end
    mkdir -p $WD_USER_DIR
    chmod 700 $WD_USER_DIR
    set -l old (umask)
    umask 077
    set -l tmp (mktemp $WD_USER_DIR/.secrets.env.XXXXXX)
    umask $old
    set -l done 0
    if test -f $WD_SECRETS_ENV
        for line in (cat $WD_SECRETS_ENV)
            if string match -qr '^\s*'$name'\s*=' -- $line
                test $done -eq 0; and printf '%s=%s\n' $name $v >>$tmp
                set done 1
            else
                printf '%s\n' $line >>$tmp
            end
        end
    end
    test $done -eq 1; or printf '%s=%s\n' $name $v >>$tmp
    mv $tmp $WD_SECRETS_ENV
    chmod 600 $WD_SECRETS_ENV
end

function wd_keyring_available
    command -q secret-tool; or return 1
    # lookup несуществующего: код 1 без вывода — сервис жив; ошибка шины/сервиса
    # печатает в stderr и тоже даёт 1, поэтому смотрим на текст.
    set -l err (secret-tool lookup application wd-probe-nonexistent 2>&1 >/dev/null | string collect)
    test -z "$err"
end

# Имя слота -> переменная secrets.env (только три основных провайдера).
function wd_env_name_for --argument-names slot
    switch $slot
        case openrouter; echo OPENROUTER_API_KEY
        case deepl; echo DEEPL_API_KEY
        case gemini; echo GEMINI_API_KEY
    end
end

# wd_key_store NAME [keyring|env] — значение со stdin.
function wd_key_store --argument-names name where
    test -n "$where"; or begin
        wd_keyring_available; and set where keyring; or set where env
    end
    switch $where
        case keyring
            python3 $WD_KEYRING_PY --app (wd_keyring_app) set $name
        case env
            set -l envname (wd_env_name_for $name)
            test -n "$envname"; or begin
                echo "В secrets.env можно хранить только openrouter/deepl/gemini" >&2
                return 1
            end
            wd_secrets_env_set $envname
            and echo "Ключ '$name' записан в $WD_SECRETS_ENV (0600)."
        case '*'
            return 1
    end
end

function wd_key_unset --argument-names name
    python3 $WD_KEYRING_PY --app (wd_keyring_app) unset $name
end

function wd_key_get --argument-names name
    wd_secrets_json | jq -r --arg k "$name" '.apiKeys[$k] // empty' 2>/dev/null
end

function wd_key_list
    wd_secrets_json | jq -r '.apiKeys // {} | keys[]' 2>/dev/null
end

function wd_key_effective --argument-names name
    set -l value (wd_key_get $name)
    if test -n "$value"
        echo $value
        return 0
    end
    set -l primary (wd_primary_slot_for $name)
    if test -n "$primary"; and test "$primary" != "$name"
        wd_key_get $primary
    end
end

function wd_doctor
    python3 $WD_KEYRING_PY --app (wd_keyring_app) doctor $argv
end

# ──────────────────────────────── модели ───────────────────────────────────

function wd_model_dir
    wd_conf MODEL_DIR ~/.local/share/whisper-dictate/models
end

# Каталог OPUS-MT для локального перевода. Тот же путь читает local-translate.sh из ii.
function wd_mt_dir
    string replace -r '^~' $HOME -- (wd_conf MT_MODEL_DIR ~/.local/share/whisper-dictate/mt-models)
end

function wd_mt
    python3 $WD_MT_PY --dir (wd_mt_dir) $argv
end

# GPU-бэкенд ggml (пакет ggml-vulkan и т.п.). Без него whisper-cli считает на процессоре.
function wd_gpu_backend
    for b in vulkan cuda hip sycl
        if test -e /usr/lib/ggml/libggml-$b.so; or test -e /usr/lib/libggml-$b.so
            echo $b
            return 0
        end
    end
    return 1
end

# ─────────────────────────────── Hyprland ──────────────────────────────────

function wd_bind
    python3 $WD_BIND_PY $argv
end

# ─────────────────────────────── самопроверка ──────────────────────────────

function wd_t_ok; printf '  [ OK ] %s\n' "$argv"; end
function wd_t_warn; printf '  [WARN] %s\n' "$argv"; set -g WD_T_WARN (math $WD_T_WARN + 1); end
function wd_t_fail; printf '  [FAIL] %s\n' "$argv"; set -g WD_T_FAIL (math $WD_T_FAIL + 1); end

function wd_selftest
    set -g WD_T_WARN 0
    set -g WD_T_FAIL 0
    set -l full (contains -- --full $argv; and echo 1; or echo 0)
    echo "whisper-dictate "(wd_version)

    echo "Зависимости:"
    for c in fish jq curl flock python3 ffmpeg pw-record notify-send wl-copy
        if command -q $c
            wd_t_ok $c
        else
            wd_t_fail "$c не найден"
        end
    end
    for c in ydotool secret-tool
        command -q $c; and wd_t_ok $c; or wd_t_warn "$c не найден (нужен для вставки/кейринга)"
    end
    pgrep -x ydotoold >/dev/null 2>&1; and wd_t_ok "ydotoold запущен"; or wd_t_warn "ydotoold не запущен — вставка Ctrl+V не сработает"

    echo "Распознавание:"
    set -l wbin (wd_conf WHISPER_BIN whisper-cli)
    string match -q '*/*' -- $wbin; or set wbin (command -v $wbin; or echo /usr/bin/$wbin)
    test -x $wbin; and wd_t_ok "whisper-cli: $wbin"; or wd_t_fail "whisper-cli не найден (пакет whisper-cpp)"
    if set -l gpu (wd_gpu_backend)
        wd_t_ok "GPU для whisper: $gpu"
    else
        wd_t_warn "whisper считает на процессоре, это медленно: sudo pacman -S ggml-vulkan"
    end
    set -l mdir (wd_model_dir)
    set -l model (wd_conf MODEL ggml-large-v3-turbo.bin)
    string match -q '*/*' -- $model; or set model $mdir/$model
    set -l vad (wd_conf VAD_MODEL ggml-silero-v5.1.2.bin)
    string match -q '*/*' -- $vad; or set vad $mdir/$vad
    test -s $model; and wd_t_ok "модель: $model"; or wd_t_fail "нет модели $model (укажите путь в whisper-dictate-gui)"
    test -s $vad; and wd_t_ok "VAD: $vad"; or wd_t_fail "нет VAD-модели $vad (укажите путь в whisper-dictate-gui)"
    test -f (wd_conf SPLIT_SCRIPT $WD_LIBDIR/dictate-split.py); and wd_t_ok "dictate-split.py"; or wd_t_fail "dictate-split.py не найден"

    echo "Локальный перевод (OPUS-MT):"
    # Нужен только провайдеру «Локальный перевод»; при DeepL/Gemini отсутствие не ошибка.
    set -l provider (wd_conf TRANSLATE_PROVIDER "")
    test -n "$provider"; or set provider (wd_key_get dictationProvider 2>/dev/null)
    for line in (wd_mt status 2>/dev/null)
        set -l f (string split -m 2 ' ' -- $line)
        switch $f[1]
            case dir
                echo "  каталог: $f[2]"
            case zle-en en-zle engine
                set -l what (test $f[1] = engine; and echo "движок ctranslate2"; or echo "модель $f[1] ($f[3])")
                if test "$f[2]" = ok
                    wd_t_ok $what
                else if test "$provider" = local
                    wd_t_warn "$what: нет (Nata → Перевод → скачать)"
                else
                    printf '  [ -- ] %s: нет, нужна только для локального перевода\n' $what
                end
        end
    end

    echo "Ключи:"
    set -l have (wd_key_list)
    for k in openrouter deepl gemini
        if contains -- $k $have
            wd_t_ok "$k: задан"
        else
            wd_t_warn "$k: не задан"
        end
    end
    if test -f $WD_SECRETS_ENV
        set -l perm (stat -c %a $WD_SECRETS_ENV)
        test "$perm" = 600; and wd_t_ok "secrets.env права 600"; or wd_t_warn "secrets.env права $perm — выполните chmod 600 $WD_SECRETS_ENV"
    end
    if command -q secret-tool
        set -l rep (python3 $WD_KEYRING_PY --app (wd_keyring_app) doctor 2>&1)
        set -l rc $status
        if test $rc -eq 3
            wd_t_warn (string match -r 'Записей с этим application: \d+' -- $rep)" — дубли, whisper-dictate-setup doctor --fix"
        else if test $rc -eq 0
            wd_t_ok "кейринг: дублей нет"
        else
            wd_t_warn "кейринг недоступен"
        end
    end

    echo "Окно и горячая клавиша:"
    if wd_wm_hyprland
        set -l brep (python3 $WD_BIND_PY status 2>&1)
        if test $status -eq 0
            wd_t_ok (string join ' ' -- $brep[2..-1])
        else
            wd_t_warn "бинд не настроен (whisper-dictate-setup bind)"
        end
    else
        wd_t_ok "Hyprland не обнаружен: текст вставляется в активное окно"
        wd_t_warn "горячую клавишу задайте в настройках окружения: команда whisper-dictate"
    end

    if test $full -eq 1
        echo "Полный прогон:"
        if test -x $wbin; and test -s $model; and test -s $vad
            set -l tmp (mktemp -d)
            ffmpeg -loglevel error -f lavfi -i anullsrc=r=16000:cl=mono -t 1 -c:a pcm_s16le $tmp/silence.wav
            timeout 180 $wbin -m $model -f $tmp/silence.wav -l ru -nt -otxt -of $tmp/out --vad --vad-model $vad >/dev/null 2>&1
            test $status -eq 0; and wd_t_ok "whisper отработал на тишине"; or wd_t_fail "whisper упал на тестовом файле"
            rm -rf $tmp
        end
        for k in openrouter deepl gemini
            contains -- $k $have; or continue
            set -l out (wd_keys_cli --test-$k $k 2>&1 | string collect)
            if string match -q 'Работает*' -- $out
                wd_t_ok "$k: "(string split -m1 . -- $out)[1]
            else
                wd_t_fail "$k: проверка не прошла"
            end
        end
    end

    echo
    echo "Итог: FAIL=$WD_T_FAIL, WARN=$WD_T_WARN"
    test $WD_T_FAIL -eq 0
end

# ──────────────────────── порт set-api-key.fish ────────────────────────────

# У каждого провайдера один основной слот с ключом (gemini / openrouter).
# Слоты отдельных функций (geminiDictation, translatorOpenRouter, ...) — это
# НЕОБЯЗАТЕЛЬНОЕ переопределение: они нужны только тем, кто хочет развести
# квоту (у бесплатного тарифа Google она считается на проект). Если такой
# слот пуст, функция работает на основном ключе провайдера, а не падает с
# "ключ не найден" — вставлять один и тот же ключ по четыре раза не нужно.
function wd_primary_slot_for
    switch "$argv[1]"
        case gemini geminiDictation geminiTranslate translatorGemini
            echo gemini
        case openrouter translatorOpenRouter
            echo openrouter
        case '*'
            echo ""
    end
end


function wd_keys_cli
set -l cmd $argv[1]

switch "$cmd"
    case --list
        set -l current (wd_secrets_json | string collect)
        if test -z "$current"
            echo "В кейринге пока ничего не сохранено."
            return 0
        end
        echo "Сохранённые имена ключей:"
        echo "$current" | jq -r '.apiKeys // {} | keys[]'

    case --get
        # Для несекретных слотов (провайдер, модели, STT), которые читает GUI.
        set -l name $argv[2]
        test -n "$name"; or begin; echo "Использование: keys --get NAME" >&2; return 1; end
        wd_key_get $name

    case --list-models
        set -l name $argv[2]
        # Провайдер по умолчанию определяется по имени ключа (историческая
        # логика: "openrouter" -> OpenRouter, всё остальное -> Gemini), но
        # новые слоты (translatorGemini, translatorOpenRouter, ...) не обязаны
        # называться так буквально — --provider называет его явно и уже не
        # зависит от имени ключа.
        set -l json_mode false
        if contains -- --json $argv
            set json_mode true
        end
        set -l provider_override ""
        for i in (seq (count $argv))
            if test "$argv[$i]" = --provider
                set provider_override $argv[(math $i + 1)]
            end
        end
        # OpenRouter's free line-up rotates constantly, so "which models are
        # free" has to be asked, never hardcoded. The cache always stores the
        # FULL list with a `free` flag per entry; --free-only filters only what
        # is printed, so the toggle can be flipped without re-pinging.
        set -l free_only false
        if contains -- --free-only $argv
            set free_only true
        end
        if test -z "$name"
            echo "Использование: whisper-dictate-setup keys --list-models <name> [--provider gemini|openrouter] [--free-only] [--json]"
            return 1
        end

        set -l key (wd_key_effective $name)
        if test -z "$key"
            echo "Ключ '$name' не найден в кейринге."
            return 1
        end

        # Кэш последнего удачного ответа. Гео-блок идёт ПОЛОСАМИ, а не
        # случайно по одному запросу: замер показал, что и 6 повторов подряд
        # могут все упереться в закрытую exit-ноду. Поэтому повтор — только
        # половина решения; вторая половина в том, чтобы не терять уже
        # полученный список, когда сеть временно закрылась.
        set -l cache_dir ~/.cache/dictate
        set -l cache_file "$cache_dir/models-$name.json"
        mkdir -p $cache_dir 2>/dev/null

        # Гео-блок Google (и реже — OpenRouter) срабатывает через раз: в этой
        # сети exit-нода меняется от запроса к запросу, поэтому один отказ
        # ничего не доказывает. Замер: 4 из 6 подряд заблокированы, следом
        # 4 из 5 прошли. Повтор — единственное, что тут реально помогает.
        # Кэш подменяет ответ только при сетевом/гео-отказе. При неверном
        # ключе или исчерпанной квоте показать старый список — значит соврать
        # пользователю, который только что вставил нерабочий ключ.
        function _is_transient_failure --argument-names resp
            test -z "$resp"; and return 0
            set -l msg (echo "$resp" | jq -r '.error.message // ""' 2>/dev/null)
            # Не "status": это специальная переменная fish (код возврата).
            set -l err_status (echo "$resp" | jq -r '.error.status // ""' 2>/dev/null)
            if string match -q -i '*location is not supported*' -- "$msg"
                return 0
            end
            if test "$err_status" = FAILED_PRECONDITION -o "$err_status" = UNAVAILABLE
                return 0
            end
            # Не распознали как временное — значит, вероятно, проблема с ключом.
            return 1
        end

        function _fetch_with_retry --argument-names url auth_header probe
            set -l attempt 1
            set -l resp ""
            while test $attempt -le 6
                set resp (curl -s --max-time 15 "$url" -H "$auth_header" | string collect)
                if echo "$resp" | jq -e "$probe" >/dev/null 2>&1
                    printf '%s' "$resp"
                    return 0
                end
                set attempt (math $attempt + 1)
                test $attempt -le 6; and sleep 1
            end
            printf '%s' "$resp"
            return 1
        end

        set -l is_openrouter false
        if test -n "$provider_override"
            test "$provider_override" = openrouter; and set is_openrouter true
        else if test "$name" = openrouter
            set is_openrouter true
        end

        if test "$is_openrouter" = true
            # Список моделей OpenRouter публичный (ключ для самого листинга не
            # обязателен), но раз он уже есть под рукой — передаём, лишним не будет.
            set -l resp (_fetch_with_retry "https://openrouter.ai/api/v1/models" "Authorization: Bearer $key" ".data")

            set -l count (echo "$resp" | jq -r '.data | length' 2>/dev/null)
            if test -z "$count"; or test "$count" = 0
                if test -s "$cache_file"; and _is_transient_failure "$resp"
                    if test "$json_mode" = true
                        cat "$cache_file"
                    else
                        echo "Сеть недоступна — показываю сохранённый список:"
                        jq -r '.[] | "  " + .id' < "$cache_file"
                    end
                    return 0
                end
                echo "Не удалось получить список моделей. Ответ сервера:"
                echo "$resp" | jq . 2>/dev/null; or echo "$resp"
                return 1
            end

            # id уже приходит в формате "vendor/model" — это то, что
            # ожидает Ai.qml/OpenRouter-стратегия, ничего резать не надо.
            # architecture.output_modalities отсутствует у части моделей в
            # ответе — тогда считаем "text" (не резать список из-за неполных
            # метаданных), но явную картинку/аудио/эмбеддинг на выходе — вон,
            # это не то, чем можно перевести текст.
            # `free` = обе цены ровно 0. Именно цена, а не суффикс ":free" в
            # id: сейчас 3 из 21 бесплатных моделей его не имеют, так что
            # фильтр по суффиксу их потеряет.
            # Фильтр по output_modalities недостаточен: Lyria (музыка) тоже
            # заявляет "text" на выходе. Тот же урок, что и с Gemini TTS —
            # добавляем блок-лист по id, чтобы генератор музыки/видео не
            # оказался выбран как модель для перевода.
            echo "$resp" | jq -c '[.data[]
                | select((.architecture.output_modalities // ["text"]) | index("text"))
                | select((.id | test("lyria|veo|imagen|sora|whisper|embed|/tts|-tts"; "i")) | not)
                | {id: .id,
                   name: (.name // .id),
                   free: ((((.pricing.prompt // "1") | tonumber) == 0) and (((.pricing.completion // "1") | tonumber) == 0))}]' > "$cache_file"

            if test "$json_mode" = true
                if test "$free_only" = true
                    jq -c '[.[] | select(.free)]' < "$cache_file"
                else
                    cat "$cache_file"
                end
            else
                if test "$free_only" = true
                    echo "Бесплатные модели OpenRouter (цена 0 за ввод и вывод):"
                    jq -r '.[] | select(.free) | "  " + .id' < "$cache_file"
                    echo "Всего бесплатных: "(jq -r '[.[] | select(.free)] | length' < "$cache_file")" из "(jq -r 'length' < "$cache_file")
                else
                    echo "Модели, доступные OpenRouter (аккаунту ключа '$name'):"
                    jq -r '.[] | "  " + .id + (if .free then "  [бесплатно]" else "" end)' < "$cache_file"
                end
            end
        else
            set -l resp (_fetch_with_retry "https://generativelanguage.googleapis.com/v1beta/models" "x-goog-api-key: $key" ".models")

            set -l names (echo "$resp" | jq -r '.models[]? | select(.supportedGenerationMethods[]? == "generateContent") | select((.name | test("tts|image|imagen|nano-banana|lyria|veo|robotics|computer-use|embedding|aqa"; "i")) | not) | .name | sub("^models/"; "")' 2>/dev/null)

            if test -z "$names"
                if test -s "$cache_file"; and _is_transient_failure "$resp"
                    if test "$json_mode" = true
                        cat "$cache_file"
                    else
                        echo "Сеть недоступна — показываю сохранённый список:"
                        jq -r '.[] | "  " + .id' < "$cache_file"
                    end
                    return 0
                end
                echo "Не удалось получить список моделей. Ответ сервера:"
                echo "$resp" | jq . 2>/dev/null; or echo "$resp"
                return 1
            end

            echo "$resp" | jq -c '[.models[]? | select(.supportedGenerationMethods[]? == "generateContent") | select((.name | test("tts|image|imagen|nano-banana|lyria|veo|robotics|computer-use|embedding|aqa"; "i")) | not) | {id: (.name | sub("^models/"; "")), name: (.displayName // (.name | sub("^models/"; "")))}]' > "$cache_file"

            if test "$json_mode" = true
                cat "$cache_file"
            else
                echo "Модели, доступные ключу '$name' (generateContent):"
                for m in $names
                    echo "  $m"
                end
            end
        end

    case --test-gemini
        set -l name $argv[2]
        if test -z "$name"
            echo "Использование: whisper-dictate-setup keys --test-gemini <name> [model]"
            return 1
        end

        set -l key (wd_key_effective $name)
        if test -z "$key"
            echo "Ключ '$name' не найден в кейринге."
            return 1
        end

        # модель: аргументом, иначе из кейринга — из слота ЭТОГО ключа,
        # а не всегда из geminiDictationModel: раньше проверка sidebar-ключа
        # уходила на модель диктовки и врала про причину отказа.
        set -l model $argv[3]
        if test -z "$model"
            switch $name
                case geminiTranslate
                    set model (wd_key_get geminiTranslateModel)
                case geminiDictation
                    set model (wd_key_get geminiDictationModel)
            end
        end
        if test -z "$model"
            set model gemini-flash-latest
        end

        # "__auto__" — служебное значение из настроек ("Auto"), а не имя
        # модели. Отправить его в API нельзя: вернётся "models/__auto__ is
        # not found", и проверка ключа будет валиться всегда, хотя ключ
        # исправен. Разворачиваем в то же, что выберет сам пайплайн.
        set -l auto_note ""
        if test "$model" = __auto__
            set -l listed (curl -s --max-time 10 \
                "https://generativelanguage.googleapis.com/v1beta/models" \
                -H "x-goog-api-key: $key" \
                | jq -r '.models[]? | select(.supportedGenerationMethods[]? == "generateContent") | .name | sub("^models/"; "")' 2>/dev/null)
            set model ""
            if test -n "$listed"
                for candidate in gemini-flash-latest gemini-flash-lite-latest
                    if contains -- $candidate $listed
                        set model $candidate
                        break
                    end
                end
                test -z "$model"; and set model $listed[1]
            end
            if test -z "$model"
                set model gemini-flash-latest
                set auto_note " (Auto: список недоступен, взял дефолт)"
            else
                set auto_note " (Auto)"
            end
        end

        echo "Проверяю ключ '$name' на модели '$model'$auto_note..."

        # Тот же гео-блок полосами, что и у списка моделей: один отказ ничего
        # не значит про ключ. Без повтора проверка врала "ключ не работает"
        # на исправном ключе — ровно то, ради чего эта кнопка и существует.
        set -l resp ""
        set -l text ""
        set -l attempt 1
        while test $attempt -le 4
            set resp (curl -s --max-time 8 \
                "https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent" \
                -H "x-goog-api-key: $key" \
                -H "Content-Type: application/json" \
                -X POST \
                -d '{"contents":[{"parts":[{"text":"Reply with the single word: OK"}]}]}' | string collect)

            set text (echo "$resp" | jq -r '.candidates[0].content.parts[0].text // empty' 2>/dev/null)
            test -n "$text"; and break

            # Ключ отклонён/квота — повторять бессмысленно, ответ окончательный.
            set -l err_status (echo "$resp" | jq -r '.error.status // ""' 2>/dev/null)
            if test -n "$err_status"; and test "$err_status" != FAILED_PRECONDITION; and test "$err_status" != UNAVAILABLE
                break
            end

            set attempt (math $attempt + 1)
            test $attempt -le 4; and sleep 1
        end
        if test -n "$text"
            echo "Работает. Ответ модели: $text"
        else
            echo "Не сработало. Ответ сервера:"
            echo "$resp" | jq . 2>/dev/null; or echo "$resp"
            echo ""
            echo "Подсказка: посмотреть доступные модели —"
            echo "  whisper-dictate-setup keys --list-models $name"
            return 1
        end

    case --test-openrouter
        set -l name $argv[2]
        if test -z "$name"
            echo "Использование: whisper-dictate-setup keys --test-openrouter <name>"
            return 1
        end

        set -l key (wd_key_effective $name)
        if test -z "$key"
            echo "Ключ '$name' не найден в кейринге."
            return 1
        end

        # /auth/key — штатный способ OpenRouter проверить ключ без траты
        # токенов на реальный запрос к модели: возвращает метаданные ключа
        # (лимиты, is_free_tier) при успехе, ошибку — при неверном ключе.
        set -l resp (curl -s --max-time 10 "https://openrouter.ai/api/v1/auth/key" \
            -H "Authorization: Bearer $key" | string collect)

        set -l label (echo "$resp" | jq -r '.data.label // empty' 2>/dev/null)
        if test -n "$label"
            echo "Работает. Ключ: $label"
        else
            echo "Не сработало. Ответ сервера:"
            echo "$resp" | jq . 2>/dev/null; or echo "$resp"
            return 1
        end

    case --test-deepl
        set -l name $argv[2]
        if test -z "$name"
            echo "Использование: whisper-dictate-setup keys --test-deepl <name>"
            return 1
        end

        set -l key (wd_key_effective $name)
        if test -z "$key"
            echo "Ключ '$name' не найден в кейринге."
            return 1
        end

        # У бесплатного ключа DeepL в конце стоит ":fx", и он работает только
        # на api-free.deepl.com; платный ключ — только на api.deepl.com. Если
        # отправить ключ не на тот хост, приходит 403, и это выглядит как
        # «неверный ключ», поэтому хост выбирается по самому ключу.
        set -l host "https://api.deepl.com"
        if string match -q '*:fx' -- "$key"
            set host "https://api-free.deepl.com"
        end

        # /v2/usage — штатная проверка ключа без траты символов: возвращает
        # потраченное и лимит, то есть сразу видно, сколько осталось от
        # бесплатных 500 000 символов в месяц.
        set -l resp (curl -s --max-time 10 "$host/v2/usage" \
            -H "Authorization: DeepL-Auth-Key $key" | string collect)

        set -l used (echo "$resp" | jq -r '.character_count // empty' 2>/dev/null)
        set -l limit (echo "$resp" | jq -r '.character_limit // empty' 2>/dev/null)
        if test -n "$used"; and test -n "$limit"
            echo "Работает. Использовано $used из $limit символов за месяц."
        else
            echo "Не сработало. Ответ сервера:"
            echo "$resp" | jq . 2>/dev/null; or echo "$resp"
            return 1
        end

    case '*'
        # Совместимость: `<name> <value>` (значение в argv видно в ps) или
        # `<name>` со stdin — предпочтительно.
        set -l name $argv[1]
        if test -z "$name"
            echo "Использование:"
            echo "  whisper-dictate-setup keys <name>                    — записать ключ (значение со stdin)"
            echo "  whisper-dictate-setup keys --list                    — список сохранённых имён"
            echo "  whisper-dictate-setup keys --get <name>              — значение несекретного слота"
            echo "  whisper-dictate-setup keys --list-models <name> [--provider P] [--free-only] [--json]"
            echo "  whisper-dictate-setup keys --test-gemini <name> [model]"
            echo "  whisper-dictate-setup keys --test-openrouter <name>"
            echo "  whisper-dictate-setup keys --test-deepl <name>"
            return 1
        end
        if test (count $argv) -ge 2
            echo "Предупреждение: значение в аргументах видно в списке процессов; лучше передавать через stdin." >&2
            printf '%s' $argv[2] | wd_key_store $name keyring
        else
            wd_key_store $name keyring
        end
        and echo "Ключ '$name' сохранён/обновлён."
end
end
