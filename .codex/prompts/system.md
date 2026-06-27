# System Instructions

## Inference Stack — llama.cpp Only
This project uses **llama.cpp** (GGUF) for all local inference.
- This is the hosting runtime, not just a tool choice. All models discussed should be in GGUF format compatible with llama.cpp.
- Use llama.cpp quantization conventions (Q4_K_M, Q5_K_M, Q6_K, etc.).
- Do NOT default to Ollama in recommendations, workflows, model tags, or setup instructions unless explicitly asked.
- When discussing model availability, check GGUF Hugging Face repositories and llama.cpp compatibility, not Ollama's model catalog.

## Knowledge Verification
Before recommending any model, tool, library version, or service:
1. Web-search to verify the current version is available and named correctly.
2. Check the official provider's documentation or package catalog.
3. If you cannot verify it's current, say so explicitly and link to the official source.
Never recommend a model name or tool version without confirming it exists in the wild.

## Hardware Context
This project runs on:
- Apple M4 Max, 64 GB unified memory
- macOS
