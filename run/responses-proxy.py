#!/usr/bin/env python3
"""OpenAI Responses API -> Chat Completions API proxy for Codex Desktop + llama-server."""

import json
import time
import uuid
import logging
from fastapi import FastAPI, Request
from fastapi.responses import StreamingResponse
import httpx

# Set up logging
logging.basicConfig(level=logging.DEBUG, format='%(asctime)s - %(name)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)

UPSTREAM = "http://localhost:8080/v1"
app = FastAPI()


def responses_to_chat(body: dict) -> dict:
    messages = []
    instructions = body.get("instructions")
    if instructions:
        messages.append({"role": "system", "content": instructions})

    input_data = body.get("input", [])
    if isinstance(input_data, str):
        messages.append({"role": "user", "content": input_data})
    elif isinstance(input_data, list):
        for item in input_data:
            if isinstance(item, str):
                messages.append({"role": "user", "content": item})
            elif isinstance(item, dict):
                t = item.get("type", "")
                if t == "message":
                    role = "system" if item.get("role") == "developer" else item.get("role", "user")
                    content = item.get("content", "")
                    if isinstance(content, list):
                        content = "\n".join(c["text"] for c in content if c.get("type") == "input_text")
                    messages.append({"role": role, "content": content})
                elif t == "function_call":
                    args = item.get("arguments", {})
                    messages.append({"role": "assistant", "tool_calls": [{
                        "id": item.get("id", f"call_{uuid.uuid4().hex[:12]}"),
                        "type": "function",
                        "function": {"name": item.get("name", ""), "arguments": json.dumps(args) if isinstance(args, dict) else str(args)},
                    }]})
                elif t == "function_call_output":
                    messages.append({"role": "tool", "tool_call_id": item.get("call_id", ""), "content": item.get("output", "")})

    tools = []
    for tool in body.get("tools", []):
        if tool.get("type") == "function" and "function" in tool:
            f = tool["function"]
            tools.append({"type": "function", "function": {"name": f.get("name", ""), "description": f.get("description", ""), "parameters": f.get("parameters", {})}})

    chat = {
        "model": body.get("model", ""),
        "messages": messages,
        "max_tokens": min(body.get("max_output_tokens") or 2048, 2048),
        "stream": True,
    }
    if tools:
        chat["tools"] = tools
    if body.get("tool_choice"):
        chat["tool_choice"] = body["tool_choice"]
    if body.get("temperature") is not None:
        chat["temperature"] = body["temperature"]
    if body.get("top_p") is not None:
        chat["top_p"] = body["top_p"]
    return chat


@app.get("/health")
async def health():
    return {"status": "ok"}


@app.get("/v1/models")
async def list_models():
    async with httpx.AsyncClient() as client:
        resp = await client.get(f"{UPSTREAM}/models")
        return resp.json()


@app.post("/v1/responses")
async def create_response(request: Request):
    try:
        body = await request.json()
        chat_body = responses_to_chat(body)

            if body.get("stream", True):
                # Buffer the entire response first, then send all events at once
                # This avoids Codex seeing a disconnect mid-stream
                resp_id = f"resp_{uuid.uuid4().hex[:24]}"
                created = int(time.time())
                model_name = body.get("model", "")

                events = []
                events.append(f"event: response.created\ndata: {json.dumps({'id': resp_id, 'object': 'response', 'created_at': created, 'status': 'in_progress', 'model': model_name, 'output': [], 'usage': {'input_tokens': 0, 'output_tokens': 0}})}\n\n")

                text_content = ""
                reasoning_content = ""
                tool_calls = []
                current_tool = None
                tool_args = ""
                final_usage = {"input_tokens": 0, "output_tokens": 0}

                async with httpx.AsyncClient() as client:
                    async with client.stream("POST", f"{UPSTREAM}/chat/completions", json=chat_body, timeout=300.0) as resp:
                        async for line in resp.aiter_lines():
                            line = line.strip()
                            if not line or not line.startswith("data: "):
                                continue
                            data_str = line[6:]
                            if data_str == "[DONE]":
                                break
                            try:
                                data = json.loads(data_str)
                            except json.JSONDecodeError:
                                continue

                            for choice in data.get("choices", []):
                                delta = choice.get("delta", {})
                                content = delta.get("content")
                                reasoning = delta.get("reasoning_content")
                                if reasoning:
                                    reasoning_content += reasoning
                                    events.append(f"event: response.reasoning_text.delta\ndata: {json.dumps({'id': resp_id, 'object': 'response.reasoning_text.delta', 'output_index': 0, 'content_index': 0, 'delta': reasoning})}\n\n")
                                if content:
                                    text_content += content
                                    events.append(f"event: response.output_text.delta\ndata: {json.dumps({'id': resp_id, 'object': 'response.output_text.delta', 'output_index': 0, 'content_index': 0, 'delta': content})}\n\n")

                                for tc in delta.get("tool_calls", []):
                                    func = tc.get("function", {})
                                    if "name" in func:
                                        if current_tool:
                                            tool_calls.append({"id": current_tool["id"], "name": current_tool["name"], "arguments": json.loads(tool_args) if tool_args else {}})
                                        current_tool = {"id": tc.get("id", f"call_{uuid.uuid4().hex[:12]}"), "name": func["name"]}
                                        tool_args = ""
                                    if "arguments" in func:
                                        tool_args += func["arguments"]

                                finish = choice.get("finish_reason")
                                if finish in ("tool_calls", "stop") and current_tool:
                                    tool_calls.append({"id": current_tool["id"], "name": current_tool["name"], "arguments": json.loads(tool_args) if tool_args else {}})
                                    current_tool = None
                                    tool_args = ""

                            usage = data.get("usage")
                            if usage:
                                final_usage = {"input_tokens": usage.get("prompt_tokens", 0), "output_tokens": usage.get("completion_tokens", 0)}

                for tc in tool_calls:
                    events.append(f"event: response.output_tool_call.done\ndata: {json.dumps({'id': resp_id, 'object': 'response.output_tool_call.done', 'output_index': 0, 'tool_call': {'id': tc['id'], 'name': tc['name'], 'arguments': tc['arguments'], 'type': 'function_call'}})}\n\n")

                if reasoning_content:
                    events.append(f"event: response.reasoning_text.done\ndata: {json.dumps({'id': resp_id, 'object': 'response.reasoning_text.done', 'output_index': 0, 'content_index': 0})}\n\n")

                if text_content:
                    events.append(f"event: response.output_text.done\ndata: {json.dumps({'id': resp_id, 'object': 'response.output_text.done', 'output_index': 0, 'content_index': 0})}\n\n")

                output_text = text_content if text_content else reasoning_content
                events.append(f"event: response.completed\ndata: {json.dumps({'id': resp_id, 'object': 'response', 'created_at': created, 'status': 'completed', 'model': model_name, 'output': [{'type': 'message', 'role': 'assistant', 'content': [{'type': 'output_text', 'text': output_text}]}], 'usage': final_usage})}\n\n")

                async def stream():
                    for event in events:
                        yield event

                return StreamingResponse(
                    stream(),
                    media_type="text/event-stream",
                    headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no", "Connection": "keep-alive"}
                )
        else:
            async with httpx.AsyncClient() as client:
                resp = await client.post(f"{UPSTREAM}/chat/completions", json=chat_body, timeout=300.0)
                data = resp.json()
                choices = data.get("choices", [])
                msg = choices[0].get("message", {}) if choices else {}
                content = msg.get("content", "") or ""
                reasoning = msg.get("reasoning_content", "") or ""
                output_text = content if content else reasoning
                usage = data.get("usage", {})
                resp_id = f"resp_{uuid.uuid4().hex[:24]}"
                created = int(time.time())
                model_name = body.get("model", "")
                return {
                    "id": resp_id,
                    "object": "response",
                    "created_at": created,
                    "status": "completed",
                    "model": model_name,
                    "output": [{"type": "message", "role": "assistant", "content": [{"type": "output_text", "text": output_text}]}],
                    "usage": {"input_tokens": usage.get("prompt_tokens", 0), "output_tokens": usage.get("completion_tokens", 0)}
                }
    except Exception as e:
        import traceback
        print(f"ERROR in create_response: {e}")
        traceback.print_exc()
        return {
            "id": f"resp_{uuid.uuid4().hex[:24]}",
            "object": "response",
            "created_at": int(time.time()),
            "status": "completed",
            "model": body.get("model", "unknown"),
            "output": [{"type": "message", "role": "assistant", "content": [{"type": "output_text", "text": f"Proxy error: {str(e)}"}]}],
            "usage": {"input_tokens": 0, "output_tokens": 0}
        }


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="127.0.0.1", port=8081)
