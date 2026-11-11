from fastapi import Depends

from app.core.config import Settings, get_settings
from app.repositories.postgrest import PostgrestClient
from app.repositories.results import ResultsRepo, SupabaseResultsRepository
from app.repositories.voting import SupabaseVotingRepository, VotingRepo
from app.repositories.workspace import Repository, SupabaseRepository


def get_repository(settings: Settings = Depends(get_settings)) -> Repository:
    return SupabaseRepository(PostgrestClient(settings))


def get_voting_repository(settings: Settings = Depends(get_settings)) -> VotingRepo:
    return SupabaseVotingRepository(PostgrestClient(settings))


def get_results_repository(settings: Settings = Depends(get_settings)) -> ResultsRepo:
    return SupabaseResultsRepository(PostgrestClient(settings))
