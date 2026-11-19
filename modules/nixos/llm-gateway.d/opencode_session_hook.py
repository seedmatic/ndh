"""LiteLLM callback: inject the x-opencode-session header required by opencode_go.

opencode Go rejects requests without it (400 MissingSessionID). Resolution order:
inbound x-opencode-session header, litellm session id / metadata, then a stable
per-caller hash so one client keeps hitting the same route.
"""

import hashlib
import uuid

from litellm.integrations.custom_logger import CustomLogger

HEADER = "x-opencode-session"


def _inbound_headers(data):
    meta = data.get("metadata") or data.get("litellm_metadata") or {}
    headers = meta.get("headers") or {}
    proxy_req = data.get("proxy_server_request") or {}
    headers = {**(proxy_req.get("headers") or {}), **headers}
    return {str(k).lower(): v for k, v in headers.items()}


class OpencodeSessionHook(CustomLogger):
    async def async_pre_call_hook(self, user_api_key_dict, cache, data, call_type):
        model = str(data.get("model", ""))
        meta = data.get("metadata") or data.get("litellm_metadata") or {}
        if not model.startswith("go-") and "opencode_go" not in model:
            deployment = meta.get("deployment_model") or ""
            if "opencode_go" not in str(deployment):
                return data

        extra = dict(data.get("extra_headers") or {})
        if any(k.lower() == HEADER for k in extra):
            return data

        session = (
            _inbound_headers(data).get(HEADER)
            or data.get("litellm_session_id")
            or meta.get("session_id")
            or _stable_id(user_api_key_dict)
        )
        extra[HEADER] = str(session)
        data["extra_headers"] = extra
        return data


def _stable_id(user_api_key_dict):
    token = getattr(user_api_key_dict, "token", None) or getattr(
        user_api_key_dict, "user_id", None
    )
    if not token:
        return str(uuid.uuid4())
    return str(uuid.UUID(hashlib.sha256(str(token).encode()).hexdigest()[:32]))


session_hook = OpencodeSessionHook()
