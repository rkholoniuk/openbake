"""Dashboard over the tables the Dagster assets write."""

import os
import subprocess
from pathlib import Path

import pandas as pd
import streamlit as st
from sqlalchemy import create_engine, inspect

DATABASE_URL = os.environ.get("DATABASE_URL", "postgresql+psycopg://user:dev@localhost:5432/analytics")
PROJECT_DIR = Path(__file__).resolve().parent.parent
TABLES = {"daily_revenue", "revenue_by_category"}

st.set_page_config(page_title="Sales pipeline", layout="wide")
st.title("Sales pipeline")
st.caption("Built by the Dagster assets in `pipeline/` and stored in Postgres. Dagster UI: port 3000.")


@st.cache_resource
def engine():
    return create_engine(DATABASE_URL)


@st.cache_data(ttl=60)
def load() -> tuple[pd.DataFrame, pd.DataFrame]:
    daily = pd.read_sql_table("daily_revenue", engine(), parse_dates=["order_date"])
    categories = pd.read_sql_table("revenue_by_category", engine())
    return daily, categories


if st.button("Run pipeline now"):
    with st.spinner("Materializing assets..."):
        result = subprocess.run(
            ["dagster", "asset", "materialize", "--select", "*", "-m", "pipeline.definitions"],
            cwd=PROJECT_DIR,
            capture_output=True,
            text=True,
        )
    if result.returncode == 0:
        st.success("Assets materialized.")
        load.clear()
    else:
        st.error("Materialization failed.")
        st.code(result.stderr[-3000:])

if not TABLES <= set(inspect(engine()).get_table_names()):
    st.info("No data yet. Click **Run pipeline now**, or materialize the assets in Dagster.")
    st.stop()

daily, categories = load()
total = float(daily["revenue"].sum())
orders = int(daily["orders"].sum())

c1, c2, c3 = st.columns(3)
c1.metric("Revenue, 30 days", f"{total:,.2f}")
c2.metric("Orders", f"{orders:,}")
c3.metric("Average order", f"{total / orders:,.2f}" if orders else "-")

left, right = st.columns(2)
with left:
    st.subheader("Revenue per day")
    st.line_chart(daily, x="order_date", y="revenue")
with right:
    st.subheader("Revenue by category")
    st.bar_chart(categories, x="category", y="revenue")

st.subheader("Daily figures")
st.dataframe(daily.assign(order_date=daily["order_date"].dt.date), hide_index=True, use_container_width=True)
