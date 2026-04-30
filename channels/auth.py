import os

from channels.secrets import read_secret


def pop_auth_secret():
    secret = read_secret("omegaclaw_auth_secret")
    if not secret:
        secret = os.environ.pop("OMEGACLAW_AUTH_SECRET", "")
    return secret
