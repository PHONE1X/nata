#!/usr/bin/env bash
set -euo pipefail

command -v git >/dev/null || { echo "Нужен git: sudo pacman -S git" >&2; exit 1; }
command -v makepkg >/dev/null || { echo "Нужен makepkg (base-devel)" >&2; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

git clone --depth 1 https://github.com/PHONE1X/nata.git "$tmp/nata"
cd "$tmp/nata/packaging/nata"
makepkg -si
