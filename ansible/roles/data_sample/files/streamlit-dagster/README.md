# Streamlit + Dagster + Postgres sample

Dagster assets generate 30 days of synthetic orders, load them into Postgres and
derive two tables. A Streamlit app shows them.

```
pipeline/assets.py       raw_orders -> daily_revenue, revenue_by_category (+ an asset check)
pipeline/definitions.py  assets, a daily schedule, the Postgres resource
app/streamlit_app.py     dashboard with a "Run pipeline now" button
dagster.yaml             Dagster instance storage in Postgres
tests/                   end-to-end test against SQLite
```

## Run it in the workspace

```sh
ws-sample-data start        # Postgres, Dagster on :3000, Streamlit on :8501
ws-sample-data materialize  # or click "Run pipeline now" / "Materialize all"
ws-sample-data stop
```

`DATABASE_URL` points the pipeline and the app at another database.

## Test

```sh
uv run --group dev pytest
```
