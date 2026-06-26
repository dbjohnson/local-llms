#!/usr/bin/env bash

export OPENAI_BASE_URL="http://localhost:8080/v1"
export OPENAI_API_KEY="sk-dummy" # llama-server ignores this, but Codex requires it
codex
