"""Central, validated configuration. All settings come from environment variables."""
from functools import lru_cache
from typing import Literal

from pydantic import model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    app_env: Literal["development", "test", "staging", "production"] = "development"
    app_name: str = "NovixVote API"
    app_version: str = "0.1.0"
    cors_origins: str = "http://localhost:5173"

    supabase_url: str = ""
    supabase_anon_key: str = ""
    supabase_jwt_secret: str = ""

    @property
    def cors_origin_list(self) -> list[str]:
        return [o.strip() for o in self.cors_origins.split(",") if o.strip()]

    @property
    def supabase_configured(self) -> bool:
        return bool(self.supabase_url and self.supabase_anon_key)

    @model_validator(mode="after")
    def _require_secrets_outside_dev(self) -> "Settings":
        if self.app_env in ("staging", "production"):
            if not self.supabase_configured:
                raise ValueError("SUPABASE_URL and SUPABASE_ANON_KEY are required in staging/production")
            if "*" in self.cors_origin_list:
                raise ValueError("Wildcard CORS origin is not allowed in staging/production")
        return self


@lru_cache
def get_settings() -> Settings:
    return Settings()
