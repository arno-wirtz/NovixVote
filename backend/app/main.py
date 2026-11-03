from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app.api.v1.routes import router
from app.core.config import get_settings
from app.core.middleware import SecurityHeadersMiddleware


def create_app() -> FastAPI:
    settings = get_settings()
    docs = None if settings.app_env == "production" else "/docs"
    app = FastAPI(title=settings.app_name, version=settings.app_version, docs_url=docs, redoc_url=None,
                  openapi_url=None if docs is None else "/openapi.json")
    app.add_middleware(SecurityHeadersMiddleware)
    app.add_middleware(
        CORSMiddleware, allow_origins=settings.cors_origin_list, allow_credentials=False,
        allow_methods=["GET", "POST", "PATCH", "DELETE"], allow_headers=["Authorization", "Content-Type"],
    )
    app.include_router(router)
    return app


app = create_app()
