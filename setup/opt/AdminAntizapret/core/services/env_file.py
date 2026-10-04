import os

from utils.env_file import update_env_file


class EnvFileService:
    def __init__(self, env_file_path):
        self.env_file_path = env_file_path

    def set_env_value(self, key, value):
        """Update or append env key in local .env file."""
        self.set_env_values({key: value})

    def set_env_values(self, values):
        """Apply a group of settings under the same interprocess lock."""
        update_env_file(self.env_file_path, values)

    def get_env_value(self, key, default=""):
        """Reads env value from .env first, then from process env as fallback."""
        env_path = self.env_file_path
        if os.path.exists(env_path):
            with open(env_path, "r", encoding="utf-8") as f:
                for raw in f:
                    line = raw.strip()
                    if not line or line.startswith("#"):
                        continue
                    if line.startswith(f"{key}="):
                        return line.split("=", 1)[1].strip()
        return os.getenv(key, default)
