import pytest
from pydantic import ValidationError

from app.core.config import Settings
from app.schemas.api import OrganisationCreate
from tests.conftest import make_token


def test_health_is_public_and_has_security_headers(client):
    r = client.get("/api/v1/health")
    assert r.status_code == 200
    assert r.json()["status"] == "ok"
    assert r.headers["x-content-type-options"] == "nosniff"
    assert r.headers["x-request-id"]


@pytest.mark.parametrize("path", ["/api/v1/auth/me", "/api/v1/organisations", "/api/v1/voting-methods"])
def test_protected_routes_require_token(client, path):
    assert client.get(path).status_code == 401


def test_rejects_bad_tokens(client):
    for token in [make_token(secret="wrong-secret-wrong-secret-wrong-secret!"),
                  make_token(exp_in=-10), make_token(aud="anon"), "garbage"]:
        r = client.get("/api/v1/auth/me", headers={"Authorization": f"Bearer {token}"})
        assert r.status_code == 401


def test_rejects_alg_none(client):
    import base64, json
    b = lambda d: base64.urlsafe_b64encode(json.dumps(d).encode()).rstrip(b"=").decode()
    token = f"{b({'alg': 'none', 'typ': 'JWT'})}.{b({'sub': 'x', 'aud': 'authenticated', 'exp': 9999999999})}."
    assert client.get("/api/v1/auth/me", headers={"Authorization": f"Bearer {token}"}).status_code == 401


def test_me(client, auth):
    r = client.get("/api/v1/auth/me", headers=auth)
    assert r.status_code == 200 and r.json()["email"] == "a@b.test"


def test_create_and_list_organisations(client, auth, repo):
    r = client.post("/api/v1/organisations", json={"name": "Hillside School"}, headers=auth)
    assert r.status_code == 201 and r.json()["slug"] == "hillside-school"
    assert repo.calls == [("create_organisation", "Hillside School", "hillside-school")]
    assert client.get("/api/v1/organisations", headers=auth).json()[0]["role"] == "owner"


@pytest.mark.parametrize("body", [{"name": "x"}, {"name": "Valid", "slug": "Bad Slug"}, {"name": "Valid", "slug": "-a-"}, {}])
def test_create_organisation_validation(client, auth, body):
    assert client.post("/api/v1/organisations", json=body, headers=auth).status_code == 422


def test_slug_derivation_rejects_unusable_names():
    with pytest.raises(ValidationError):
        OrganisationCreate(name="!!")


def test_voting_methods_listed(client, auth):
    keys = [m["key"] for m in client.get("/api/v1/voting-methods", headers=auth).json()]
    assert "plurality" in keys


def test_production_config_requires_supabase():
    with pytest.raises(ValidationError):
        Settings(app_env="production", supabase_url="", supabase_anon_key="")
    with pytest.raises(ValidationError):
        Settings(app_env="production", supabase_url="https://x", supabase_anon_key="k", cors_origins="*")
