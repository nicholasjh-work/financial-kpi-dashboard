"""
Post-refresh validation for the Executive Financial KPI Dashboard.

Runs the validation queries from sql/validation_queries.sql against Snowflake
and reports pass/fail for each check. Designed to run as a scheduled job
after the Snowflake refresh task completes.

Usage:
    cp .env.example .env
    pip install -r requirements.txt
    python scripts/validate_refresh.py
"""
import logging
import os
import sys
from dataclasses import dataclass
from pathlib import Path

import yaml
from dotenv import load_dotenv

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
)
logger = logging.getLogger(__name__)

load_dotenv()


@dataclass
class CheckResult:
    name: str
    passed: bool
    row_count: int
    detail: str


def get_connection():
    """Connect to Snowflake using env vars."""
    from snowflake.connector import connect

    return connect(
        account=os.environ["SNOWFLAKE_ACCOUNT"],
        user=os.environ["SNOWFLAKE_USER"],
        password=os.environ["SNOWFLAKE_PASSWORD"],
        database=os.getenv("SNOWFLAKE_DATABASE", "FINANCE_DW"),
        schema=os.getenv("SNOWFLAKE_SCHEMA", "REPORTING"),
        warehouse=os.getenv("SNOWFLAKE_WAREHOUSE", "ANALYTICS_WH"),
    )


def load_thresholds() -> dict:
    """Load alert thresholds from config."""
    config_path = Path(__file__).parent.parent / "config" / "settings.yaml"
    if config_path.exists():
        with open(config_path) as f:
            cfg = yaml.safe_load(f) or {}
            return cfg.get("thresholds", {})
    return {}


def run_check(cursor, name: str, sql: str) -> CheckResult:
    """Run a single validation query. Zero rows = pass."""
    try:
        cursor.execute(sql)
        rows = cursor.fetchall()
        passed = len(rows) == 0
        detail = f"{len(rows)} issue(s) found" if not passed else "clean"
        if not passed and rows:
            detail += f": {rows[0]}"
        return CheckResult(name=name, passed=passed, row_count=len(rows), detail=detail)
    except Exception as e:
        return CheckResult(name=name, passed=False, row_count=-1, detail=str(e))


def main():
    checks = [
        (
            "Row count deviation",
            """
            WITH counts AS (
                SELECT COUNT(*) AS cnt
                FROM fact_revenue
                WHERE _loaded_at >= CURRENT_DATE
            )
            SELECT * FROM counts WHERE cnt = 0
            """,
        ),
        (
            "Orphan keys: revenue -> division",
            """
            SELECT COUNT(*) AS orphans
            FROM fact_revenue f
            LEFT JOIN dim_division d ON f.division_id = d.division_id
            WHERE d.division_id IS NULL
            HAVING COUNT(*) > 0
            """,
        ),
        (
            "Orphan keys: revenue -> product",
            """
            SELECT COUNT(*) AS orphans
            FROM fact_revenue f
            LEFT JOIN dim_product p ON f.product_id = p.product_id
            WHERE p.product_id IS NULL
            HAVING COUNT(*) > 0
            """,
        ),
        (
            "Null revenue amounts",
            """
            SELECT COUNT(*) AS nulls
            FROM fact_revenue
            WHERE (gross_amount + return_amount + adjustment_amount) IS NULL
            HAVING COUNT(*) > 0
            """,
        ),
        (
            "Duplicate transaction IDs",
            """
            SELECT transaction_id, COUNT(*) AS cnt
            FROM fact_revenue
            GROUP BY transaction_id
            HAVING COUNT(*) > 1
            LIMIT 5
            """,
        ),
        (
            "Refresh freshness (>18 hours stale)",
            """
            SELECT MAX(_loaded_at) AS last_load,
                   DATEDIFF('hour', MAX(_loaded_at), CURRENT_TIMESTAMP) AS hours_stale
            FROM fact_revenue
            HAVING DATEDIFF('hour', MAX(_loaded_at), CURRENT_TIMESTAMP) > 18
            """,
        ),
    ]

    try:
        conn = get_connection()
    except ImportError:
        logger.error("snowflake-connector-python not installed. Run: pip install -r requirements.txt")
        sys.exit(1)
    except Exception as e:
        logger.error("Connection failed: %s", e)
        sys.exit(1)

    cursor = conn.cursor()
    results = []
    failures = 0

    logger.info("Running %d validation checks...", len(checks))

    for name, sql in checks:
        result = run_check(cursor, name, sql)
        results.append(result)
        status = "PASS" if result.passed else "FAIL"
        if not result.passed:
            failures += 1
        logger.info("  [%s] %s: %s", status, result.name, result.detail)

    cursor.close()
    conn.close()

    logger.info("Validation complete: %d/%d passed", len(results) - failures, len(results))

    if failures > 0:
        logger.warning("%d check(s) failed. Review output above.", failures)
        sys.exit(1)

    sys.exit(0)


if __name__ == "__main__":
    main()
