#!/usr/bin/env python3
"""Управляемый блок бинда whisper-dictate в конфиге Hyprland (Lua или .conf).

    hypr-bind.py apply  [--key "SUPER + U"] [--file F] [--cmd whisper-dictate]
                        [--force] [--replace-legacy] [--dry-run] [--no-live]
    hypr-bind.py remove [--file F]
    hypr-bind.py status [--file F]

Блок ограничен маркерами и переписывается целиком, остальной файл не
трогается. Перед записью ищется конфликт: тот же аккорд, уже занятый другим
биндом в целевом файле или в любом *.lua/*.conf рядом (~/.config/hypr), а при
работающем Hyprland — ещё и в `hyprctl binds -j`. Старый бинд на dictate.fish /
whisper-dictate вне блока тоже считается конфликтом (двойной вызов
переключателя = запись стартует и тут же останавливается); --replace-legacy
закомментирует такую строку.

Коды возврата: 0 — готово, 2 — конфликт (файл не тронут), 1 — ошибка.
"""

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import time

HYPR_DIR = os.path.expanduser(os.environ.get("HYPR_CONFIG_DIR", "~/.config/hypr"))
BEGIN = "{c} >>> whisper-dictate (managed block, edit via whisper-dictate-setup) >>>"
END = "{c} <<< whisper-dictate <<<"
CANDIDATES = ["custom/keybinds.lua", "hyprland.lua", "custom/keybinds.conf", "hyprland.conf"]
MOD_ALIASES = {
    "SUPER": "SUPER", "WIN": "SUPER", "META": "SUPER", "LOGO": "SUPER", "MOD4": "SUPER",
    "CTRL": "CTRL", "CONTROL": "CTRL",
    "ALT": "ALT", "MOD1": "ALT",
    "SHIFT": "SHIFT",
}
MASKS = {"SHIFT": 1, "CTRL": 4, "ALT": 8, "SUPER": 64}
LEGACY_RE = re.compile(r"dictate\.fish|whisper-dictate")
LUA_BIND = re.compile(r'^\s*hl\.bind\(\s*"([^"]+)"\s*,(.*)$')
CONF_BIND = re.compile(r"^\s*bind[a-z]*\s*=\s*(.*)$")


def normalize(combo, sep):
    toks = [t.strip().upper() for t in re.split(sep, combo) if t.strip()]
    mods, key = set(), None
    for t in toks:
        if t in MOD_ALIASES:
            mods.add(MOD_ALIASES[t])
        else:
            for part in t.split():
                if part in MOD_ALIASES:
                    mods.add(MOD_ALIASES[part])
                else:
                    key = part
    return frozenset(mods), key


def default_file():
    for c in CANDIDATES:
        p = os.path.join(HYPR_DIR, c)
        if os.path.isfile(p):
            return p
    return None


def is_lua(path):
    return path.endswith(".lua")


def comment(path):
    return "--" if is_lua(path) else "#"


def split_block(lines, path):
    """-> (before, block_lines or None, after)."""
    c = comment(path)
    b, e = BEGIN.format(c=c), END.format(c=c)
    try:
        i = next(n for n, l in enumerate(lines) if l.strip() == b)
        j = next(n for n, l in enumerate(lines) if n > i and l.strip() == e)
    except StopIteration:
        return lines, None, []
    return lines[:i], lines[i:j + 1], lines[j + 1:]


def scan_files(target):
    files = {os.path.realpath(target)}
    if os.path.isdir(HYPR_DIR):
        for root, _, names in os.walk(HYPR_DIR):
            for n in names:
                if n.endswith((".lua", ".conf")) and ".bak" not in n and ".disabled" not in n:
                    files.add(os.path.realpath(os.path.join(root, n)))
    return sorted(files)


def find_binds(path, want):
    """Строки с биндом на аккорд `want` вне нашего блока."""
    try:
        lines = open(path, encoding="utf-8").read().split("\n")
    except OSError:
        return []
    before, _, after = split_block(lines, path)
    offset_after = len(lines) - len(after)
    hits = []
    for idx, line in enumerate(lines):
        if before is not lines and idx >= len(before) and idx < offset_after:
            continue
        stripped = line.lstrip()
        if stripped.startswith(("--", "#")):
            continue
        if is_lua(path):
            m = LUA_BIND.match(line)
            if m and normalize(m.group(1), r"\+") == want:
                hits.append((idx + 1, line.strip(), bool(LEGACY_RE.search(m.group(2)))))
        else:
            m = CONF_BIND.match(line)
            if m:
                parts = [p.strip() for p in m.group(1).split(",")]
                if len(parts) >= 2 and normalize(parts[0] + " " + parts[1], r"[\s]+") == want:
                    hits.append((idx + 1, line.strip(), bool(LEGACY_RE.search(m.group(1)))))
    return hits


def live_conflicts(want, use_live):
    if not use_live or not os.environ.get("HYPRLAND_INSTANCE_SIGNATURE"):
        return []
    try:
        out = subprocess.run(["hyprctl", "binds", "-j"], capture_output=True, text=True, timeout=5).stdout
        binds = json.loads(out)
    except Exception:
        return []
    mods, key = want
    mask = sum(MASKS[m] for m in mods)
    res = []
    for b in binds:
        if int(b.get("modmask", -1)) == mask and str(b.get("key", "")).upper() == key:
            text = f"{b.get('dispatcher', '')} {b.get('arg', '')}"
            if not LEGACY_RE.search(text):
                res.append(text.strip())
    return res


def make_block(path, key, cmd):
    c = comment(path)
    if is_lua(path):
        body = f'hl.bind("{key}", hl.dsp.exec_cmd("{cmd}"), {{ description = "Whisper Dictate: голосовой ввод" }})'
    else:
        mods, k = normalize(key, r"\+")
        body = f"bind = {' '.join(sorted(mods))}, {k}, exec, {cmd}"
    return [BEGIN.format(c=c), body, END.format(c=c)]


def write_atomic(path, text):
    mode = os.stat(path).st_mode & 0o777 if os.path.exists(path) else 0o644
    tmp = f"{path}.wd-tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(text)
    os.chmod(tmp, mode)
    os.replace(tmp, path)


def backup(path):
    if os.path.exists(path):
        dst = f"{path}.bak_whisper-dictate_{time.strftime('%Y%m%d-%H%M%S')}"
        shutil.copy2(path, dst)
        return dst


def cmd_apply(a):
    path = a.file or default_file()
    if not path:
        print("Не найден конфиг Hyprland; укажите --file", file=sys.stderr)
        return 1
    path = os.path.expanduser(path)
    want = normalize(a.key, r"\+" if "+" in a.key else r"[,\s]+")
    if not want[1]:
        print(f"Не удалось разобрать аккорд: {a.key}", file=sys.stderr)
        return 1

    conflicts, legacy = [], []
    for f in scan_files(path):
        for ln, text, is_leg in find_binds(f, want):
            (legacy if is_leg else conflicts).append((f, ln, text))
    for text in live_conflicts(want, not a.no_live):
        conflicts.append(("hyprctl binds", 0, text))

    if conflicts and not a.force:
        print(f"Аккорд {a.key} уже занят:")
        for f, ln, text in conflicts:
            print(f"  {f}:{ln}: {text}" if ln else f"  [{f}] {text}")
        print("Выберите другой аккорд или повторите с --force.")
        return 2
    if legacy and not a.replace_legacy:
        print(f"Аккорд {a.key} уже вызывает старый dictate.fish (двойной вызов сломает переключатель):")
        for f, ln, text in legacy:
            print(f"  {f}:{ln}: {text}")
        print("Повторите с --replace-legacy, чтобы закомментировать старую строку.")
        return 2

    text = open(path, encoding="utf-8").read() if os.path.exists(path) else ""
    lines = text.split("\n")
    if lines and lines[-1] == "":
        lines.pop()

    if legacy and a.replace_legacy:
        c = comment(path)
        for f, ln, _ in legacy:
            if os.path.realpath(f) == os.path.realpath(path):
                lines[ln - 1] = f"{c} [whisper-dictate: заменено] {lines[ln - 1]}"
            elif not a.dry_run:
                other = open(f, encoding="utf-8").read().split("\n")
                other[ln - 1] = f"{comment(f)} [whisper-dictate: заменено] {other[ln - 1]}"
                backup(f)
                write_atomic(f, "\n".join(other))

    before, old, after = split_block(lines, path)
    block = make_block(path, a.key, a.cmd)
    new_lines = (before + block + after) if old is not None else (lines + ([""] if lines else []) + block)
    new_text = "\n".join(new_lines) + "\n"
    if a.dry_run:
        print("\n".join(block))
        return 0
    if new_text == text:
        print(f"Уже настроено: {path}")
        return 0
    os.makedirs(os.path.dirname(path), exist_ok=True)
    bak = backup(path)
    write_atomic(path, new_text)
    print(f"Бинд {a.key} записан в {path}" + (f" (копия: {bak})" if bak else ""))
    return 0


def cmd_remove(a):
    path = os.path.expanduser(a.file) if a.file else default_file()
    if not path or not os.path.exists(path):
        print("Файл не найден")
        return 1
    lines = open(path, encoding="utf-8").read().split("\n")
    before, old, after = split_block(lines, path)
    if old is None:
        print("Управляемого блока нет.")
        return 0
    while before and before[-1] == "":
        before.pop()
    backup(path)
    write_atomic(path, "\n".join(before + ([""] if after and after != [""] else []) + after).rstrip("\n") + "\n")
    print(f"Блок удалён из {path}")
    return 0


def cmd_status(a):
    path = os.path.expanduser(a.file) if a.file else default_file()
    if not path or not os.path.exists(path):
        print("Конфиг Hyprland не найден.")
        return 1
    lines = open(path, encoding="utf-8").read().split("\n")
    _, old, _ = split_block(lines, path)
    if old is None:
        print(f"Блок whisper-dictate в {path} не настроен.")
        return 1
    print(f"Блок установлен в {path}:")
    print("\n".join("  " + l for l in old[1:-1]))
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="action", required=True)
    ap1 = sub.add_parser("apply")
    ap1.add_argument("--key", default="SUPER + U")
    ap1.add_argument("--cmd", default="whisper-dictate")
    ap1.add_argument("--force", action="store_true")
    ap1.add_argument("--replace-legacy", action="store_true")
    ap1.add_argument("--dry-run", action="store_true")
    ap1.add_argument("--no-live", action="store_true")
    sub.add_parser("remove")
    sub.add_parser("status")
    for p in sub.choices.values():
        p.add_argument("--file")
    a = ap.parse_args()
    return {"apply": cmd_apply, "remove": cmd_remove, "status": cmd_status}[a.action](a)


if __name__ == "__main__":
    sys.exit(main())
