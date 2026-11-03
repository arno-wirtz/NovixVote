from .base import VotingMethod

_methods: dict[str, VotingMethod] = {}


def register(method: VotingMethod) -> None:
    if method.key in _methods:
        raise ValueError(f"Voting method already registered: {method.key}")
    _methods[method.key] = method


def get(key: str) -> VotingMethod:
    try:
        return _methods[key]
    except KeyError:
        raise KeyError(f"Unknown voting method: {key}") from None


def all_methods() -> list[VotingMethod]:
    return list(_methods.values())
