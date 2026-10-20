#!/usr/bin/env python3
"""Движки whisper-dictate: ускоритель whisper, модели whisper, Ollama, облачные модели.

    engines.py gpu
    engines.py accel status | install vulkan|hip|cuda
    engines.py whisper --dir DIR status | download NAME
    engines.py ollama status | install vulkan|rocm|cuda|cpu | pull NAME
    engines.py stt-models [--refresh]

Пакеты ставятся через pkexec (окно пароля системы). WD_PKEXEC подменяет его в
тестах, WD_GGML_DIR — каталог бэкендов ggml. Длинные операции печатают
«PROGRESS <процент>».
"""
import argparse
import glob
import json
import os
import subprocess
import sys
import time
import urllib.request

from wd_net import fetch_file, hf_url

GGML_DIR = os.environ.get("WD_GGML_DIR", "/usr/lib/ggml")
# Ускорители whisper.cpp: пакет ggml-<имя> кладёт libggml-<имя>.so в GGML_DIR.
ACCELS = {
    "vulkan": ("ggml-vulkan", "Vulkan — AMD, Intel и NVIDIA, ставится быстро"),
    "hip": ("ggml-hip", "ROCm (HIP) — только AMD, тянет ROCm на несколько ГБ"),
    "cuda": ("ggml-cuda", "CUDA — только NVIDIA, тянет CUDA на несколько ГБ"),
}
VENDORS = {"0x1002": "amd", "0x10de": "nvidia", "0x8086": "intel"}
RECOMMENDED = {"amd": "vulkan", "intel": "vulkan", "nvidia": "cuda"}

WHISPER_REPO = ("ggerganov/whisper.cpp", "main")
# имя файла -> (размер в байтах, описание); размер же служит проверкой целостности.
WHISPER_MODELS = {
    "ggml-large-v3-turbo.bin": (1624555275, "large-v3-turbo — лучший выбор: точно и быстро"),
    "ggml-large-v3-turbo-q5_0.bin": (574041195, "large-v3-turbo q5 — почти так же точно, втрое меньше"),
    "ggml-large-v3.bin": (3095033483, "large-v3 — самая точная, медленнее"),
    "ggml-medium.bin": (1533763059, "medium"),
    "ggml-small.bin": (487601967, "small — для слабых машин"),
    "ggml-base.bin": (147951465, "base — быстро, но много ошибок"),
    "ggml-tiny.bin": (77691713, "tiny — только для проверки"),
}
VAD_MODEL = ("ggml-org/whisper-vad", "main", "ggml-silero-v5.1.2.bin", 885098)

OLLAMA_URL = os.environ.get("OLLAMA_HOST") or "http://localhost:11434"
if not OLLAMA_URL.startswith("http"):
    OLLAMA_URL = "http://" + OLLAMA_URL
OLLAMA_VARIANTS = {"vulkan": "ollama-vulkan", "rocm": "ollama-rocm", "cuda": "ollama-cuda", "cpu": None}

STT_URL = "https://openrouter.ai/api/v1/models?output_modalities=transcription"
STT_CACHE = os.path.join(os.environ.get("XDG_CACHE_HOME") or os.path.expanduser("~/.cache"),
                         "whisper-dictate", "stt-models.json")
STT_FALLBACK = ["openai/gpt-4o-transcribe", "openai/gpt-4o-mini-transcribe",
                "openai/whisper-large-v3-turbo", "openai/whisper-large-v3"]


def gpu_vendor():
    for path in sorted(glob.glob("/sys/class/drm/card*/device/vendor")):
        try:
            vendor = VENDORS.get(open(path).read().strip())
        except OSError:
            continue
        if vendor:
            return vendor
    return "none"


def pkg_installed(name):
    return subprocess.run(["pacman", "-Q", name], capture_output=True).returncode == 0


def as_root(cmd):
    """Команда от root: pkexec покажет окно пароля (агент polkit сессии)."""
    if os.geteuid() == 0:
        full = cmd
    else:
        full = [os.environ.get("WD_PKEXEC") or "pkexec", *cmd]
    print("Запуск: " + " ".join(cmd), flush=True)
    proc = subprocess.run(full, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    for line in proc.stdout.splitlines()[-15:]:
        print(line)
    if proc.returncode in (126, 127) and full[0].endswith("pkexec"):
        print("Пароль не введён или нет агента polkit.", file=sys.stderr)
    return proc.returncode


def cmd_gpu(_args):
    vendor = gpu_vendor()
    print(f"gpu {vendor}")
    print(f"recommended {RECOMMENDED.get(vendor, 'cpu')}")
    return 0


def cmd_accel(args):
    if args.action == "status":
        for name, (_pkg, title) in ACCELS.items():
            ok = os.path.exists(os.path.join(GGML_DIR, f"libggml-{name}.so"))
            print(f"{name} {'ok' if ok else 'missing'} {title}")
        return 0
    pkg = ACCELS[args.name][0]
    return as_root(["pacman", "-S", "--needed", "--noconfirm", pkg])


def cmd_whisper(args):
    root = os.path.expanduser(args.dir)
    items = {**WHISPER_MODELS, VAD_MODEL[2]: (VAD_MODEL[3], "VAD (обрезка тишины)")}
    if args.action == "status":
        print(f"dir {root}")
        for name, (size, title) in items.items():
            path = os.path.join(root, name)
            ok = os.path.isfile(path) and os.path.getsize(path) == size
            print(f"{name} {'ok' if ok else 'missing'} {size} {title}")
        return 0
    if args.name not in items:
        print(f"Неизвестная модель: {args.name}", file=sys.stderr)
        return 2
    size = items[args.name][0]
    dest = os.path.join(root, args.name)
    if os.path.isfile(dest) and os.path.getsize(dest) == size:
        print(f"Уже скачано: {dest}")
        return 0
    repo, rev = (VAD_MODEL[0], VAD_MODEL[1]) if args.name == VAD_MODEL[2] else WHISPER_REPO
    print(f"Скачиваю {args.name} ({size // 1000000} МБ) в {root}", flush=True)
    try:
        fetch_file(hf_url(repo, rev, args.name), dest, size)
    except OSError as err:
        print(f"Загрузка не удалась: {err}", file=sys.stderr)
        return 1
    print(f"Скачано: {dest}")
    return 0


def ollama_api(path, body=None, timeout=10):
    data = json.dumps(body).encode() if body is not None else None
    request = urllib.request.Request(OLLAMA_URL + path, data=data,
                                     headers={"Content-Type": "application/json"})
    return urllib.request.urlopen(request, timeout=timeout)


def cmd_ollama(args):
    if args.action == "status":
        print(f"installed {'yes' if pkg_installed('ollama') else 'no'}")
        for variant, pkg in OLLAMA_VARIANTS.items():
            if pkg:
                print(f"variant {variant} {'ok' if pkg_installed(pkg) else 'missing'}")
        try:
            with ollama_api("/api/tags", timeout=5) as resp:
                models = json.load(resp).get("models", [])
            print("service up")
            for m in models:
                print(f"model {m['name']} {m.get('size', 0)}")
        except (OSError, ValueError):
            print("service down")
        return 0
    if args.action == "install":
        pkgs = ["ollama"] + ([OLLAMA_VARIANTS[args.name]] if OLLAMA_VARIANTS[args.name] else [])
        script = (f"pacman -S --needed --noconfirm {' '.join(pkgs)} && "
                  "systemctl enable --now ollama.service")
        return as_root(["sh", "-c", script])
    print(f"Скачиваю в Ollama: {args.name}", flush=True)
    try:
        with ollama_api("/api/pull", {"model": args.name, "stream": True}, timeout=3600) as resp:
            last = -1
            for raw in resp:
                event = json.loads(raw)
                if event.get("error"):
                    print(f"Ollama: {event['error']}", file=sys.stderr)
                    return 1
                total, done = event.get("total"), event.get("completed")
                if total and done is not None:
                    pct = min(99, done * 100 // total)
                    if pct != last:
                        print(f"PROGRESS {pct}", flush=True)
                        last = pct
                elif event.get("status") and event["status"] != "success":
                    print(event["status"], flush=True)
    except (OSError, ValueError) as err:
        print(f"Ollama не отвечает на {OLLAMA_URL}: {err}", file=sys.stderr)
        return 1
    print("PROGRESS 100")
    print(f"Модель {args.name} скачана.")
    return 0


def price_per_minute(pricing):
    # Аудиомодели OpenRouter берут плату за секунду (prompt); у gpt-4o-* — за токены.
    try:
        if float(pricing.get("completion") or 0) > 0:
            return "по токенам"
        per_min = float(pricing.get("prompt") or 0) * 60
    except (TypeError, ValueError):
        return ""
    return f"${per_min:.4f}/мин" if 0 < per_min < 1 else ""


def cmd_stt_models(args):
    data = None
    fresh = os.path.isfile(STT_CACHE) and time.time() - os.path.getmtime(STT_CACHE) < 86400
    if args.refresh or not fresh:
        try:
            with urllib.request.urlopen(urllib.request.Request(STT_URL, headers={"User-Agent": "nata"}),
                                        timeout=20) as resp:
                data = json.load(resp)["data"]
            os.makedirs(os.path.dirname(STT_CACHE), exist_ok=True)
            with open(STT_CACHE, "w") as out:
                json.dump(data, out)
        except (OSError, ValueError, KeyError):
            data = None
    if data is None and os.path.isfile(STT_CACHE):
        try:
            data = json.load(open(STT_CACHE))
        except (OSError, ValueError):
            data = None
    if data is None:
        for model in STT_FALLBACK:
            print(f"{model}\t{model}\t")
        return 0
    for m in sorted(data, key=lambda m: m["id"]):
        print(f"{m['id']}\t{m.get('name') or m['id']}\t{price_per_minute(m.get('pricing') or {})}")
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="cmd", required=True)
    sub.add_parser("gpu")
    accel = sub.add_parser("accel").add_subparsers(dest="action", required=True)
    accel.add_parser("status")
    accel.add_parser("install").add_argument("name", choices=sorted(ACCELS))
    wp = sub.add_parser("whisper")
    wp.add_argument("--dir", required=True)
    whisper = wp.add_subparsers(dest="action", required=True)
    whisper.add_parser("status")
    whisper.add_parser("download").add_argument("name")
    ollama = sub.add_parser("ollama").add_subparsers(dest="action", required=True)
    ollama.add_parser("status")
    ollama.add_parser("install").add_argument("name", choices=sorted(OLLAMA_VARIANTS))
    ollama.add_parser("pull").add_argument("name")
    sub.add_parser("stt-models").add_argument("--refresh", action="store_true")
    args = parser.parse_args()
    handlers = {"gpu": cmd_gpu, "accel": cmd_accel, "whisper": cmd_whisper,
                "ollama": cmd_ollama, "stt-models": cmd_stt_models}
    return handlers[args.cmd](args)


if __name__ == "__main__":
    sys.exit(main())
