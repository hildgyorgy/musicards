#!/bin/zsh
set -euo pipefail
script_directory="${0:A:h}"
exec python3 "$script_directory/didl_playlist_probe.py" "$@"
