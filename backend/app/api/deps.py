from fastapi import Depends

from app.core.config import Settings, get_settings
from app.repositories.postgrest import PostgrestClient
from app.repositories.workspace import Repository, SupabaseRepository


def get_repository(settings: Settings = Depends(get_settings)) -> Repository:
    return SupabaseRepository(PostgrestClient(settings))
