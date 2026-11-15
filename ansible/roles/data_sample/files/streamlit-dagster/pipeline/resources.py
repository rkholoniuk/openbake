import os

import dagster as dg
from sqlalchemy import Engine, create_engine

DEFAULT_DATABASE_URL = "postgresql+psycopg://user:dev@localhost:5432/analytics"


def database_url() -> str:
    return os.environ.get("DATABASE_URL", DEFAULT_DATABASE_URL)


class Warehouse(dg.ConfigurableResource):
    """The analytics database. Postgres in the workspace; any SQLAlchemy URL works (tests use SQLite)."""

    url: str = DEFAULT_DATABASE_URL

    def engine(self) -> Engine:
        return create_engine(self.url)
