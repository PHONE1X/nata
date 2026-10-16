#!/usr/bin/env python3
"""Диагностика и лечение дублей секрета в libsecret.

Проблема: `secret-tool store` заменяет только запись с ТОЧНО такими же
атрибутами. Если приложение (Quickshell/ii) создало запись с лишним атрибутом,
а наши скрипты пишут без него, в кейринге копятся параллельные записи
с одним и тем же application=..., и `secret-tool lookup` отдаёт любую из них.

Использование:
    keyring-doctor.py [--app APP] doctor [--fix [--yes]]   отчёт / слить в одну запись
    keyring-doctor.py [--app APP] set NAME                 значение со stdin, слияние под flock
    keyring-doctor.py [--app APP] unset NAME

Записи пишутся с теми же атрибутами и меткой, что у самой свежей существующей
(так делает и Quickshell/ii: application + explanation) — иначе каждая запись
с другим набором атрибутов становилась бы параллельным дублем.

Значения секретов никогда не печатаются — только имена ключей и счётчики.
Лечение: резервная копия (0600) -> слияние (новее побеждает, пустое не
затирает непустое) -> secret-tool clear -> одна запись -> проверка; при сбое
восстанавливается самая свежая запись из копии.
"""

import argparse
import fcntl
import json
import os
import re
import subprocess
import sys
import tempfile
import time

DEFAULT_LABEL = "illogical-impulse Safe Storage"
DEFAULT_EXPLANATION = "For storing API keys and other sensitive information"
FIELD_RE = re.compile(r"^(label|created|modified|schema|attribute\.\S+) = ")
BLOCK_RE = re.compile(r"^\[(/[^\]]*)\]$")


def run(args, stdin=None):
    return subprocess.run(args, input=stdin, capture_output=True, text=True)


def parse_items(text):
    """Разбор вывода `secret-tool search --all`. Секрет может быть многострочным."""
    items, cur, in_secret = [], None, False
    for line in text.splitlines():
        m = BLOCK_RE.match(line)
        if m:
            if cur:
                items.append(cur)
            cur, in_secret = {"path": m.group(1), "secret": "", "attrs": {}}, False
            continue
        if cur is None:
            continue
        if line.startswith("secret = "):
            cur["secret"], in_secret = line[len("secret = "):], True
            continue
        fm = FIELD_RE.match(line)
        if fm:
            in_secret = False
            k, _, v = line.partition(" = ")
            if k.startswith("attribute."):
                cur["attrs"][k[len("attribute."):]] = v
            else:
                cur[k] = v
        elif in_secret:
            cur["secret"] += "\n" + line
    if cur:
        items.append(cur)
    return items


def fetch(app):
    r = run(["secret-tool", "search", "--all", "application", app])
    if r.returncode not in (0, 1):
        sys.exit("secret-tool search не удался (кейринг заблокирован?)")
    items = parse_items(r.stdout)
    items.sort(key=lambda i: i.get("modified", ""))
    return items


def load_json(item):
    try:
        v = json.loads(item["secret"])
        return v if isinstance(v, dict) else None
    except ValueError:
        return None


def merge(items):
    """Старые первыми, новые перекрывают; пустая строка не затирает значение."""
    out = {"apiKeys": {}}
    for it in items:
        d = load_json(it)
        if d is None:
            continue
        for k, v in d.items():
            if k == "apiKeys" and isinstance(v, dict):
                for name, val in v.items():
                    if val in ("", None) and out["apiKeys"].get(name) not in ("", None):
                        continue
                    out["apiKeys"][name] = val
            elif v not in ("", None) or k not in out:
                out[k] = v
    return out


def report(items):
    print(f"Записей с этим application: {len(items)}")
    for n, it in enumerate(items, 1):
        d = load_json(it)
        extra = {k: v for k, v in it["attrs"].items() if k != "application"}
        names = sorted(d.get("apiKeys", {})) if d is not None else None
        desc = f"{len(names)} ключ(ей)" if names is not None else "не JSON"
        print(f"  #{n} {it['path']} изменена {it.get('modified', '?')}, {desc}"
              + (f", доп. атрибуты: {','.join(sorted(extra))}" if extra else ""))
    keyed = {}
    for it in items:
        d = load_json(it) or {}
        for name, val in d.get("apiKeys", {}).items():
            keyed.setdefault(name, []).append(val)
    conflicts = sorted(n for n, vs in keyed.items() if len({json.dumps(v) for v in vs if v not in ("", None)}) > 1)
    newest = set((load_json(items[-1]) or {}).get("apiKeys", {}))
    stale = sorted(n for n in keyed if n not in newest)
    if stale:
        print("Есть только в старых записях (при слиянии вернутся): " + ", ".join(stale))
    if conflicts:
        print("Ключи с разными значениями в разных записях (победит самая новая): " + ", ".join(conflicts))
    return len(items) > 1


def lock_path():
    base = os.environ.get("XDG_RUNTIME_DIR") or tempfile.gettempdir()
    return os.path.join(base, "whisper-dictate-keyring.lock")


def canonical(app, items):
    """Атрибуты и метка, с которыми записывать, чтобы заменить существующую запись."""
    if items:
        newest = items[-1]
        return newest.get("label") or DEFAULT_LABEL, dict(newest["attrs"])
    return DEFAULT_LABEL, {"application": app, "explanation": DEFAULT_EXPLANATION}


def store(label, attrs, payload):
    args = ["secret-tool", "store", f"--label={label}"]
    for k, v in attrs.items():
        args += [k, v]
    return run(args, stdin=payload)


def lookup(app):
    return run(["secret-tool", "lookup", "application", app]).stdout


def fix(app, items, assume_yes):
    merged = merge(items)
    if not assume_yes:
        ans = input(f"Слить {len(items)} записей в одну ({len(merged['apiKeys'])} ключей)? [y/N] ")
        if ans.strip().lower() not in ("y", "yes", "д", "да"):
            print("Отменено.")
            return 1
    state = os.path.join(os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state"), "whisper-dictate")
    os.makedirs(state, mode=0o700, exist_ok=True)
    backup = os.path.join(state, f"keyring-backup-{time.strftime('%Y%m%d-%H%M%S')}.json")
    fd = os.open(backup, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump([{"attrs": i["attrs"], "label": i.get("label"), "modified": i.get("modified"), "secret": i["secret"]}
                   for i in items], f)
    print(f"Резервная копия (0600, содержит секреты): {backup}")
    payload = json.dumps(merged, ensure_ascii=False)
    with open(lock_path(), "w") as lk:
        fcntl.flock(lk, fcntl.LOCK_EX)
        label, attrs = canonical(app, items)
        run(["secret-tool", "clear", "application", app])
        r = store(label, attrs, payload)
        ok = r.returncode == 0 and (load_json({"secret": lookup(app)}) == merged)
        if not ok:
            store(label, attrs, items[-1]["secret"])
            print("Проверка не прошла — восстановлена самая свежая прежняя запись.", file=sys.stderr)
            return 1
    print(f"Готово: одна запись, {len(merged['apiKeys'])} ключей.")
    return 0


def locked_update(app, mutate):
    with open(lock_path(), "w") as lk:
        fcntl.flock(lk, fcntl.LOCK_EX)
        items = fetch(app)
        merged = merge(items) if items else {"apiKeys": {}}
        merged.setdefault("apiKeys", {})
        mutate(merged)
        label, attrs = canonical(app, items)
        r = store(label, attrs, json.dumps(merged, ensure_ascii=False))
        if r.returncode != 0:
            sys.exit("secret-tool store не удался")
        if len(items) > 1:
            print("Предупреждение: в кейринге дубли записей — whisper-dictate-setup doctor --fix", file=sys.stderr)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--app", default=os.environ.get("DICTATE_KEYRING_APP", "illogical-impulse"))
    sub = ap.add_subparsers(dest="cmd")
    d = sub.add_parser("doctor")
    d.add_argument("--fix", action="store_true")
    d.add_argument("--yes", action="store_true")
    sub.add_parser("set").add_argument("name")
    sub.add_parser("unset").add_argument("name")
    a = ap.parse_args()

    if a.cmd == "set":
        value = sys.stdin.read().rstrip("\n")
        if not value:
            sys.exit("пустое значение со stdin — ничего не записано")
        locked_update(a.app, lambda m: m["apiKeys"].__setitem__(a.name, value))
        print(f"Ключ '{a.name}' сохранён.")
        return 0
    if a.cmd == "unset":
        locked_update(a.app, lambda m: m["apiKeys"].pop(a.name, None))
        print(f"Ключ '{a.name}' удалён.")
        return 0

    fixing = a.cmd == "doctor" and a.fix
    items = fetch(a.app)
    if not items:
        print("В кейринге записей нет.")
        return 0
    dupes = report(items)
    if not fixing:
        if dupes:
            print("Лечение: whisper-dictate-setup doctor --fix")
        return 3 if dupes else 0
    if not dupes:
        print("Дублей нет, лечить нечего.")
        return 0
    return fix(a.app, items, a.yes)


if __name__ == "__main__":
    sys.exit(main())
