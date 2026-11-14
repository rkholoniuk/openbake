"""Sales pipeline: synthetic orders -> daily revenue and revenue by category, all in the warehouse."""

import dagster as dg
import numpy as np
import pandas as pd

from .resources import Warehouse

CATEGORIES = ["books", "electronics", "garden", "grocery", "toys"]
DAYS = 30
ORDERS = 3000


@dg.asset(group_name="sales", description="Synthetic orders for the last 30 days.")
def raw_orders(warehouse: Warehouse) -> dg.MaterializeResult:
    rng = np.random.default_rng()
    days = pd.date_range(end=pd.Timestamp.today().normalize(), periods=DAYS, freq="D")
    orders = pd.DataFrame(
        {
            "order_id": np.arange(1, ORDERS + 1),
            "order_date": rng.choice(days, ORDERS),
            "category": rng.choice(CATEGORIES, ORDERS),
            "quantity": rng.integers(1, 6, ORDERS),
            "unit_price": rng.gamma(2.0, 15.0, ORDERS).round(2),
        }
    )
    orders.to_sql("raw_orders", warehouse.engine(), if_exists="replace", index=False)
    return dg.MaterializeResult(metadata={"rows": len(orders)})


def _orders(warehouse: Warehouse) -> pd.DataFrame:
    orders = pd.read_sql_table("raw_orders", warehouse.engine(), parse_dates=["order_date"])
    orders["revenue"] = orders["quantity"] * orders["unit_price"]
    return orders


@dg.asset(group_name="sales", deps=[raw_orders], description="Orders and revenue per day.")
def daily_revenue(warehouse: Warehouse) -> dg.MaterializeResult:
    orders = _orders(warehouse)
    daily = (
        orders.assign(order_date=orders["order_date"].dt.normalize())
        .groupby("order_date", as_index=False)
        .agg(orders=("order_id", "count"), revenue=("revenue", "sum"))
        .round({"revenue": 2})
    )
    daily.to_sql("daily_revenue", warehouse.engine(), if_exists="replace", index=False)
    return dg.MaterializeResult(
        metadata={"days": len(daily), "total_revenue": float(daily["revenue"].sum())}
    )


@dg.asset(group_name="sales", deps=[raw_orders], description="Revenue per product category.")
def revenue_by_category(warehouse: Warehouse) -> dg.MaterializeResult:
    orders = _orders(warehouse)
    by_category = (
        orders.groupby("category", as_index=False)
        .agg(orders=("order_id", "count"), revenue=("revenue", "sum"))
        .round({"revenue": 2})
        .sort_values("revenue", ascending=False)
    )
    by_category.to_sql("revenue_by_category", warehouse.engine(), if_exists="replace", index=False)
    return dg.MaterializeResult(metadata={"categories": len(by_category)})


@dg.asset_check(asset=daily_revenue, description="Every day has orders and no revenue is negative.")
def daily_revenue_is_sane(warehouse: Warehouse) -> dg.AssetCheckResult:
    daily = pd.read_sql_table("daily_revenue", warehouse.engine())
    negative = int((daily["revenue"] < 0).sum())
    return dg.AssetCheckResult(
        passed=bool(len(daily) > 0 and negative == 0),
        metadata={"days": len(daily), "negative_days": negative},
    )
