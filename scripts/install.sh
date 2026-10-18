#!/bin/sh
set -eu

if ! command -v python3 >/dev/null 2>&1; then
    echo 'bluemock requires Python 3.10 or newer; install python3 and retry.' >&2
    exit 1
fi
if ! python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)'; then
    echo 'bluemock requires Python 3.10 or newer; the python3 on PATH is too old.' >&2
    exit 1
fi

repo_dir=$(CDPATH='' cd -P "$(dirname "$0")/.." && pwd)
venv_dir="$HOME/.local/share/bluemock/venv"
bin_dir="$HOME/.local/bin"
if [ ! -x "$venv_dir/bin/python" ]; then
    python3 -m venv "$venv_dir"
fi
if ! "$venv_dir/bin/python" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)'; then
    echo "Existing venv at $venv_dir requires Python 3.10 or newer; recreate it and retry." >&2
    exit 1
fi
"$venv_dir/bin/python" -m pip install "$repo_dir"
mkdir -p "$bin_dir"
ln -sf "$venv_dir/bin/bluemock" "$bin_dir/bluemock"
echo "Installed bluemock: $bin_dir/bluemock"
case ":${PATH:-}:" in
    *":$bin_dir:"*) ;;
    *) echo 'Add ~/.local/bin to PATH: export PATH="$HOME/.local/bin:$PATH"' ;;
esac
