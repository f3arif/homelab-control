"""
title: AFZ Typed Agent
author: AFZ Engineering
version: 0.1.0
requirements: httpx
"""

from typing import Any, Dict, List, Optional, Tuple

import httpx
from pydantic import BaseModel, Field


class Pipe:
    class Valves(BaseModel):
        AFZ_AGENT_URL: str = Field(
            default="http://100.70.25.8:8796",
            description="AFZ typed-agent base URL reachable from the OpenWebUI server.",
        )
        REQUEST_TIMEOUT_SECONDS: int = Field(
            default=240,
            ge=30,
            le=600,
            description="Timeout for one AFZ agent request.",
        )
        INCLUDE_CONVERSATION_HISTORY: bool = Field(
            default=True,
            description="Include prior system/user/assistant turns in the AFZ prompt.",
        )
        SHOW_TOOL_TRACE: bool = Field(
            default=True,
            description="Append the AFZ local typed-tool trace to the answer.",
        )

    def __init__(self):
        self.valves = self.Valves()

    def pipes(self):
        return [
            {"id": "torbox-auto", "name": "AFZ TorBox - Smart Auto"},
            {"id": "torbox-sol", "name": "AFZ TorBox - Sol"},
            {"id": "general-auto", "name": "AFZ General - Smart Auto"},
            {"id": "general-sol", "name": "AFZ General - Sol"},
        ]

    @staticmethod
    def _model_suffix(model: str) -> str:
        # OpenWebUI manifold model IDs are typically prefixed with the Pipe ID.
        return model.split(".", 1)[-1] if "." in model else model

    @staticmethod
    def _route(model: str) -> Tuple[str, str]:
        model = Pipe._model_suffix(model)
        routes = {
            "torbox-auto": ("torbox", "auto"),
            "torbox-sol": ("torbox", "sol"),
            "general-auto": ("AFZ-General", "auto"),
            "general-sol": ("AFZ-General", "sol"),
        }
        return routes.get(model, ("AFZ-General", "auto"))

    @staticmethod
    def _content_text(content: Any) -> str:
        if isinstance(content, str):
            return content
        if isinstance(content, list):
            parts: List[str] = []
            for item in content:
                if isinstance(item, str):
                    parts.append(item)
                elif isinstance(item, dict):
                    text = item.get("text")
                    if isinstance(text, str):
                        parts.append(text)
            return "\n".join(p for p in parts if p)
        if content is None:
            return ""
        return str(content)

    def _build_prompt(self, body: Dict[str, Any]) -> str:
        messages = body.get("messages") or []
        normalized: List[Tuple[str, str]] = []
        for message in messages:
            if not isinstance(message, dict):
                continue
            role = str(message.get("role") or "user").lower()
            if role not in {"system", "user", "assistant"}:
                continue
            text = self._content_text(message.get("content")).strip()
            if text:
                normalized.append((role, text))

        if not normalized:
            return ""

        if not self.valves.INCLUDE_CONVERSATION_HISTORY:
            for role, text in reversed(normalized):
                if role == "user":
                    return text
            return normalized[-1][1]

        return "\n\n".join(f"{role.upper()}: {text}" for role, text in normalized)

    async def pipe(
        self,
        body: Dict[str, Any],
        __user__: Optional[Dict[str, Any]] = None,
    ):
        project, processor = self._route(str(body.get("model") or ""))
        prompt = self._build_prompt(body)
        if not prompt:
            return "AFZ Agent error: no usable prompt was supplied."

        payload = {
            "prompt": prompt,
            "project": project,
            "processor": processor,
        }
        url = self.valves.AFZ_AGENT_URL.rstrip("/") + "/api/request"

        try:
            timeout = httpx.Timeout(float(self.valves.REQUEST_TIMEOUT_SECONDS))
            async with httpx.AsyncClient(timeout=timeout) as client:
                response = await client.post(url, json=payload)
                response.raise_for_status()
                data = response.json()
        except httpx.HTTPStatusError as exc:
            detail = ""
            try:
                detail = exc.response.text[:1000]
            except Exception:
                pass
            return f"AFZ Agent HTTP error {exc.response.status_code}: {detail or exc}"
        except Exception as exc:
            return f"AFZ Agent connection error: {exc}"

        if not data.get("ok"):
            return f"AFZ Agent error: {data.get('error') or data.get('state') or data}"

        answer = str(data.get("answer") or "")
        if not answer:
            answer = "AFZ Agent completed without answer text."

        trace = data.get("toolTrace") or []
        if self.valves.SHOW_TOOL_TRACE and trace:
            rows: List[str] = []
            for item in trace:
                if not isinstance(item, dict):
                    continue
                name = str(item.get("name") or "unknown")
                ok = bool(item.get("ok"))
                line = f"- {name}: {'PASS' if ok else 'FAIL'}"
                error = item.get("error")
                if error:
                    line += f" - {str(error)[:500]}"
                rows.append(line)
            if rows:
                answer += "\n\n---\n**AFZ local tool trace**\n" + "\n".join(rows)

        return answer
