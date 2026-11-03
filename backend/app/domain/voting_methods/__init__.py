from . import registry
from .base import Ballot, CountResult, VotingMethod
from .highest_averages import DHondtMethod, SainteLagueMethod
from .instant_runoff import InstantRunoffMethod
from .plurality import PluralityMethod

registry.register(PluralityMethod())
registry.register(DHondtMethod())
registry.register(SainteLagueMethod())
registry.register(InstantRunoffMethod())

__all__ = ["Ballot", "CountResult", "VotingMethod", "PluralityMethod", "DHondtMethod", "SainteLagueMethod", "InstantRunoffMethod", "registry"]
