#!/usr/bin/env bash
set -euo pipefail

if [ -z "${1:-}" ]; then
    echo "Uso: $0 <ruta_de_rom.gb>"
    exit 1
fi

ROM_PATH="$(realpath "$1")"
if [ ! -f "$ROM_PATH" ]; then
    echo "Error: No se encontro la ROM en '$ROM_PATH'" >&2
    exit 1
fi

WORK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="$WORK_DIR/recomp_linux"
REPO_DIR="$WORK_DIR/gb-recompiled"
ROM_STEM="$(basename "$ROM_PATH")"
ROM_STEM="${ROM_STEM%.*}"

mkdir -p "$OUT_DIR"

# Clonar gb-recompiled solo si no existe
if [ ! -d "$REPO_DIR" ]; then
    echo "==> Clonando gb-recompiled..."
    git clone https://github.com/arcanite24/gb-recompiled.git "$REPO_DIR"
else
    echo "==> Usando gb-recompiled existente en $REPO_DIR"
fi

# Construir gbrecomp
echo "==> Compilando gbrecomp..."
cmake -G Ninja -S "$REPO_DIR" -B "$REPO_DIR/build"
ninja -C "$REPO_DIR/build"

# Recompilar ROM a C en recomp_linux
echo "==> Generando proyecto C en $OUT_DIR..."
"$REPO_DIR/build/bin/gbrecomp" "$ROM_PATH" -o "$OUT_DIR"

# Compilar binario nativo para Linux
echo "==> Compilando binario para Linux..."
cmake -G Ninja -S "$OUT_DIR" -B "$OUT_DIR/build"
ninja -C "$OUT_DIR/build"

BIN_PATH="$OUT_DIR/build/$ROM_STEM"
echo ""
echo "==> Compilacion completada: $BIN_PATH"
echo "==> Ejecutando juego..."
"$BIN_PATH"
