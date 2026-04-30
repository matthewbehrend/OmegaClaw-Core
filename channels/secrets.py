import os

_SECRETS_DIR = "/run/secrets"
_cache = {}


def read_secret(name, default=""):
    if name in _cache:
        return _cache[name]
    path = os.path.join(_SECRETS_DIR, name)
    value = ""
    try:
        with open(path) as f:
            value = f.read().strip()
    except (FileNotFoundError, PermissionError):
        pass
    result = value or default
    _cache[name] = result
    return result


def read_tg_bot_token():
    return read_secret("tg_bot_token")


def read_mm_bot_token():
    return read_secret("mm_bot_token")
