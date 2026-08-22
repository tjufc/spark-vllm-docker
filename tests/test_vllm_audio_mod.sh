#!/bin/bash
set -euo pipefail

PROJECT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
MOD="$PROJECT_DIR/mods/vllm-audio/run.sh"
HOST_PYTHON="$(command -v python3)"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

BIN_DIR="$TMP_DIR/bin"
STATE_FILE="$TMP_DIR/state.json"
UV_LOG="$TMP_DIR/uv.log"
mkdir -p "$BIN_DIR"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

write_state() {
  "$HOST_PYTHON" - "$STATE_FILE" "$@" <<'PY'
import json
import sys

path = sys.argv[1]
installed = sys.argv[2].split(",") if sys.argv[2] else []
torch_version = sys.argv[3] if len(sys.argv) > 3 else ""
payload = {"installed": [name for name in installed if name], "torch_version": torch_version}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle)
PY
}

installed_packages() {
  "$HOST_PYTHON" - "$STATE_FILE" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    payload = json.load(handle)
print(" ".join(payload.get("installed", [])))
PY
}

{
  printf '#!%s\n' "$HOST_PYTHON"
  cat <<'PY'
import json
import os
import re
import sys

STATE_PATH = os.environ["VLLM_AUDIO_TEST_STATE"]


def load_state():
    with open(STATE_PATH, encoding="utf-8") as handle:
        return json.load(handle)


def save_state(state):
    with open(STATE_PATH, "w", encoding="utf-8") as handle:
        json.dump(state, handle)


def installed():
    return set(load_state().get("installed", []))


def handle_pip(args):
    packages = []
    index = 0
    while index < len(args):
        arg = args[index]
        if arg in ("--constraint", "--override", "--python"):
            index += 2
            continue
        if arg.startswith("-"):
            index += 1
            continue
        packages.append(arg)
        index += 1
    state = load_state()
    state["installed"] = sorted(set(state.get("installed", [])) | set(packages))
    save_state(state)
    print("fake-pip installed " + " ".join(packages))


def handle_dash_c(code):
    state = load_state()
    present = set(state.get("installed", []))
    if "import torch" in code and "torch.__version__" in code:
        torch_version = state.get("torch_version") or ""
        if not torch_version:
            raise SystemExit(1)
        print(torch_version)
        return
    version_match = re.search(r"version\(['\"]([A-Za-z0-9_-]+)['\"]\)", code)
    if "importlib.metadata" in code and version_match:
        package = version_match.group(1)
        if package in present:
            print(f"test-{package}-1.0")
            return
        raise SystemExit(1)
    import_match = re.search(r"\bimport\s+([A-Za-z0-9_, ]+)", code)
    if not import_match:
        raise SystemExit("unsupported python -c: " + code)
    names = [name.strip() for name in import_match.group(1).split(",") if name.strip()]
    if any(name not in present for name in names):
        raise SystemExit(1)


def main():
    if len(sys.argv) >= 3 and sys.argv[1] == "-m" and sys.argv[2] == "pip":
        remaining = sys.argv[3:]
        if remaining and remaining[0] == "install":
            remaining = remaining[1:]
        if remaining[:1] == ["--version"]:
            print("pip 24.0 from fake")
            return
        handle_pip(remaining)
        return
    if len(sys.argv) >= 3 and sys.argv[1] == "-c":
        handle_dash_c(sys.argv[2])
        return
    raise SystemExit("unsupported python invocation: " + " ".join(sys.argv[1:]))


if __name__ == "__main__":
    main()
PY
} > "$BIN_DIR/python3"
chmod +x "$BIN_DIR/python3"

cat > "$BIN_DIR/uv" <<EOF
#!/bin/bash
set -euo pipefail
printf '%s\\n' "\$*" >> "\$VLLM_AUDIO_TEST_UV_LOG"
exec "$HOST_PYTHON" - "\$VLLM_AUDIO_TEST_STATE" "\$@" <<'PY'
import json
import sys

state_path = sys.argv[1]
args = sys.argv[2:]
if args[:2] != ["pip", "install"]:
    raise SystemExit("expected uv pip install, got: " + " ".join(args))

packages = []
index = 2
while index < len(args):
    arg = args[index]
    if arg in ("--python", "--override", "--constraint"):
        index += 2
        continue
    if arg.startswith("-"):
        index += 1
        continue
    packages.append(arg)
    index += 1

with open(state_path, encoding="utf-8") as handle:
    state = json.load(handle)
state["installed"] = sorted(set(state.get("installed", [])) | set(packages))
with open(state_path, "w", encoding="utf-8") as handle:
    json.dump(state, handle)
print("fake-uv installed " + " ".join(packages))
PY
EOF
chmod +x "$BIN_DIR/python3" "$BIN_DIR/uv"

export VLLM_AUDIO_TEST_STATE="$STATE_FILE"
export VLLM_AUDIO_TEST_UV_LOG="$UV_LOG"
# Keep the host uv off PATH so the pip fallback case can actually run.
export PATH="$BIN_DIR:/usr/bin:/bin"
hash -r

if [[ "$(command -v python3)" != "$BIN_DIR/python3" ]]; then
  fail "test python3 is not on PATH: $(command -v python3)"
fi
if [[ "$(command -v uv)" != "$BIN_DIR/uv" ]]; then
  fail "test uv is not on PATH: $(command -v uv)"
fi

bash -n "$MOD"

grep -Fq 'PACKAGES=(soundfile librosa av)' "$MOD" || fail "unexpected package list"
if grep -Eq 'pip install[^[:space:]].*vllm\[audio\]' "$MOD"; then
  fail "mod must not install the vllm[audio] extra"
fi

# Already installed: no installer should run.
write_state "soundfile,librosa,av" "2.13.0"
: > "$UV_LOG"
output=$(bash "$MOD")
grep -Fq "All audio extras are already installed." <<< "$output" || fail "expected skip output, got: $output"
if [[ -s "$UV_LOG" ]]; then
  fail "uv should not run when packages are already importable"
fi

# Missing av: uv install with Torch override.
write_state "soundfile,librosa" "2.13.0"
: > "$UV_LOG"
output=$(bash "$MOD")
grep -Fq "Installing av while pinning Torch 2.13.0" <<< "$output" || fail "expected torch-pinned install, got: $output"
grep -Fq "Installed av: test-av-1.0" <<< "$output" || fail "expected av install confirmation, got: $output"
uv_cmd=$(cat "$UV_LOG")
grep -Fq "pip install --python" <<< "$uv_cmd" || fail "expected uv pip install: $uv_cmd"
grep -Fq " av " <<< " $uv_cmd " || fail "expected av in uv command: $uv_cmd"
grep -Fq -- "--override" <<< "$uv_cmd" || fail "expected torch override: $uv_cmd"
[[ "$(installed_packages)" == *"av"* ]] || fail "state should include av after install"

# pip fallback when uv is missing.
write_state "soundfile" "2.13.0"
rm -f "$BIN_DIR/uv"
hash -r
if command -v uv >/dev/null 2>&1; then
  fail "uv still on PATH after removal: $(command -v uv)"
fi
: > "$UV_LOG"
output=$(bash "$MOD")
grep -Fq "Installing librosa av while pinning Torch 2.13.0" <<< "$output" || fail "expected pip fallback install, got: $output"
grep -Fq "Installed librosa: test-librosa-1.0" <<< "$output" || fail "expected librosa confirmation, got: $output"
grep -Fq "Installed av: test-av-1.0" <<< "$output" || fail "expected av confirmation after pip, got: $output"
[[ "$(installed_packages)" == *"librosa"* ]] || fail "state should include librosa after pip"
[[ "$(installed_packages)" == *"av"* ]] || fail "state should include av after pip"

# Failed install must abort.
write_state "" ""
{
  printf '#!%s\n' "$HOST_PYTHON"
  cat <<'PY'
import sys

if sys.argv[1:3] == ["-m", "pip"] and sys.argv[3:4] == ["--version"]:
    print("pip 24.0 from fake")
    raise SystemExit(0)
if sys.argv[1:3] == ["-m", "pip"]:
    print("fake-pip refused install")
    raise SystemExit(0)
raise SystemExit(1)
PY
} > "$BIN_DIR/python3"
chmod +x "$BIN_DIR/python3"
if output=$(bash "$MOD" 2>&1); then
  fail "expected failed import after pip to abort, got: $output"
fi
grep -Fq "Installation completed without making soundfile importable." <<< "$output" || fail "expected import failure message, got: $output"

echo "vllm-audio mod tests passed."
