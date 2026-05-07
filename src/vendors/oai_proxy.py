"""Inject the proxy-required ``X-API-Key`` header into every litellm call.

Some OpenAI-compatible proxies (notably the Azure-hosted gateway used in
this project's ``.env``) authenticate at the gateway layer with a custom
``X-API-Key`` header rather than the standard ``Authorization`` bearer.
Neither the openai SDK nor litellm send that header by default, so we
wrap ``litellm.completion`` / ``litellm.acompletion`` once at process
start to splice it into ``extra_headers`` whenever ``X_API_KEY`` is set
in the environment.

Call :func:`install` once after ``load_dotenv`` and before any system
issues an LLM call. Idempotent.
"""

from __future__ import annotations

import os
from typing import Any

import litellm

_INSTALLED_FLAG = "_clbench_xkey_installed"


def install() -> bool:
    """Wrap ``litellm.completion`` / ``acompletion`` to inject ``X-API-Key``.

    Returns ``True`` if the wrap was installed this call, ``False`` if
    it was a no-op (already installed, or ``X_API_KEY`` not set).
    """
    if getattr(litellm, _INSTALLED_FLAG, False):
        return False

    x_api_key = os.getenv("X_API_KEY")
    if not x_api_key:
        return False

    orig_completion = litellm.completion
    orig_acompletion = litellm.acompletion

    def _inject(kwargs: dict[str, Any]) -> dict[str, Any]:
        headers = dict(kwargs.get("extra_headers") or {})
        headers.setdefault("X-API-Key", x_api_key)
        kwargs["extra_headers"] = headers
        return kwargs

    def completion(*args: Any, **kwargs: Any) -> Any:
        return orig_completion(*args, **_inject(kwargs))

    async def acompletion(*args: Any, **kwargs: Any) -> Any:
        return await orig_acompletion(*args, **_inject(kwargs))

    litellm.completion = completion
    litellm.acompletion = acompletion
    setattr(litellm, _INSTALLED_FLAG, True)
    return True
