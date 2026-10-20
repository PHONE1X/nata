"""Загрузка файлов с прогрессом для whisper-dictate (модели whisper, VAD, OPUS-MT).

Прогресс печатается строками «PROGRESS <процент>» — их читает GUI.
WD_HF_BASE_URL подменяет https://huggingface.co (тесты кладут туда file://).
"""
import os
import urllib.request

BASE_URL = os.environ.get("WD_HF_BASE_URL") or os.environ.get("WD_MT_BASE_URL") or "https://huggingface.co"
AGENT = {"User-Agent": "nata-whisper-dictate"}


def hf_url(repo, rev, name):
    return f"{BASE_URL}/{repo}/resolve/{rev}/{name}"


def remote_size(url):
    if not url.startswith("http"):
        return 0
    request = urllib.request.Request(url, method="HEAD", headers=AGENT)
    try:
        with urllib.request.urlopen(request, timeout=60) as resp:
            # HuggingFace отдаёт размер файла из LFS/Xet в X-Linked-Size, до редиректа.
            return int(resp.headers.get("X-Linked-Size") or resp.headers.get("Content-Length") or 0)
    except (OSError, ValueError):
        return 0


def fetch(url, dest, done=0, total=0):
    """Скачивает url в dest; возвращает число байт. done/total — для общего процента."""
    request = urllib.request.Request(url, headers=AGENT)
    last = -1
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
                pct = min(99, (done + got) * 100 // total)
                if pct != last:
                    print(f"PROGRESS {pct}", flush=True)
                    last = pct
    if expected and int(expected) != got:
        raise OSError(f"{os.path.basename(dest)}: получено {got} из {expected} байт")
    return got


def fetch_file(url, dest, size=0):
    """Один файл: качаем в dest.part, после проверки размера переименовываем."""
    os.makedirs(os.path.dirname(dest) or ".", exist_ok=True)
    tmp = dest + ".part"
    total = size or remote_size(url)
    try:
        got = fetch(url, tmp, 0, total)
        if size and got != size:
            raise OSError(f"{os.path.basename(dest)}: получено {got} из {size} байт")
    except BaseException:
        if os.path.exists(tmp):
            os.remove(tmp)
        raise
    os.replace(tmp, dest)
    print("PROGRESS 100", flush=True)
