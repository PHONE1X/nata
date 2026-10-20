# whisper-dictate

Голосовая диктовка для Linux (Wayland). Нажал горячую клавишу, говоришь, нажал её ещё раз — распознанный текст вставляется в активное окно.

![Главное меню настройки](docs/screenshots/setup-main.png)
![Выбор распознавания речи](docs/screenshots/setup-stt.png)

## Как это работает

1. **Запись.** Первый запуск `whisper-dictate` (по умолчанию горячая клавиша `SUPER + U`) начинает запись с микрофона через PipeWire (`pw-record`, 16 кГц, моно). Второй запуск останавливает её.
2. **Разбиение.** Длинная запись режется на куски по `CHUNK_SECONDS` (по умолчанию 120 с), чтобы каждый кусок распознавался отдельно.
3. **Распознавание (STT).** Каждый кусок идёт либо в облако (OpenRouter, Gemini), либо в локальный `whisper-cli` (whisper.cpp). Если облако недоступно или вернуло ошибку, кусок распознаётся локально.
4. **Перевод (необязательно).** Если включён, текст переводится через DeepL, Gemini, OpenRouter или локальную модель.
5. **Вставка.** Текст кладётся в буфер обмена (`wl-copy`) и вставляется в окно через `ydotool` (Ctrl+V).

На Hyprland скрипт дополнительно запоминает окно, из которого начали диктовать, и возвращает фокус туда перед вставкой. Раскладка для вывода берётся из окна-получателя. На других окружениях текст вставляется в то окно, которое активно в момент вставки.

## Приватность

По умолчанию распознавание **полностью локальное**: аудио не покидает компьютер. Облако включается явно (`STT=openrouter` или `STT=gemini`) и требует API-ключа. Перевод через облако так же включается отдельно.

## Требования

- Wayland с `wl-clipboard`, `ydotool` (запущен `ydotoold`), PipeWire (`pw-record`), `ffmpeg`, `jq`, `fish`, `libsecret` (`secret-tool`), `libnotify`, `curl`.
- Для локального распознавания: `whisper.cpp` (`whisper-cli`) и модель `ggml-*.bin`. Для GPU на AMD/Intel/NVIDIA удобнее собрать `whisper.cpp` с Vulkan (есть `packaging/whisper.cpp-vulkan`).
- Для GUI-настройки: `zenity` (GNOME/другие) или `kdialog` (KDE). Для TUI: `fzf`. Без них настройка работает в CLI.

Привязки к окружению нет: основной сценарий работает на Hyprland, KDE Plasma, GNOME и других Wayland-окружениях. Quickshell не нужен.

## Установка

Пакет собирается локально из дерева репозитория (публикация в AUR пока не сделана):

```
cd packaging/whisper.cpp-vulkan && makepkg -si     # необязательно: GPU-whisper
cd packaging/whisper-dictate    && makepkg -si
```

Установка раскладывает:

- `/usr/bin/whisper-dictate` и `/usr/bin/whisper-dictate-setup`;
- `/usr/lib/whisper-dictate/` (библиотеки);
- `/etc/whisper-dictate/dictate.conf` (системный конфиг);
- `/usr/share/whisper-dictate/secrets.env.example`;
- `.desktop`-файлы в `/usr/share/applications/`.

После установки запустите `whisper-dictate-setup`.

## Настройка

```
whisper-dictate-setup              # режим выбирается сам: GUI, TUI или CLI
whisper-dictate-setup --cli        # принудительно CLI
```

Меню покрывает:

- **Проверку установки** и самотест;
- **API-ключи** (OpenRouter, DeepL, Gemini) — ввод скрытый, в аргументах командной строки ключи не передаются;
- **Распознавание речи**: только локально или облако;
- **Провайдер перевода**;
- **Модели whisper**: скачивание `tiny` … `large-v3-turbo`, VAD-модель, выбор текущей;
- **Горячую клавишу**: на Hyprland меню добавляет блок в конфиг; на других окружениях показывает, где назначить команду `whisper-dictate` (KDE: «Параметры системы → Сочетания клавиш → Добавить команду»; GNOME: «Параметры → Клавиатура → Настраиваемые сочетания»);
- **Индикатор в Quickshell ii** — необязательный шаг, см. ниже;
- **Диагностику кейринга** (дубли записей в libsecret).

Прямые команды:

```
whisper-dictate-setup model download large-v3-turbo
whisper-dictate-setup key OPENROUTER_API_KEY         # значение со stdin
whisper-dictate-setup conf STT openrouter            # прочитать/записать dictate.conf
whisper-dictate-setup bind apply --key "SUPER + U"   # Hyprland
whisper-dictate-setup doctor [--fix]
whisper-dictate-setup migrate                        # подцепить старую установку
whisper-dictate --test [--full]                      # самопроверка
```

## Конфиг и секреты

Приоритет настроек: переменная `DICTATE_<КЛЮЧ>` в окружении > `~/.config/whisper-dictate/dictate.conf` > `/etc/whisper-dictate/dictate.conf` > значение по умолчанию.

Ключи API ищутся в таком порядке: переменные окружения (`OPENROUTER_API_KEY`, `DEEPL_API_KEY`, `GEMINI_API_KEY`) > `~/.config/whisper-dictate/secrets.env` (права 0600) > libsecret.

Модели по умолчанию лежат в `~/.local/share/whisper-dictate/models`.

## Quickshell ii (необязательно)

Если вы используете Quickshell ii (illogical-impulse), можно добавить кнопку диктовки в бар:

```
cd packaging/quickshell-ii-dictate && makepkg -si
quickshell-ii-dictate-apply --status   # подключён ли модуль
quickshell-ii-dictate-apply            # подключить (с бэкапом Directories.qml)
quickshell-ii-dictate-apply --revert   # откатить
```

Патч меняет только путь к скрипту диктовки в `~/.config/quickshell/ii/modules/common/Directories.qml`. Если ваша конфигурация Quickshell отличается и патч не ложится, скрипт выводит ошибку: проверьте вывод и при необходимости откатите через `--revert` или восстановите файл из `Directories.qml.bak_whisper-dictate`.

## Тесты

```
fish tests/run.fish
```

Тесты работают в песочнице: заглушки `secret-tool`, `whisper-cli`, `hyprctl` и другие. Реальные ключи, конфиги и записи в кейринг не трогаются.

## Структура

```
bin/        whisper-dictate (переключатель записи), whisper-dictate-setup (настройка)
lib/        общие функции, распознавание, настройка, адаптер окна (wm.fish)
etc/        системный dictate.conf
share/      .desktop-файлы, шаблон secrets.env
packaging/  PKGBUILD для whisper-dictate, whisper.cpp-vulkan, quickshell-ii-dictate
tests/      песочничные тесты
docs/       скриншоты
```

## Лицензия

MIT, см. [LICENSE](LICENSE).
