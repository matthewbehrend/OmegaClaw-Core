import os

def pop_auth_secret():
    return os.environ.pop("OMEGACLAW_AUTH_SECRET", "")
