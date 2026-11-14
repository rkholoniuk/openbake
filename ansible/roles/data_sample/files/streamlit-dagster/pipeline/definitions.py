import dagster as dg

from . import assets
from .resources import Warehouse, database_url

refresh_sales = dg.define_asset_job("refresh_sales", selection=dg.AssetSelection.groups("sales"))

defs = dg.Definitions(
    assets=[assets.raw_orders, assets.daily_revenue, assets.revenue_by_category],
    asset_checks=[assets.daily_revenue_is_sane],
    jobs=[refresh_sales],
    schedules=[dg.ScheduleDefinition(job=refresh_sales, cron_schedule="0 6 * * *")],
    resources={"warehouse": Warehouse(url=database_url())},
)
