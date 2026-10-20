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
- Для GUI-настройки: `python-gobject` и `gtk4` (ставятся как зависимости пакета). Для TUI в терминале: `fzf`. Без него работает CLI.

Привязки к окружению нет: основной сценарий работает на Hyprland, KDE Plasma, GNOME и других Wayland-окружениях. Quickshell не нужен.

## Установка

Пакет собирается локально из дерева репозитория (публикация в AUR пока не сделана):

```
cd packaging/whisper.cpp-vulkan && makepkg -si     # необязательно: GPU-whisper
cd packaging/whisper-dictate    && makepkg -si
```

Установка раскладывает:

- `/usr/bin/whisper-dictate`, `/usr/bin/whisper-dictate-setup`, `/usr/bin/whisper-dictate-gui`;
- `/usr/lib/whisper-dictate/` (библиотеки и заготовки интеграции Quickshell);
- `/etc/whisper-dictate/dictate.conf` (системный конфиг);
- `/usr/share/whisper-dictate/secrets.env.example`;
- `.desktop`-файлы в `/usr/share/applications/`.

После установки запустите `whisper-dictate-gui` (или `whisper-dictate-setup`).

## Настройка

Окно настройки (`whisper-dictate-gui`) — основной способ. Все разделы в одном окне:

- **Распознавание**: только локально или облако OpenRouter (с выбором модели); путь к основной модели `ggml-*.bin` и к VAD-модели выбирается файловым диалогом. Модели не скачиваются: укажите файлы, которые уже есть на диске.
- **Перевод**: выключен, Gemini, DeepL или локальный скрипт; модель Gemini.
- **API-ключи**: OpenRouter, DeepL, Gemini. Поле скрытое, ключ уходит в libsecret (или в `secrets.env`, если libsecret недоступен).
- **Горячая клавиша**: на Hyprland записывает привязку; на других окружениях показывает, где назначить команду `whisper-dictate`.
- **Quickshell**: кнопки подключения виджета (см. ниже).
- **Проверка**: самотест установки.

Терминальный вариант: `whisper-dictate-setup --tui` (нужен `fzf`) или `whisper-dictate-setup --cli`.

Прямые команды:

```
whisper-dictate-setup key openrouter                  # значение со stdin
whisper-dictate-setup conf MODEL /путь/к/ggml-medium.bin
whisper-dictate-setup bind apply --key "SUPER + U"    # Hyprland
whisper-dictate-setup qs ii install                   # или: qs standalone install
whisper-dictate-setup doctor [--fix]
whisper-dictate --test [--full]                       # самопроверка
```

## Конфиг и секреты

Приоритет настроек: переменная `DICTATE_<КЛЮЧ>` в окружении > `~/.config/whisper-dictate/dictate.conf` > `/etc/whisper-dictate/dictate.conf` > значение по умолчанию.

Ключи API ищутся в таком порядке: переменные окружения (`OPENROUTER_API_KEY`, `DEEPL_API_KEY`, `GEMINI_API_KEY`) > `~/.config/whisper-dictate/secrets.env` (права 0600) > libsecret. Ключи, сохранённые раньше под именем `illogical-impulse`, при первой записи копируются в новую запись и продолжают работать.

## Quickshell

Два варианта интеграции, оба подключаются кнопкой в GUI или командой `whisper-dictate-setup qs <ii|standalone> install`. Удаление (`remove`) убирает только то, что добавил модуль.

- **Отдельный виджет** (`standalone`): самостоятельный индикатор записи и очереди. Копируется в `~/.config/quickshell/whisper-dictate/`. Запуск: `qs -c whisper-dictate` (можно добавить в автозапуск Hyprland).
- **Logical Impulse (ii)**: кнопка диктовки в правой части бара и пункт «Диктовка» в настройках ii. Установщик добавляет блоки между маркерами `// whisper-dictate >>>` и `// whisper-dictate <<<` в `settings.qml`, `modules/common/Persistent.qml` и `modules/ii/bar/BarContent.qml`. Перед записью он проверяет, что нужные места в файлах найдены ровно один раз; если версия ii отличается, ничего не меняется и выводится ошибка. После установки перезапустите Quickshell.

Виджеты написаны по структуре upstream Logical Impulse и в этой среде не запускались: проверьте на своей сессии Quickshell.

## Тесты

```
fish tests/run.fish
```

Тесты работают в песочнице: заглушки `secret-tool`, `whisper-cli`, `hyprctl` и другие. Реальные ключи, конфиги и записи в кейринг не трогаются.

## Структура

```
bin/        whisper-dictate (переключатель записи), whisper-dictate-setup (настройка), whisper-dictate-gui (GTK-окно)
lib/        общие функции, распознавание, настройка, адаптер окна (wm.fish), qs-integrate.py (интеграция Quickshell)
etc/        системный dictate.conf
share/      .desktop-файлы, шаблон secrets.env, виджеты Quickshell (quickshell/ii, quickshell/standalone)
packaging/  PKGBUILD для whisper-dictate и whisper.cpp-vulkan
tests/      песочничные тесты
docs/       скриншоты
```

## Лицензия

MIT, см. [LICENSE](LICENSE).
