#!/usr/bin/env python3
"""Модели OPUS-MT (Marian) для локального перевода: проверка, загрузка, движок.

Модели уже сконвертированы в CTranslate2 int8 и работают на процессоре через
local-translate.sh / marian-translate.py (провайдер «Локальный перевод»,
модель marian:opus-tc-big). Раскладка каталога та же, что ждёт marian-translate.py:

    <dir>/opus-tc-big/zle-en/   русский/украинский/белорусский -> английский
    <dir>/opus-tc-big/en-zle/   английский -> русский/украинский/белорусский
    <dir>/.venv/                python с ctranslate2 и sentencepiece

Использование:
    mt-models.py --dir DIR status
    mt-models.py --dir DIR download zle-en|en-zle
    mt-models.py --dir DIR engine

Во время загрузки печатаются строки «PROGRESS <процент>» — их читает GUI.
"""
import argparse
import os
import shutil
import subprocess
import sys
import urllib.request

FAMILY = "opus-tc-big"
# Ревизии закреплены: сменится репозиторий на HuggingFace — скачается то же самое.
MODELS = {
    "zle-en": ("luigi000/opus-mt-tc-big-zle-en-ct2-int8", "987aa3c46cf871ea683bcc7a540e3053d372cb71",
               "русский → английский"),
    "en-zle": ("NothingSoftware/opus-mt-tc-big-en-zle-ct2-int8", "60e35c8d683875ff7ead041d6b9c2ef69237e4e7",
               "английский → русский"),
}
FILES = ["config.json", "shared_vocabulary.json", "source.spm", "target.spm", "model.bin"]
BASE_URL = os.environ.get("WD_MT_BASE_URL", "https://huggingface.co")
ENGINE_PACKAGES = ["ctranslate2", "sentencepiece"]
# ctranslate2 выпускает колёса не под каждый свежий Python; через uv берём проверенный.
ENGINE_PYTHON = "3.12"


def model_dir(root, direction):
    return os.path.join(root, FAMILY, direction)


def installed(root, direction):
    path = model_dir(root, direction)
    return all(os.path.isfile(os.path.join(path, f)) and os.path.getsize(os.path.join(path, f)) > 0
               for f in FILES)


def venv_python(root):
    return os.path.join(root, ".venv", "bin", "python")


def engine_ok(root):
    py = venv_python(root)
    if not os.access(py, os.X_OK):
        return False
    probe = subprocess.run([py, "-c", "import ctranslate2, sentencepiece"],
                           capture_output=True, timeout=60)
    return probe.returncode == 0


def status(root):
    print(f"dir {root}")
    for direction, (_repo, _rev, title) in MODELS.items():
        print(f"{direction} {'ok' if installed(root, direction) else 'missing'} {title}")
    print(f"engine {'ok' if engine_ok(root) else 'missing'}")
    return 0


def fetch(url, dest, done, total):
    request = urllib.request.Request(url, headers={"User-Agent": "nata-mt-models"})
    with urllib.request.urlopen(request, timeout=60) as resp, open(dest, "wb") as out:
        expected = resp.headers.get("Content-Length")
        got = 0
        while True:
            chunk = resp.read(1 << 20)
            if not chunk:
                break
            out.write(chunk)
            got += len(chunk)
            if total:
                print(f"PROGRESS {min(99, (done + got) * 100 // total)}", flush=True)
    if expected and int(expected) != got:
        raise OSError(f"{os.path.basename(dest)}: получено {got} из {expected} байт")
    return got


def remote_size(url):
    request = urllib.request.Request(url, method="HEAD", headers={"User-Agent": "nata-mt-models"})
    try:
        with urllib.request.urlopen(request, timeout=60) as resp:
            # HuggingFace отдаёт размер файла из LFS/Xet в X-Linked-Size, до редиректа.
            return int(resp.headers.get("X-Linked-Size") or resp.headers.get("Content-Length") or 0)
    except (OSError, ValueError):
        return 0


def download(root, direction):
    repo, rev, title = MODELS[direction]
    final = model_dir(root, direction)
    if installed(root, direction):
        print(f"Модель {direction} ({title}) уже скачана: {final}")
        return 0
    tmp = final + ".part"
    shutil.rmtree(tmp, ignore_errors=True)
    os.makedirs(tmp, exist_ok=True)
    urls = {f: f"{BASE_URL}/{repo}/resolve/{rev}/{f}" for f in FILES}
    total = sum(remote_size(u) for u in urls.values()) if BASE_URL.startswith("http") else 0
    print(f"Скачиваю {direction} ({title}) из {repo}", flush=True)
    done = 0
    try:
        for name, url in urls.items():
            done += fetch(url, os.path.join(tmp, name), done, total)
    except OSError as err:
        shutil.rmtree(tmp, ignore_errors=True)
        print(f"Загрузка не удалась: {err}", file=sys.stderr)
        return 1
    shutil.rmtree(final, ignore_errors=True)
    os.rename(tmp, final)
    print("PROGRESS 100", flush=True)
    print(f"Модель {direction} скачана: {final}")
    return 0


def engine(root):
    if engine_ok(root):
        print(f"Движок перевода уже установлен: {venv_python(root)}")
        return 0
    venv = os.path.join(root, ".venv")
    os.makedirs(root, exist_ok=True)
    shutil.rmtree(venv, ignore_errors=True)
    uv = shutil.which("uv")
    if uv:
        steps = [[uv, "venv", "--python", ENGINE_PYTHON, venv],
                 [uv, "pip", "install", "--python", venv_python(root), *ENGINE_PACKAGES]]
    else:
        steps = [[sys.executable, "-m", "venv", venv],
                 [venv_python(root), "-m", "pip", "install", *ENGINE_PACKAGES]]
    print("Устанавливаю ctranslate2 и sentencepiece в " + venv, flush=True)
    for i, cmd in enumerate(steps, 1):
        proc = subprocess.run(cmd, capture_output=True, text=True)
        if proc.returncode != 0:
            print((proc.stdout + proc.stderr).strip()[-2000:], file=sys.stderr)
            print("Установка движка не удалась.", file=sys.stderr)
            return 1
        print(f"PROGRESS {i * 100 // len(steps)}", flush=True)
    if not engine_ok(root):
        print("Движок установлен, но не импортируется.", file=sys.stderr)
        return 1
    print("Движок перевода установлен.")
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--dir", required=True)
    sub = parser.add_subparsers(dest="cmd", required=True)
    sub.add_parser("status")
    dl = sub.add_parser("download")
    dl.add_argument("direction", choices=sorted(MODELS))
    sub.add_parser("engine")
    args = parser.parse_args()
    root = os.path.expanduser(args.dir)
    if args.cmd == "status":
        return status(root)
    if args.cmd == "download":
        return download(root, args.direction)
    return engine(root)


if __name__ == "__main__":
    sys.exit(main())
