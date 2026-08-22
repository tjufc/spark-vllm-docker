#!/bin/bash
set -euo pipefail

# Install vLLM audio extras into the running container without rebuilding
# vllm-node. The stock image does not ship vllm[audio]; /v1/audio/transcriptions
# then fails until soundfile, librosa, and PyAV (av) are present.
#
# Do not install the vllm[audio] extra itself: that can re-resolve vLLM and
# fight the image's CUDA Torch stack. Only the three runtime packages that
# were verified for Qwen3-ASR / OpenWhispr are installed.

PREFIX="[vllm-audio]"
PACKAGES=(soundfile librosa av)

if ! command -v python3 >/dev/null 2>&1; then
  echo "$PREFIX python3 is required to install audio extras." >&2
  exit 1
fi

python_executable="$(command -v python3)"

package_is_importable() {
  local package="$1"
  "$python_executable" -c "import ${package}" >/dev/null 2>&1
}

package_version() {
  local package="$1"
  "$python_executable" -c "import importlib.metadata as m; print(m.version('${package}'))" 2>/dev/null || true
}

missing=()
for package in "${PACKAGES[@]}"; do
  if package_is_importable "$package"; then
    version="$(package_version "$package")"
    if [[ -n "$version" ]]; then
      echo "$PREFIX ${package} is already installed: ${version}"
    else
      echo "$PREFIX ${package} is already importable"
    fi
  else
    missing+=("$package")
  fi
done

if [[ ${#missing[@]} -eq 0 ]]; then
  echo "$PREFIX All audio extras are already installed."
  exit 0
fi

override_file=""
cleanup() {
  if [[ -n "$override_file" ]]; then
    rm -f "$override_file"
  fi
}
trap cleanup EXIT

if torch_version="$("$python_executable" -c "import torch; print(torch.__version__)" 2>/dev/null)"; then
  override_file="$(mktemp)"
  printf 'torch==%s\n' "$torch_version" > "$override_file"
  for package in torchvision torchaudio; do
    pinned_version="$(package_version "$package")"
    if [[ -n "$pinned_version" ]]; then
      printf '%s==%s\n' "$package" "$pinned_version" >> "$override_file"
    fi
  done
  echo "$PREFIX Installing ${missing[*]} while pinning Torch ${torch_version}"
else
  echo "$PREFIX Installing ${missing[*]} (Torch pin skipped; torch is not importable)"
fi

install_packages() {
  local -a cmd
  if command -v uv >/dev/null 2>&1; then
    cmd=(uv pip install --python "$python_executable")
    cmd+=("${missing[@]}")
    if [[ -n "$override_file" ]]; then
      cmd+=(--override "$override_file")
    fi
  elif "$python_executable" -m pip --version >/dev/null 2>&1; then
    cmd=("$python_executable" -m pip install)
    cmd+=("${missing[@]}")
    if [[ -n "$override_file" ]]; then
      cmd+=(--constraint "$override_file")
    fi
  else
    echo "$PREFIX Neither uv nor Python pip is available to install audio extras." >&2
    exit 1
  fi

  echo "$PREFIX Running: ${cmd[*]}"
  "${cmd[@]}"
}

install_packages

for package in "${missing[@]}"; do
  if ! package_is_importable "$package"; then
    echo "$PREFIX Installation completed without making ${package} importable." >&2
    echo "$PREFIX If soundfile/av fail, the image may also need libsndfile1 or ffmpeg." >&2
    exit 1
  fi
  version="$(package_version "$package")"
  if [[ -n "$version" ]]; then
    echo "$PREFIX Installed ${package}: ${version}"
  else
    echo "$PREFIX Installed ${package}"
  fi
done

echo "$PREFIX Audio extras are ready for /v1/audio/transcriptions."
