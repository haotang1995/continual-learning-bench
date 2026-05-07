"""End-to-end smoke test for the OAI-proxy X-API-Key injection.

Loads .env, installs the litellm wrap, and issues a tiny chat completion
against the proxy. Exits 0 on success, 1 on any error. Prints the model
response and the URL hit so you can eyeball that traffic actually went
to the proxy (not api.openai.com).
"""

from __future__ import annotations

import os
import sys

from dotenv import load_dotenv


def main() -> int:
    load_dotenv()
    base_url = os.getenv("OPENAI_BASE_URL")
    if not base_url:
        print("FAIL: OPENAI_BASE_URL not set", file=sys.stderr)
        return 1
    if not os.getenv("X_API_KEY"):
        print("FAIL: X_API_KEY not set", file=sys.stderr)
        return 1

    from src.vendors import oai_proxy

    installed = oai_proxy.install()
    print(f"oai_proxy.install() -> {installed}")

    import litellm

    try:
        resp = litellm.completion(
            model="gpt-4.1",
            messages=[{"role": "user", "content": "Reply with exactly: pong"}],
            max_tokens=5,
            temperature=0.0,
        )
    except Exception as exc:
        print(
            f"FAIL: litellm.completion raised: {type(exc).__name__}: {exc}",
            file=sys.stderr,
        )
        return 1

    content = resp.choices[0].message.content
    model = resp.model
    print(f"base_url      : {base_url}")
    print(f"resolved model: {model}")
    print(f"response      : {content!r}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
