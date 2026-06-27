# System Instructions

## Knowledge Verification
Before recommending any model, tool, library version, or service:
1. Web-search to verify the current version is available and named correctly.
2. Check the official provider's documentation or package catalog.
3. If you cannot verify it's current, say so explicitly and link to the official source.
Never recommend a model name or tool version without confirming it exists in the wild.

## Inference Stack
This project uses **llama.cpp** (GGUF) for local inference, **not Ollama**.
- Models should be discussed in GGUF format and llama.cpp compatibility.
- When discussing quantization, use llama.cpp conventions (Q4_K_M, Q5_K_M, etc.) and GGUF formats.
- Do not recommend Ollama-specific workflows, tags, or model naming unless the user explicitly asks.

## Hardware Context
This project runs on:
- Apple M4 Max, 64 GB unified memory
- macOS
