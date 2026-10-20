# Общие функции whisper-dictate: слои конфигурации и чтение секретов.
# Подключается и рабочей программой (whisper-dictate), и мастером настройки.
#
# Конфиг (ключ=значение, # — комментарий, пустое значение = «не задано»):
#   окружение DICTATE_<КЛЮЧ>  >  ~/.config/whisper-dictate/dictate.conf
#   >  /etc/whisper-dictate/dictate.conf  >  дефолт в коде.
# Секреты:
#   окружение (OPENROUTER_API_KEY, DEEPL_API_KEY, GEMINI_API_KEY)
#   >  ~/.config/whisper-dictate/secrets.env  >  libsecret (кейринг).
# Файлы НЕ source-ятся: значения разбираются построчно, чтобы чужой конфиг
# не мог выполнить код.

set -g WD_SYSCONF_DIR /etc/whisper-dictate
test -n "$WHISPER_DICTATE_SYSCONFDIR"; and set -g WD_SYSCONF_DIR $WHISPER_DICTATE_SYSCONFDIR
set -l _xdg_conf "$XDG_CONFIG_HOME"
test -n "$_xdg_conf"; or set _xdg_conf $HOME/.config
set -g WD_USER_DIR $_xdg_conf/whisper-dictate
set -g WD_SYS_CONF $WD_SYSCONF_DIR/dictate.conf
set -g WD_USER_CONF $WD_USER_DIR/dictate.conf
set -g WD_SECRETS_ENV $WD_USER_DIR/secrets.env

function wd_unquote_expand --argument-names v
    set v (string replace -r '^"(.*)"$' '$1' -- $v)
    set v (string replace -r "^'(.*)'\$" '$1' -- $v)
    set v (string replace -r '^~(/|$)' "$HOME\$1" -- $v)
    string replace -a '$HOME' "$HOME" -- $v
end

# Печатает последнее значение KEY из файла; код 1, если ключа нет или значение пустое.
function wd_file_get --argument-names file key
    test -r "$file"; or return 1
    set -l m (string replace -rf -- '^\s*'$key'\s*=\s*(.*?)\s*$' '$1' <$file)
    test (count $m) -gt 0; or return 1
    set -l v (wd_unquote_expand $m[-1])
    test -n "$v"; or return 1
    printf '%s\n' $v
end

function wd_conf --argument-names key default
    set -l envname DICTATE_$key
    if set -q $envname; and test -n "$$envname"
        printf '%s\n' $$envname
        return 0
    end
    for f in $WD_USER_CONF $WD_SYS_CONF
        set -l v (wd_file_get $f $key)
        if test $status -eq 0
            printf '%s\n' $v
            return 0
        end
    end
    printf '%s\n' $default
end

function wd_keyring_app
    wd_conf KEYRING_APP whisper-dictate
end

# Ключи, сохранённые до отделения от Quickshell ii, лежат под старым именем приложения.
function wd_keyring_json
    set -l json (secret-tool lookup application (wd_keyring_app) 2>/dev/null | string collect)
    test -n "$json"; or set json (secret-tool lookup application illogical-impulse 2>/dev/null | string collect)
    printf '%s' $json
end

# Единый JSON {apiKeys:{...}}: кейринг < secrets.env < окружение; несекретные
# настройки (TRANSLATE_PROVIDER, STT, GEMINI_MODEL) из dictate.conf перебивают кейринг.
function wd_secrets_json
    set -l kr (wd_keyring_json | string collect)
    test -n "$kr"; or set kr '{}'
    set -l or_k (wd_pick_secret OPENROUTER_API_KEY)
    set -l dl_k (wd_pick_secret DEEPL_API_KEY)
    set -l gm_k (wd_pick_secret GEMINI_API_KEY)
    env WD_KR="$kr" WD_OR="$or_k" WD_DL="$dl_k" WD_GM="$gm_k" \
        WD_PROV=(wd_conf TRANSLATE_PROVIDER) WD_STT=(wd_conf STT) WD_GMODEL=(wd_conf GEMINI_MODEL) \
        jq -nc '
        (env.WD_KR | fromjson? // {}) as $kr
        | $kr
        | .apiKeys = (.apiKeys // {})
        | if env.WD_OR != "" then .apiKeys.openrouter = env.WD_OR else . end
        | if env.WD_DL != "" then .apiKeys.deepl = env.WD_DL else . end
        | if env.WD_GM != "" then .apiKeys.gemini = env.WD_GM else . end
        | if env.WD_PROV != "" then .apiKeys.dictationProvider = env.WD_PROV else . end
        | if env.WD_STT != "" then .apiKeys.dictationStt = env.WD_STT else . end
        | if env.WD_GMODEL != "" then .apiKeys.geminiDictationModel = env.WD_GMODEL else . end' 2>/dev/null
    or echo '{"apiKeys":{}}'
end

# окружение > secrets.env
function wd_pick_secret --argument-names name
    if set -q $name; and test -n "$$name"
        printf '%s' $$name
        return 0
    end
    set -l v (wd_file_get $WD_SECRETS_ENV $name)
    test $status -eq 0; and printf '%s' $v
end

function wd_version
    set -l v (cat $WD_LIBDIR/VERSION 2>/dev/null)
    test -n "$v[1]"; and echo $v[1]; or echo unknown
end
