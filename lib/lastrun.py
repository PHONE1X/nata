#!/usr/bin/env python3
"""Последний запуск диктовки: где распознавали, сколько заняло, почему облако отказало.

    lastrun.py [--log PATH]

Читает журнал диктовки (по умолчанию ~/.local/state/dictate/dictate.log) и
печатает строки «поле\tзначение»:

    when     время последнего задания
    stt      как распознавали: local | cloud:МОДЕЛЬ | local(cloud failed) | ...
    mode     local | cloud | mixed
    model    облачная модель, если она участвовала
    reason   почему облако отказало (http-код и текст ошибки)
    audio    длительность речи, секунды
    whisper  время распознавания, секунды
    total    всё задание, секунды
    lang     язык
    text     коротко по-русски, для показа в окне
"""
import argparse
import os
import re
import sys

DEFAULT_LOG = "~/.local/state/dictate/dictate.log"
TIMING = re.compile(
    r"TIMING:\s*audio\s+(?P<audio>[\d.]+)s\s*\|\s*whisper\s+(?P<whisper>[\d.]+)s"
    r"(?:\s*\((?P<rate>[\d.]+)x[^\)]*\))?\s*\|\s*translate\s+(?P<translate>[\d.]+)s"
    r"\s*\|\s*total\s+(?P<total>[\d.]+)s\s*\|\s*stt\s+(?P<stt>.+?)\s*\|\s*lang\s+(?P<lang>\S+)")
CHUNK = re.compile(r"cloud chunk \d+/\d+ failed \((?P<detail>.*?)\)\s*(?:—|-|$)")


def read_lines(path, limit=4000):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as log:
            lines = log.readlines()
    except OSError:
        return []
    return lines[-limit:]


def parse(lines):
    """Последнее задание из журнала: разбор строки TIMING и причина отказа облака."""
    timing_index = None
    timing = None
    for index in range(len(lines) - 1, -1, -1):
        match = TIMING.search(lines[index])
        if match:
            timing = match.groupdict()
            timing_index = index
            break
    if not timing:
        return None
    # Причина отказа облака — строка «cloud chunk … failed» этого же задания.
    reason = ""
    start = 0
    for index in range(timing_index - 1, -1, -1):
        if "TIMING:" in lines[index]:
            start = index
            break
    for index in range(timing_index - 1, start - 1, -1):
        match = CHUNK.search(lines[index])
        if match:
            reason = clean_reason(match.group("detail"))
            break
    return {"when": lines[timing_index][:19].strip(), "timing": timing, "reason": reason}


def clean_reason(detail):
    """«http=402 curl=0 0.78s Текст ошибки» -> «http=402: Текст ошибки»."""
    detail = detail.strip()
    match = re.match(r"http=(\d+)\s+(?:curl=\d+\s+)?(?:\S+\s+)?(?P<text>.*)$", detail)
    if not match:
        return detail
    code = match.group(1)
    text = match.group("text").strip()
    if not text:
        return f"http={code}"
    return f"http={code}: {text}"


def describe(data):
    """Короткое описание результата — для строки в окне настройки."""
    timing = data["timing"]
    stt = timing["stt"]
    reason = data["reason"]
    if stt.startswith("cloud:") and stt.endswith(")"):
        where = f"частично в облаке, часть — на этом компьютере ({stt})"
    elif stt.startswith("cloud:"):
        where = f"в облаке, модель {stt.split(':', 1)[1]}"
    elif stt == "local(cloud failed)":
        where = "на этом компьютере — облако отказалось"
    else:
        where = "на этом компьютере"
    if reason:
        where += f" ({reason})"
    speed = ""
    try:
        audio = float(timing["audio"])
        whisper = float(timing["whisper"])
        if audio > 0 and whisper > 0:
            speed = f", {audio:.0f} с речи за {whisper:.1f} с ({audio / whisper:.0f}× быстрее)"
    except (TypeError, ValueError):
        pass
    return f"Последний раз: {where}{speed}."


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--log", default=os.environ.get("WD_DICTATE_LOG") or DEFAULT_LOG)
    args = parser.parse_args()
    data = parse(read_lines(os.path.expanduser(args.log)))
    if not data:
        print("empty\t1")
        return 0
    timing = data["timing"]
    stt = timing["stt"]
    if stt.startswith("cloud:") and "+local(" in stt:
        mode = "mixed"
    elif stt.startswith("cloud:"):
        mode = "cloud"
    else:
        mode = "local"
    model = stt.split(":", 1)[1] if stt.startswith("cloud:") else ""
    if "+local(" in model:
        model = model.split("+", 1)[0]
    fields = [
        ("when", data["when"]),
        ("stt", stt),
        ("mode", mode),
        ("model", model),
        ("reason", data["reason"]),
        ("audio", timing["audio"]),
        ("whisper", timing["whisper"]),
        ("total", timing["total"]),
        ("lang", timing["lang"]),
        ("text", describe(data)),
    ]
    for name, value in fields:
        print(f"{name}\t{value}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
