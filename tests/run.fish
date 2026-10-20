#!/usr/bin/env fish
# Тесты whisper-dictate. Всё в песочнице: свой HOME/XDG, secret-tool и
# whisper-cli/notify-send/wl-copy/hyprctl — заглушки из tests/stubs.
# Настоящий кейринг, экран и конфиги пользователя не затрагиваются.
#   fish tests/run.fish

set -l repo (realpath (dirname (status filename))/..)
set -l T (mktemp -d)
set -gx HOME $T/home
mkdir -p $HOME $T/run $T/etc $T/hypr/custom
set -gx XDG_CONFIG_HOME $HOME/.config
set -gx XDG_STATE_HOME $HOME/.local/state
set -gx XDG_RUNTIME_DIR $T/run
set -gx STUB_SECRET_DIR $T/sec
set -gx STUB_NOTIFY_LOG $T/notify.log
set -gx STUB_CLIP_FILE $T/clip.txt
set -gx WHISPER_DICTATE_SYSCONFDIR $T/etc
set -gx HYPR_CONFIG_DIR $T/hypr
set -e HYPRLAND_INSTANCE_SIGNATURE
set -gx PATH $repo/tests/stubs $repo/bin $PATH
set -l S $repo/bin/whisper-dictate-setup
set -l D $repo/bin/whisper-dictate

set -g pass 0
set -g failn 0
function check --argument-names name
    if eval (string escape -- $argv[2..-1] | string join ' ') >/dev/null 2>&1
        set pass (math $pass + 1)
        echo "  ok   $name"
    else
        set failn (math $failn + 1)
        echo "  FAIL $name   ($argv[2..-1])"
    end
end

echo "== синтаксис"
for f in $repo/bin/whisper-dictate $repo/bin/whisper-dictate-setup $repo/lib/*.fish
    check "fish -n "(basename $f) fish -n $f
end
for f in $repo/lib/*.py $repo/tests/stubs/secret-tool
    check "python "(basename $f) python3 -c "import ast,sys; ast.parse(open('$f').read())"
end

echo "== конфиг: приоритеты"
printf 'MODEL=sys.bin\nCHUNK_SECONDS=60\n# comment\nPROMPT="кавычки"\n' >$T/etc/dictate.conf
check "sys значение" test (fish $S conf MODEL) = sys.bin
$S conf MODEL user.bin
check "user перебивает sys" test (fish $S conf MODEL) = user.bin
check "sys остаётся для других ключей" test (fish $S conf CHUNK_SECONDS) = 60
check "env перебивает всё" test (env DICTATE_MODEL=env.bin fish $S conf MODEL) = env.bin
check "кавычки снимаются" test (fish $S conf PROMPT) = "кавычки"
$S conf MODEL again.bin
check "conf set заменяет, а не дублирует" test (grep -c '^MODEL=' $XDG_CONFIG_HOME/whisper-dictate/dictate.conf) -eq 1

echo "== секреты: слои и flock"
printf 'sk-keyring-or' | $S key openrouter >/dev/null
check "кейринг прочитан" test (fish -c "source $repo/lib/setup-core.fish; wd_key_get openrouter") = sk-keyring-or
printf 'sk-file-or' | $S key openrouter --env >/dev/null
check "secrets.env перебивает кейринг" test (fish -c "source $repo/lib/setup-core.fish; wd_key_get openrouter") = sk-file-or
check "env перебивает secrets.env" test (env OPENROUTER_API_KEY=sk-env fish -c "source $repo/lib/setup-core.fish; wd_key_get openrouter") = sk-env
check "secrets.env права 600" test (stat -c %a $XDG_CONFIG_HOME/whisper-dictate/secrets.env) = 600
for i in 1 2 3 4 5 6 7 8 9 10
    printf "v$i" | fish $S key slot$i >/dev/null 2>&1 &
end
wait
check "10 параллельных записей — ни одна не потеряна" test (fish -c "source $repo/lib/setup-core.fish; wd_key_list" | grep -c '^slot') -eq 10
check "в репозитории нет ключей" not grep -rIE 'sk-[A-Za-z0-9]{20,}|AIza[0-9A-Za-z_-]{30,}|sk-or-v1' $repo --exclude-dir=.git --exclude-dir=tests

echo "== doctor: дубли в кейринге"
echo '{"apiKeys":{"old1":"x1"}}' | secret-tool store --label=a application whisper-dictate
echo '{"apiKeys":{"old2":"x2"}}' | secret-tool store --label=b application whisper-dictate explanation Foo
$S doctor >/dev/null 2>&1
check "doctor видит дубли (код 3)" test $status -eq 3
$S doctor --fix --yes >/dev/null 2>&1
check "--fix проходит" test $status -eq 0
check "после --fix одна запись" test (secret-tool search --all application whisper-dictate | grep -c '^\[') -eq 1
check "после --fix ключи слиты" test (secret-tool lookup application whisper-dictate | jq -r '.apiKeys | has("old1") and has("old2") and has("slot3")') = true

set -l seed_dir (mktemp -d)
echo '{"apiKeys":{"legacy1":"L1"}}' | env STUB_SECRET_DIR=$seed_dir secret-tool store --label=l application illogical-impulse
printf 'new' | env STUB_SECRET_DIR=$seed_dir fish $S key seeded >/dev/null 2>&1
check "первая запись сохраняет ключи illogical-impulse" test (env STUB_SECRET_DIR=$seed_dir secret-tool lookup application whisper-dictate | jq -r '.apiKeys | has("legacy1") and has("seeded")') = true
check "illogical-impulse не тронут" test (env STUB_SECRET_DIR=$seed_dir secret-tool lookup application illogical-impulse | jq -r '.apiKeys | has("seeded") | not') = true
rm -rf $seed_dir
check "резервная копия 0600" test (stat -c %a (ls $XDG_STATE_HOME/whisper-dictate/keyring-backup-*.json)[1]) = 600

echo "== Hyprland: бинд"
cp $repo/tests/fixtures/keybinds.lua $T/hypr/custom/keybinds.lua
$S bind apply --key "SUPER + U" --no-live >/dev/null 2>&1
check "старый dictate.fish = конфликт (код 2)" test $status -eq 2
$S bind apply --key "SUPER + A" --no-live >/dev/null 2>&1
check "чужой бинд = конфликт (код 2)" test $status -eq 2
check "файл не тронут при конфликте" test (grep -c whisper-dictate $T/hypr/custom/keybinds.lua) -eq 0
$S bind apply --key "SUPER + U" --replace-legacy --no-live >/dev/null 2>&1
check "--replace-legacy проходит" test $status -eq 0
check "старая строка закомментирована" grep -q -- '-- \[whisper-dictate: заменено\] hl.bind("SUPER + U"' $T/hypr/custom/keybinds.lua
check "блок записан" grep -q 'hl.dsp.exec_cmd("whisper-dictate")' $T/hypr/custom/keybinds.lua
set -l before (md5sum < $T/hypr/custom/keybinds.lua)
$S bind apply --key "SUPER + U" --no-live >/dev/null 2>&1
check "повтор идемпотентен" test (md5sum < $T/hypr/custom/keybinds.lua) = $before
$S bind apply --key "CTRL + SUPER + D" --no-live >/dev/null 2>&1
check "смена аккорда заменяет блок" test (grep -c '>>> whisper-dictate' $T/hypr/custom/keybinds.lua) -eq 1
$S bind remove >/dev/null 2>&1
check "remove убирает блок" test (grep -c 'whisper-dictate (managed' $T/hypr/custom/keybinds.lua) -eq 0
printf 'bind = SUPER, Q, exec, kitty\nbind = SUPER SHIFT, U, exec, foo\n' >$T/hypr/hyprland.conf
$S bind apply --file $T/hypr/hyprland.conf --key "SUPER + SHIFT + U" --no-live >/dev/null 2>&1
check ".conf: конфликт" test $status -eq 2
$S bind apply --file $T/hypr/hyprland.conf --key "ALT + D" --no-live >/dev/null 2>&1
check ".conf: запись" grep -q 'bind = ALT, D, exec, whisper-dictate' $T/hypr/hyprland.conf

echo "== самопроверка"
mkdir -p $T/models
printf 'x%.0s' (seq 100) >$T/models/m.bin
set -gx DICTATE_WHISPER_BIN $repo/tests/stubs/whisper-cli
set -gx DICTATE_MODEL_DIR $T/models
set -gx DICTATE_MODEL m.bin
set -gx DICTATE_VAD_MODEL m.bin
$D --test >$T/selftest.out 2>&1
check "--test: без FAIL → код 0" test $status -eq 0
check "--test --full: прогон whisper" sh -c "$D --test --full 2>&1 | grep -q 'whisper отработал'"
set -gx DICTATE_MODEL_DIR $T/nomodels
$D --test >/dev/null 2>&1
check "--test: нет модели → код 1" test $status -eq 1

echo "== конвейер: запись → whisper → вставка (DRY_RUN)"
set -gx DICTATE_MODEL_DIR $T/models
set -gx DICTATE_STT local
set -gx DICTATE_DRY_RUN 1
ffmpeg -loglevel error -f lavfi -i "sine=frequency=440:duration=2" -ar 16000 -ac 1 -c:a pcm_s16le $T/rec.wav
set -l cache $HOME/.cache/dictate
mkdir -p $cache/queue
printf '{"wav":"%s","target_addr":"","target_title":"t","target_class":"c","keymap":"ru","lang":"ru"}' $T/rec.wav >$cache/queue/000001.job
timeout 60 $D --run-worker >/dev/null 2>&1
set -l log $HOME/.local/state/dictate/dictate.log
check "лог создан в ~/.local/state/dictate" test -s $log
check "задание обработано" grep -q 'JOB 000001 done\|JOB 000001 TIMING' $log
check "распознанный текст дошёл до вставки" grep -q 'Привет, это тест' $log
check "wav удалён после успеха" not test -e $T/rec.wav
set -gx STUB_WHISPER_FAIL 1
set -gx DICTATE_WHISPER_RETRY_DELAY 0
set -gx DICTATE_WHISPER_ATTEMPTS 1
ffmpeg -loglevel error -f lavfi -i "sine=frequency=440:duration=2" -ar 16000 -ac 1 -c:a pcm_s16le $T/rec2.wav
printf '{"wav":"%s","target_addr":"","target_title":"t","target_class":"c","keymap":"ru","lang":"ru"}' $T/rec2.wav >$cache/queue/000002.job
timeout 60 $D --run-worker >/dev/null 2>&1
check "сбой whisper: запись сохранена" test -e $T/rec2.wav
check "сбой whisper: задание в failed/" test -e $cache/failed/000002.job
set -e STUB_WHISPER_FAIL

echo "== Quickshell: интеграция ii"
set -l QS $T/qs
mkdir -p $QS/ii/modules/common $QS/ii/modules/ii/bar
printf 'import QtQuick\n\nItem {\n    property var pages: [\n    ]\n}\n' >$QS/ii/settings.qml
printf 'Singleton {\n    property var states: QtObject {\n        property JsonObject ai: JsonObject {\n        }\n    }\n}\n' >$QS/ii/modules/common/Persistent.qml
printf 'RowLayout {\n    id: indicatorsRowLayout\n    spacing: 0\n}\n' >$QS/ii/modules/ii/bar/BarContent.qml
cp -r $QS/ii $T/qs-orig
check "ii: до установки — не установлено" not python3 $repo/lib/qs-integrate.py ii status --dir $QS
check "ii: установка" python3 $repo/lib/qs-integrate.py ii install --dir $QS
check "ii: статус после установки" python3 $repo/lib/qs-integrate.py ii status --dir $QS
python3 $repo/lib/qs-integrate.py ii install --dir $QS >/dev/null
check "ii: повторная установка не дублирует" test (grep -c 'whisper-dictate >>>' $QS/ii/settings.qml) -eq 1
check "ii: удаление" python3 $repo/lib/qs-integrate.py ii remove --dir $QS
check "ii: после удаления файлы как до установки" diff -r $T/qs-orig $QS/ii
check "ii: нет временных файлов" test (count (find $QS -name '*.wd-tmp')) -eq 0
mkdir -p $QS/bad
cp -r $T/qs-orig $QS/bad/ii
printf 'RowLayout {\n    spacing: 0\n}\n' >$QS/bad/ii/modules/ii/bar/BarContent.qml
cp -r $QS/bad/ii $T/bad-before
check "ii: якорь не найден — отказ" not python3 $repo/lib/qs-integrate.py ii install --dir $QS/bad
check "ii: при отказе файлы не тронуты" diff -r $T/bad-before $QS/bad/ii

echo "== OPUS-MT"
set -l MT $T/mt
$S conf MT_MODEL_DIR $MT >/dev/null
check "mt: пустой каталог — модели нет" string match -q 'zle-en missing*' -- ($S mt status)
set -l SRV $T/hf/luigi000/opus-mt-tc-big-zle-en-ct2-int8/resolve/987aa3c46cf871ea683bcc7a540e3053d372cb71
mkdir -p $SRV
for f in config.json shared_vocabulary.json source.spm target.spm model.bin
    echo x >$SRV/$f
end
WD_MT_BASE_URL=file://$T/hf $S mt download zle-en >/dev/null 2>&1
check "mt: загрузка zle-en" string match -q 'zle-en ok*' -- ($S mt status)
check "mt: нет .part после загрузки" not test -e $MT/opus-tc-big/zle-en.part
check "mt: en-zle по-прежнему нет" string match -q 'en-zle missing*' -- ($S mt status)

echo "== модели whisper и ускоритель"
set -l WM $T/wm
$S conf MODEL_DIR $WM >/dev/null
check "whisper: VAD нет" string match -q 'ggml-silero-v5.1.2.bin missing*' -- ($S whisper-models status)
set -l VSRV $T/hf/ggml-org/whisper-vad/resolve/main
mkdir -p $VSRV
head -c 885098 /dev/zero >$VSRV/ggml-silero-v5.1.2.bin
WD_HF_BASE_URL=file://$T/hf $S whisper-models download ggml-silero-v5.1.2.bin >/dev/null 2>&1
check "whisper: VAD скачан" string match -q 'ggml-silero-v5.1.2.bin ok*' -- ($S whisper-models status)
set -l BSRV $T/hf/ggerganov/whisper.cpp/resolve/main
mkdir -p $BSRV
echo x >$BSRV/ggml-tiny.bin
check "whisper: неверный размер — ошибка" not env WD_HF_BASE_URL=file://$T/hf $S whisper-models download ggml-tiny.bin
check "whisper: нет недокачанного файла" not test -e $WM/ggml-tiny.bin.part
check "whisper: неизвестная модель" not $S whisper-models download nope.bin
mkdir -p $T/ggml
touch $T/ggml/libggml-hip.so
check "accel: hip найден" string match -q 'hip ok*' -- (env WD_GGML_DIR=$T/ggml $S accel status)
check "accel: vulkan нет" string match -q 'vulkan missing*' -- (env WD_GGML_DIR=$T/ggml $S accel status)
check "accel: установка через WD_PKEXEC" env WD_PKEXEC=true $S accel install vulkan

echo
echo "итого: ok=$pass fail=$failn  (песочница $T)"
rm -rf $T
test $failn -eq 0
