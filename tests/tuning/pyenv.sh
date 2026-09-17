#!/usr/bin/env bash
# Numpy na NixOS: symlinknute libstdc++/libz v .venv/liblibs + LD_LIBRARY_PATH
export LD_LIBRARY_PATH="$(cd "$(dirname "$0")" && pwd)/.venv/liblibs${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
exec "$(cd "$(dirname "$0")" && pwd)/.venv/bin/python" "$@"
