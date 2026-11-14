import dagster as dg
import pandas as pd
from sqlalchemy import create_engine

from pipeline import assets
from pipeline.definitions import defs
from pipeline.resources import Warehouse


def test_definitions_load():
    dg.Definitions.validate_loadable(defs)


def test_pipeline_end_to_end(tmp_path):
    url = f"sqlite:///{tmp_path / 'warehouse.db'}"
    result = dg.materialize(
        [assets.raw_orders, assets.daily_revenue, assets.revenue_by_category, assets.daily_revenue_is_sane],
        resources={"warehouse": Warehouse(url=url)},
    )
    assert result.success
    assert all(check.passed for check in result.get_asset_check_evaluations())

    engine = create_engine(url)
    daily = pd.read_sql_table("daily_revenue", engine)
    by_category = pd.read_sql_table("revenue_by_category", engine)
    assert len(daily) == assets.DAYS
    assert daily["orders"].sum() == assets.ORDERS
    assert set(by_category["category"]) == set(assets.CATEGORIES)
    assert abs(daily["revenue"].sum() - by_category["revenue"].sum()) < 0.05
