import os

_AUTH_SECRET_PATH = "/tmp/.auth_secret"


def pop_auth_secret():
    try:
        with open(_AUTH_SECRET_PATH) as f:
            secret = f.read().strip()
        os.unlink(_AUTH_SECRET_PATH)
        if secret:
            return secret
    except (FileNotFoundError, PermissionError):
        pass
    return os.environ.pop("OMEGACLAW_AUTH_SECRET", "")
