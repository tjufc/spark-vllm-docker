# vLLM audio extras

The stock `vllm-node` image does not install `vllm[audio]`. OpenAI-compatible
`POST /v1/audio/transcriptions` then fails with a missing-audio-extra error or
`Invalid or unsupported audio file.`

This runtime mod installs only the three packages that make transcription work
on the existing image:

| Package | Role |
|---|---|
| `soundfile` | WAV and other common PCM containers |
| `librosa` | vLLM audio extra's typical decode/resample helper |
| `av` (PyAV) | m4a/webm and resampling; OpenWhispr recordings usually need this |

It does **not** install `vllm[audio]`. That extra can re-resolve vLLM and
replace the image's CUDA Torch build.

The install is idempotent: already-importable packages are skipped. Torch,
TorchVision, and Torchaudio are pinned when present so the resolver cannot
swap them. Prefer `uv pip`; fall back to `python3 -m pip`.

The Qwen3-ASR recipe applies this mod automatically. To use it with a manual
launch:

```bash
./launch-cluster.sh --solo \
  --apply-mod mods/vllm-audio \
  exec vllm serve Qwen/Qwen3-ASR-1.7B --port 8510 --host 0.0.0.0
```
