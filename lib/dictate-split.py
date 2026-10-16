#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Режет запись диктовки на куски по ~N секунд, стараясь резать по тишине.

Зачем это вообще нужно. Длинная запись — это один огромный проход whisper по
видеокарте, и именно на нём у нас вешалась очередь вычислений amdgpu
(`ring comp_1.2.0 timeout` -> сброс всей карты -> падение Hyprland). Несколько
коротких проходов вместо одного длинного заметно снижают риск, и — что важнее —
если один кусок всё-таки потерян, остальные уже распознаны и не пропадут.

Почему не просто `ffmpeg -f segment`. Ровная нарезка по времени рубит речь
посередине слова, и на каждой границе whisper теряет или коверкает слово.
Поэтому границу двигаем к ближайшей паузе в речи (silencedetect), и только
если паузы рядом нет — режем по времени как есть.

Вывод: по одному пути до куска в строке, в порядке воспроизведения.
Использование: dictate-split.py <входной.wav> <каталог-для-кусков> <секунд>
"""

import os
import re
import subprocess
import sys

# Насколько далеко от расчётной границы согласны искать паузу. 30 с — это
# компромисс: достаточно, чтобы почти всегда найти паузу в живой речи, и не
# настолько много, чтобы куски получались сильно разной длины.
SEARCH_WINDOW = 30.0
# Порог тишины. -35 дБ с длительностью 0.35 с ловит естественные паузы между
# фразами и не срабатывает на дыхании и фоновом шуме комнаты.
SILENCE_NOISE = "-35dB"
SILENCE_MIN_DURATION = 0.35


def duration_seconds(path):
    """Длительность записи из размера файла.

    Формат задан в dictate.fish (16 кГц, моно, s16 = 32000 байт/с), поэтому
    арифметика точна и не требует лишнего вызова ffprobe. 44 байта — заголовок.
    """
    return max(0.0, (os.path.getsize(path) - 44) / 32000.0)


def silence_midpoints(path):
    """Середины пауз в записи, в секундах, по возрастанию."""
    try:
        proc = subprocess.run(
            ["ffmpeg", "-nostdin", "-v", "info", "-i", path,
             "-af", "silencedetect=noise=%s:d=%s" % (SILENCE_NOISE, SILENCE_MIN_DURATION),
             "-f", "null", "-"],
            capture_output=True, text=True, timeout=120,
        )
    except (OSError, subprocess.SubprocessError):
        return []

    starts, points = [], []
    for line in proc.stderr.splitlines():
        m = re.search(r"silence_start:\s*([0-9.]+)", line)
        if m:
            starts.append(float(m.group(1)))
            continue
        m = re.search(r"silence_end:\s*([0-9.]+)", line)
        if m and starts:
            points.append((starts.pop() + float(m.group(1))) / 2.0)
    return sorted(points)


def cut_points(total, chunk, points):
    """Границы реза: идём от начала, каждый раз прыгая примерно на chunk."""
    cuts, pos = [], 0.0
    while total - pos > chunk * 1.5:
        target = pos + chunk
        # Ближайшая пауза к расчётной границе, но строго после текущей позиции,
        # иначе можно получить кусок нулевой длины и уйти в вечный цикл.
        candidates = [p for p in points
                      if abs(p - target) <= SEARCH_WINDOW and p > pos + chunk * 0.5]
        pos = min(candidates, key=lambda p: abs(p - target)) if candidates else target
        cuts.append(pos)
    return cuts


def main():
    if len(sys.argv) != 4:
        sys.stderr.write("usage: dictate-split.py <in.wav> <outdir> <seconds>\n")
        return 2

    src, outdir, chunk = sys.argv[1], sys.argv[2], float(sys.argv[3])
    total = duration_seconds(src)
    os.makedirs(outdir, exist_ok=True)

    # Короткую запись не трогаем совсем: лишний перекодировщик на пути — лишний
    # источник ошибок, а весь смысл нарезки только в длинных записях.
    if total <= chunk * 1.5:
        print(src)
        return 0

    cuts = cut_points(total, chunk, silence_midpoints(src))
    bounds = [0.0] + cuts + [total]

    written = []
    for i in range(len(bounds) - 1):
        dst = os.path.join(outdir, "chunk-%03d.wav" % i)
        cmd = ["ffmpeg", "-nostdin", "-v", "error", "-y",
               "-i", src, "-ss", "%.3f" % bounds[i]]
        # У последнего куска конец не задаём: -to с точностью до миллисекунды
        # умеет отрезать последние отсчёты, а это как раз хвост фразы.
        if i < len(bounds) - 2:
            cmd += ["-to", "%.3f" % bounds[i + 1]]
        cmd += ["-c", "copy", dst]
        try:
            if subprocess.run(cmd, capture_output=True, timeout=120).returncode != 0:
                raise OSError("ffmpeg failed")
        except (OSError, subprocess.SubprocessError):
            # Нарезка не удалась — честно отдаём исходник целиком. Один
            # длинный проход whisper хуже, чем несколько коротких, но
            # несравнимо лучше, чем потерянная запись.
            sys.stderr.write("split failed at chunk %d, falling back to whole file\n" % i)
            print(src)
            return 0
        written.append(dst)

    for path in written:
        print(path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
