# whisper-dictate

Голосовой ввод для Wayland/Hyprland: запись → whisper.cpp (локально) или облачный STT → опциональный перевод → вставка.

## Установка (Arch)

```
cd packaging/whisper.cpp-vulkan && makepkg -si     # опционально, GPU-whisper
cd packaging/whisper-dictate    && makepkg -si
cd packaging/quickshell-ii-dictate && makepkg -si  # опционально, только для Quickshell ii
quickshell-ii-dictate-apply                        # правит ~/.config/quickshell/ii (с бэкапом)
```

Раскладка: `/usr/bin/whisper-dictate{,-setup}`, `/usr/lib/whisper-dictate/`, `/etc/whisper-dictate/dictate.conf`.
Пользовательское: `~/.config/whisper-dictate/{dictate.conf,secrets.env}`, модели в `~/.local/share/whisper-dictate/models`.

## Настройка

```
whisper-dictate-setup            # GUI (zenity/kdialog), TUI (fzf) или CLI — выбирается сам
whisper-dictate-setup --gui|--tui|--cli
whisper-dictate-setup model download large-v3-turbo
whisper-dictate-setup bind apply --key "SUPER + U"   # блок в keybinds.lua / .conf между маркерами
whisper-dictate-setup doctor [--fix]                 # дубли записей в libsecret
whisper-dictate-setup migrate                        # подцепить старую установку (~/.local/bin/dictate.fish)
whisper-dictate --test [--full]                      # самопроверка
```

## Конфиг и секреты

Приоритет конфига: `DICTATE_<КЛЮЧ>` в окружении > `~/.config/whisper-dictate/dictate.conf` > `/etc/whisper-dictate/dictate.conf` > дефолт.
Секреты: переменные окружения (`OPENROUTER_API_KEY`, `DEEPL_API_KEY`, `GEMINI_API_KEY`) > `secrets.env` (0600, см. `/usr/share/whisper-dictate/secrets.env.example`) > libsecret.
Ключи в argv не передаются: только stdin / скрытый ввод. Запись в libsecret — read-modify-write под `flock`.

## Тесты

```
fish tests/run.fish   # песочница, заглушки secret-tool/whisper-cli/hyprctl/…; реальные ключи и конфиги не трогает
```
