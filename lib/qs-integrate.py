#!/usr/bin/env python3
"""Подключение модуля диктовки к Quickshell: standalone или Logical Impulse (ii).

Usage: qs-integrate.py <ii|standalone> <status|install|remove> [--dir QS_CONFIG_DIR]
"""
import argparse
import os
import shutil
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
SOURCE_ROOTS = [HERE / "quickshell", HERE.parent / "share" / "quickshell"]

BEGIN = "// whisper-dictate >>>"
END = "// whisper-dictate <<<"
MARK = "// whisper-dictate: модуль интеграции"

II_COPIES = {
    "modules/ii/bar/DictateIndicator.qml": "ii/modules/ii/bar/DictateIndicator.qml",
    "modules/settings/DictateConfig.qml": "ii/modules/settings/DictateConfig.qml",
}

SETTINGS_FILE = "settings.qml"
SETTINGS_ANCHOR = "property var pages: ["
SETTINGS_BLOCK = """{
    name: Translation.tr("Dictation"),
    icon: "mic",
    component: "modules/settings/DictateConfig.qml"
},"""

PERSIST_FILE = "modules/common/Persistent.qml"
PERSIST_ANCHOR = "property JsonObject ai: JsonObject {"
PERSIST_BLOCK = """property JsonObject dictation: JsonObject {
    property bool active: false
    property int startedAt: 0
    property bool processing: false
    property int pending: 0
    property int ready: 0
    property string target: ""
    property string targetAddr: ""
    property string targetClass: ""
    property string lang: ""
    property string langPinned: ""
    property list<var> queue: []
}"""

BAR_FILE = "modules/ii/bar/BarContent.qml"
BAR_ANCHOR = "id: indicatorsRowLayout"
BAR_BLOCK = "                    DictateIndicator { Layout.alignment: Qt.AlignVCenter }"

STANDALONE_SRC = "standalone/shell.qml"
STANDALONE_DIR = "whisper-dictate"
WIRED_FILES = (SETTINGS_FILE, PERSIST_FILE, BAR_FILE)


def source(rel):
    for root in SOURCE_ROOTS:
        if (root / rel).is_file():
            return root / rel
    sys.exit(f"не найден исходник {rel}")


def strip_block(text):
    out, skipping = [], False
    for line in text.splitlines(keepends=True):
        if line.strip() == BEGIN:
            skipping = True
        elif line.strip() == END:
            skipping = False
        elif not skipping:
            out.append(line)
    return "".join(out)


def block_lines(block, indent):
    body = [indent + line if line else line for line in block.splitlines()]
    return [f"{indent}{BEGIN}\n"] + [line + "\n" for line in body] + [f"{indent}{END}\n"]


def find_anchor(lines, anchor, rel):
    hits = [i for i, line in enumerate(lines) if anchor in line]
    if len(hits) != 1:
        sys.exit(f"{rel}: якорь «{anchor}» найден {len(hits)} раз, ожидался 1. Версия Logical Impulse не совпадает.")
    return hits[0]


def insert_after_anchor(text, rel, anchor, block, indent=""):
    lines = text.splitlines(keepends=True)
    idx = find_anchor(lines, anchor, rel)
    return "".join(lines[: idx + 1] + block_lines(block, indent) + lines[idx + 1 :])


def insert_before_anchor(text, rel, anchor, block):
    lines = text.splitlines(keepends=True)
    idx = find_anchor(lines, anchor, rel)
    indent = lines[idx][: len(lines[idx]) - len(lines[idx].lstrip())]
    return "".join(lines[:idx] + block_lines(block, indent) + lines[idx:])


def insert_into_row(text, rel):
    lines = text.splitlines(keepends=True)
    idx = find_anchor(lines, BAR_ANCHOR, rel)
    spacing = next((i for i in range(idx, len(lines)) if lines[i].strip() == "spacing: 0"), None)
    if spacing is None:
        sys.exit(f"{rel}: после «{BAR_ANCHOR}» не найден «spacing: 0»")
    return "".join(lines[: spacing + 1] + block_lines(BAR_BLOCK.strip(), "                    ") + lines[spacing + 1 :])


def write_atomic(path, text):
    tmp = path.with_name(path.name + ".wd-tmp")
    tmp.write_text(text, encoding="utf-8")
    os.replace(tmp, path)


def ii_status(root):
    copies = all(
        (root / rel).is_file()
        and (root / rel).read_text(encoding="utf-8").startswith(MARK)
        for rel in II_COPIES
    )
    wired = all(BEGIN in (root / rel).read_text(encoding="utf-8") for rel in WIRED_FILES)
    return copies and wired


def ii_install(root):
    if not root.is_dir():
        sys.exit(f"Logical Impulse не найден: {root}")
    new_texts = {}
    for rel in WIRED_FILES:
        if not (root / rel).is_file():
            sys.exit(f"нет файла {root / rel}")
        new_texts[rel] = strip_block((root / rel).read_text(encoding="utf-8"))
    new_texts[SETTINGS_FILE] = insert_after_anchor(new_texts[SETTINGS_FILE], SETTINGS_FILE, SETTINGS_ANCHOR, SETTINGS_BLOCK, "        ")
    new_texts[PERSIST_FILE] = insert_before_anchor(new_texts[PERSIST_FILE], PERSIST_FILE, PERSIST_ANCHOR, PERSIST_BLOCK)
    new_texts[BAR_FILE] = insert_into_row(new_texts[BAR_FILE], BAR_FILE)

    for rel, src in II_COPIES.items():
        (root / rel).parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source(src), root / rel)
    for rel, text in new_texts.items():
        write_atomic(root / rel, text)


def ii_remove(root):
    for rel in WIRED_FILES:
        path = root / rel
        if path.is_file():
            write_atomic(path, strip_block(path.read_text(encoding="utf-8")))
    for rel in II_COPIES:
        path = root / rel
        if path.is_file():
            path.unlink()
            try:
                path.parent.rmdir()
            except OSError:
                pass


def standalone_status(root):
    return (root / "shell.qml").is_file()


def standalone_install(root):
    root.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source(STANDALONE_SRC), root / "shell.qml")


def standalone_remove(root):
    shutil.rmtree(root, ignore_errors=True)


def main():
    parser = argparse.ArgumentParser(description="Подключение модуля диктовки к Quickshell")
    parser.add_argument("target", choices=["ii", "standalone"])
    parser.add_argument("action", choices=["status", "install", "remove"])
    parser.add_argument("--dir", help="каталог конфигов Quickshell (по умолчанию ~/.config/quickshell)")
    args = parser.parse_args()

    qs_dir = Path(args.dir) if args.dir else Path(os.environ.get("XDG_CONFIG_HOME") or Path.home() / ".config") / "quickshell"
    if args.target == "ii":
        root, status, install, remove = qs_dir / "ii", ii_status, ii_install, ii_remove
    else:
        root, status, install, remove = qs_dir / STANDALONE_DIR, standalone_status, standalone_install, standalone_remove

    if args.action == "status":
        installed = status(root) if root.is_dir() else False
        print("установлено" if installed else "не установлено")
        sys.exit(0 if installed else 1)
    if args.action == "install":
        install(root)
        print(f"установлено: {root}")
    else:
        remove(root)
        print(f"удалено: {root}")


if __name__ == "__main__":
    main()
