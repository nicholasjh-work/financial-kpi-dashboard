"""
Export a snapshot of KPI values to CSV for audit trail.

Runs monthly. Captures the current values of all dashboard KPIs
at the division and month grain. The CSV is stored for historical
comparison and compliance review.

Usage:
    python scripts/export_kpi_snapshot.py
    python scripts/export_kpi_snapshot.py --month 2025-01
"""
import argparse
import logging
import os
from datetime import datetime
from pathlib import Path

import pandas as pd
from dotenv import load_dotenv

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
logger = logging.getLogger(__name__)

load_dotenv()

SNAPSHOT_SQL = """
SELECT
    r.division,
    r.month,
    r.net_revenue,
    r.cogs,
    r.gross_margin_pct,
    r.net_revenue_ytd,
    r.net_revenue_r12m,
    r.net_revenue_py,
    o.actual_opex_total,
    o.budget_opex_total,
    o.actual_opex_total - o.budget_opex_total AS opex_variance,
    CURRENT_TIMESTAMP() AS snapshot_timestamp
FROM reporting.v_rpt_revenue_by_division r
LEFT JOIN (
    SELECT
        month,
        SUM(actual_opex) AS actual_opex_total,
        SUM(budget_opex) AS budget_opex_total
    FROM reporting.v_rpt_opex_variance
    GROUP BY month
) o ON r.month = o.month
WHERE r.month = %(target_month)s
ORDER BY r.division, r.month
"""


def main():
    parser = argparse.ArgumentParser(description="Export KPI snapshot to CSV")
    parser.add_argument(
        "--month",
        default=None,
        help="Target month in YYYY-MM format. Defaults to prior month.",
    )
    args = parser.parse_args()

    if args.month:
        target_month = args.month + "-01"
    else:
        today = datetime.today()
        if today.month == 1:
            target_month = f"{today.year - 1}-12-01"
        else:
            target_month = f"{today.year}-{today.month - 1:02d}-01"

    logger.info("Exporting KPI snapshot for %s", target_month)

    from snowflake.connector import connect

    conn = connect(
        account=os.environ["SNOWFLAKE_ACCOUNT"],
        user=os.environ["SNOWFLAKE_USER"],
        password=os.environ["SNOWFLAKE_PASSWORD"],
        database=os.getenv("SNOWFLAKE_DATABASE", "FINANCE_DW"),
        schema=os.getenv("SNOWFLAKE_SCHEMA", "REPORTING"),
        warehouse=os.getenv("SNOWFLAKE_WAREHOUSE", "ANALYTICS_WH"),
    )

    df = pd.read_sql(SNAPSHOT_SQL, conn, params={"target_month": target_month})
    conn.close()

    output_dir = Path(__file__).parent.parent / "data" / "snapshots"
    output_dir.mkdir(parents=True, exist_ok=True)
    filename = f"kpi_snapshot_{target_month[:7].replace('-', '')}.csv"
    output_path = output_dir / filename

    df.to_csv(output_path, index=False)
    logger.info("Exported %d rows to %s", len(df), output_path)


if __name__ == "__main__":
    main()
