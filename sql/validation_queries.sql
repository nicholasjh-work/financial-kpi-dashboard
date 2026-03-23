-- Post-refresh validation queries.
-- Run these after every Snowflake refresh to catch data issues
-- before they reach the Power BI dashboard.
--
-- Each query returns rows only if something is wrong.
-- Zero rows = pass. Any rows = investigate.

-- 1. Row count check: flag if today's refresh is more than 10% off
--    from the prior refresh. Sudden drops usually mean an extract failed.
--    Sudden spikes usually mean a filter broke or a duplicate source loaded.
WITH counts AS (
    SELECT
        'fact_revenue' AS table_name,
        COUNT(*) AS current_count,
        (SELECT COUNT(*) FROM fact_revenue WHERE _loaded_at < CURRENT_DATE) AS prior_count
    FROM fact_revenue
    WHERE _loaded_at >= CURRENT_DATE
    UNION ALL
    SELECT
        'fact_opex',
        COUNT(*),
        (SELECT COUNT(*) FROM fact_opex WHERE _loaded_at < CURRENT_DATE)
    FROM fact_opex
    WHERE _loaded_at >= CURRENT_DATE
)
SELECT *
FROM counts
WHERE ABS(current_count - prior_count) > prior_count * 0.10
   OR current_count = 0;


-- 2. Orphan key check: fact rows that don't join to a dimension.
--    Orphans mean either the dimension load is behind the fact load,
--    or a new code appeared that hasn't been mapped.
SELECT 'fact_revenue -> dim_division' AS join_path, COUNT(*) AS orphan_count
FROM fact_revenue f
LEFT JOIN dim_division d ON f.division_id = d.division_id
WHERE d.division_id IS NULL
HAVING COUNT(*) > 0

UNION ALL

SELECT 'fact_revenue -> dim_product', COUNT(*)
FROM fact_revenue f
LEFT JOIN dim_product p ON f.product_id = p.product_id
WHERE p.product_id IS NULL
HAVING COUNT(*) > 0

UNION ALL

SELECT 'fact_opex -> dim_cost_center', COUNT(*)
FROM fact_opex f
LEFT JOIN dim_cost_center cc ON f.cost_center_id = cc.cost_center_id
WHERE cc.cost_center_id IS NULL
HAVING COUNT(*) > 0;


-- 3. Null rate check on required fields.
--    These fields should never be null. If they are, something broke upstream.
SELECT
    'fact_revenue.net_revenue nulls' AS check_name,
    COUNT(*) AS null_count
FROM fact_revenue
WHERE (gross_amount + return_amount + adjustment_amount) IS NULL
HAVING COUNT(*) > 0

UNION ALL

SELECT
    'fact_revenue.division_id nulls',
    COUNT(*)
FROM fact_revenue
WHERE division_id IS NULL
HAVING COUNT(*) > 0

UNION ALL

SELECT
    'fact_opex.actual_amount nulls',
    COUNT(*)
FROM fact_opex
WHERE actual_amount IS NULL
HAVING COUNT(*) > 0;


-- 4. Revenue reconciliation: compare dashboard view totals to raw fact totals.
--    These should match within 0.1%. If they don't, a filter or join
--    in the view is dropping or duplicating rows.
WITH view_total AS (
    SELECT SUM(net_revenue) AS view_revenue
    FROM reporting.v_rpt_revenue_by_division
    WHERE month >= DATE_TRUNC('month', CURRENT_DATE - INTERVAL '1 month')
      AND month < DATE_TRUNC('month', CURRENT_DATE)
),
raw_total AS (
    SELECT SUM(gross_amount + return_amount + adjustment_amount) AS raw_revenue
    FROM fact_revenue f
    JOIN dim_date dt ON f.date_key = dt.date_key
    WHERE DATE_TRUNC('month', dt.calendar_date) >= DATE_TRUNC('month', CURRENT_DATE - INTERVAL '1 month')
      AND DATE_TRUNC('month', dt.calendar_date) < DATE_TRUNC('month', CURRENT_DATE)
      AND f.is_intercompany = FALSE
      AND f.is_test_data = FALSE
)
SELECT
    v.view_revenue,
    r.raw_revenue,
    ABS(v.view_revenue - r.raw_revenue) AS difference,
    ABS(v.view_revenue - r.raw_revenue) / NULLIF(r.raw_revenue, 0) AS pct_difference
FROM view_total v
CROSS JOIN raw_total r
WHERE ABS(v.view_revenue - r.raw_revenue) / NULLIF(r.raw_revenue, 0) > 0.001;


-- 5. Duplicate business key check on fact_revenue.
--    Each transaction_id should appear exactly once.
--    Duplicates here inflate revenue on the dashboard.
SELECT
    transaction_id,
    COUNT(*) AS occurrences
FROM fact_revenue
GROUP BY transaction_id
HAVING COUNT(*) > 1
LIMIT 20;


-- 6. Budget completeness check: every cost center should have
--    budget loaded for the current fiscal year. Missing budget
--    makes the variance calculation meaningless for that cost center.
SELECT
    cc.cost_center_name,
    COUNT(DISTINCT DATE_TRUNC('month', dt.calendar_date)) AS months_with_budget
FROM dim_cost_center cc
LEFT JOIN fact_opex f ON cc.cost_center_id = f.cost_center_id
LEFT JOIN dim_date dt ON f.date_key = dt.date_key
WHERE dt.fiscal_year = YEAR(CURRENT_DATE)
  AND f.budget_amount IS NOT NULL
GROUP BY cc.cost_center_name
HAVING COUNT(DISTINCT DATE_TRUNC('month', dt.calendar_date)) < MONTH(CURRENT_DATE);


-- 7. Refresh freshness check: flag if the most recent load
--    is older than expected. Revenue should refresh daily by 6 AM.
SELECT
    'fact_revenue' AS table_name,
    MAX(_loaded_at) AS last_refresh,
    DATEDIFF('hour', MAX(_loaded_at), CURRENT_TIMESTAMP) AS hours_since_refresh
FROM fact_revenue
HAVING DATEDIFF('hour', MAX(_loaded_at), CURRENT_TIMESTAMP) > 18

UNION ALL

SELECT
    'fact_opex',
    MAX(_loaded_at),
    DATEDIFF('hour', MAX(_loaded_at), CURRENT_TIMESTAMP)
FROM fact_opex
HAVING DATEDIFF('hour', MAX(_loaded_at), CURRENT_TIMESTAMP) > 18;
