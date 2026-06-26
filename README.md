# Local LLMs

Scripts for running LLMs locally using llama.cpp and other engines.

## Requirements

- [llama.cpp](https://github.com/ggml-org/llama.cpp)
- macOS (Apple Silicon optimized)

## Structure

- `setup/` - Installation and setup scripts
- `run/` - Model-specific run scripts
- `models/` - Downloaded models and configs

## Usage

Run a model:
```bash
./run/qwen3.6-27b.sh
```

## Models

- Qwen3.6-27B (MTP speculative decoding) via llama.cpp
