-- Governed reporting views for the Executive Financial KPI Dashboard.
-- These views sit between the raw Snowflake tables and Power BI.
-- Power BI connects to these views, not to raw tables.
--
-- Naming convention: v_rpt_ prefix = reporting view, governed, tested.
-- All views are read-only. No write operations.

-- Revenue by division and month with period-over-period and rolling totals.
-- Grain: one row per division, product_line, month.
-- Source: fact_revenue joined to dim_division, dim_product, dim_date.
-- Returns are netted against the original invoice month, not the return month.
CREATE OR REPLACE VIEW reporting.v_rpt_revenue_by_division AS
WITH base AS (
    SELECT
        d.division,
        d.region,
        p.product_line,
        p.therapeutic_class,
        dt.fiscal_year,
        dt.fiscal_quarter,
        DATE_TRUNC('month', dt.calendar_date)                       AS month,
        SUM(f.gross_amount)                                          AS gross_revenue,
        SUM(f.return_amount)                                         AS returns,
        SUM(f.adjustment_amount)                                     AS adjustments,
        SUM(f.gross_amount + f.return_amount + f.adjustment_amount)  AS net_revenue,
        SUM(f.cogs)                                                  AS cogs,
        SUM(f.quantity)                                              AS units_sold
    FROM fact_revenue f
    JOIN dim_division d   ON f.division_id = d.division_id
    JOIN dim_product p    ON f.product_id = p.product_id
    JOIN dim_date dt      ON f.date_key = dt.date_key
    WHERE f.is_intercompany = FALSE
      AND f.is_test_data = FALSE
    GROUP BY d.division, d.region, p.product_line, p.therapeutic_class,
             dt.fiscal_year, dt.fiscal_quarter, DATE_TRUNC('month', dt.calendar_date)
),
with_comparatives AS (
    SELECT
        b.*,
        -- Gross margin at the pre-aggregated grain
        CASE
            WHEN b.net_revenue = 0 THEN 0
            ELSE (b.net_revenue - b.cogs) / b.net_revenue
        END AS gross_margin_pct,

        -- Prior year same month
        LAG(b.net_revenue, 12) OVER (
            PARTITION BY b.division, b.product_line
            ORDER BY b.month
        ) AS net_revenue_py,

        -- Rolling 12-month net revenue
        SUM(b.net_revenue) OVER (
            PARTITION BY b.division, b.product_line
            ORDER BY b.month
            ROWS BETWEEN 11 PRECEDING AND CURRENT ROW
        ) AS net_revenue_r12m,

        -- YTD net revenue (resets each fiscal year)
        SUM(b.net_revenue) OVER (
            PARTITION BY b.division, b.product_line, b.fiscal_year
            ORDER BY b.month
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS net_revenue_ytd,

        -- Month-over-month revenue change
        LAG(b.net_revenue, 1) OVER (
            PARTITION BY b.division, b.product_line
            ORDER BY b.month
        ) AS net_revenue_prior_month,

        -- Rank divisions by revenue within each month (for top-N filtering)
        RANK() OVER (
            PARTITION BY b.month
            ORDER BY b.net_revenue DESC
        ) AS division_revenue_rank
    FROM base b
)
SELECT * FROM with_comparatives;


-- OPEX actual vs budget by cost center and month.
-- Grain: one row per cost_center, expense_category, month.
-- Source: fact_opex joined to dim_cost_center, dim_date.
-- Budget is loaded monthly. Actuals refresh daily.
CREATE OR REPLACE VIEW reporting.v_rpt_opex_variance AS
WITH monthly_opex AS (
    SELECT
        cc.cost_center_name                                       AS cost_center,
        cc.department,
        cc.function_area,
        f.expense_category,
        DATE_TRUNC('month', dt.calendar_date)                     AS month,
        dt.fiscal_year,
        dt.fiscal_quarter,
        SUM(f.actual_amount)                                      AS actual_opex,
        SUM(f.budget_amount)                                      AS budget_opex
    FROM fact_opex f
    JOIN dim_cost_center cc ON f.cost_center_id = cc.cost_center_id
    JOIN dim_date dt        ON f.date_key = dt.date_key
    WHERE f.is_test_data = FALSE
    GROUP BY cc.cost_center_name, cc.department, cc.function_area,
             f.expense_category, DATE_TRUNC('month', dt.calendar_date),
             dt.fiscal_year, dt.fiscal_quarter
)
SELECT
    m.*,
    m.actual_opex - m.budget_opex AS opex_variance,
    CASE
        WHEN m.budget_opex = 0 THEN NULL
        ELSE (m.actual_opex - m.budget_opex) / m.budget_opex
    END AS opex_variance_pct,

    -- YTD actual and budget
    SUM(m.actual_opex) OVER (
        PARTITION BY m.cost_center, m.expense_category, m.fiscal_year
        ORDER BY m.month
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS actual_opex_ytd,
    SUM(m.budget_opex) OVER (
        PARTITION BY m.cost_center, m.expense_category, m.fiscal_year
        ORDER BY m.month
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS budget_opex_ytd,

    -- Prior year actual for trending
    LAG(m.actual_opex, 12) OVER (
        PARTITION BY m.cost_center, m.expense_category
        ORDER BY m.month
    ) AS actual_opex_py,

    -- Running 3-month average (smooths monthly noise)
    AVG(m.actual_opex) OVER (
        PARTITION BY m.cost_center, m.expense_category
        ORDER BY m.month
        ROWS BETWEEN 2 PRECEDING AND CURRENT ROW
    ) AS actual_opex_3m_avg
FROM monthly_opex m;


-- Constant-currency revenue.
-- Joins fact_revenue to fact_fx_rates to strip currency translation effects.
-- Grain: one row per division, month, currency.
-- Base currency is USD. Constant rate = average rate from the comparison period.
CREATE OR REPLACE VIEW reporting.v_rpt_constant_currency_revenue AS
WITH revenue_with_currency AS (
    SELECT
        d.division,
        DATE_TRUNC('month', dt.calendar_date)  AS month,
        cur.currency_code,
        SUM(f.gross_amount + f.return_amount + f.adjustment_amount) AS net_revenue_local,
        SUM(f.quantity) AS units_sold
    FROM fact_revenue f
    JOIN dim_division d    ON f.division_id = d.division_id
    JOIN dim_date dt       ON f.date_key = dt.date_key
    JOIN dim_currency cur  ON f.currency_id = cur.currency_id
    WHERE f.is_intercompany = FALSE
      AND f.is_test_data = FALSE
    GROUP BY d.division, DATE_TRUNC('month', dt.calendar_date), cur.currency_code
),
fx AS (
    -- Monthly average FX rate and prior year rate for constant-currency calc
    SELECT
        currency_pair,
        DATE_TRUNC('month', rate_date)   AS month,
        AVG(rate)                        AS avg_rate,
        LAG(AVG(rate), 12) OVER (
            PARTITION BY currency_pair
            ORDER BY DATE_TRUNC('month', rate_date)
        ) AS avg_rate_py
    FROM fact_fx_rates
    GROUP BY currency_pair, DATE_TRUNC('month', rate_date)
)
SELECT
    r.division,
    r.month,
    r.currency_code,
    r.net_revenue_local,
    r.net_revenue_local * fx.avg_rate       AS net_revenue_usd,
    r.net_revenue_local * fx.avg_rate_py    AS net_revenue_constant_currency,
    -- FX impact = actual USD revenue minus what it would have been at prior year rates
    (r.net_revenue_local * fx.avg_rate) - (r.net_revenue_local * COALESCE(fx.avg_rate_py, fx.avg_rate))
        AS fx_impact
FROM revenue_with_currency r
LEFT JOIN fx ON fx.currency_pair = r.currency_code || '/USD'
           AND fx.month = r.month;


-- Margin bridge components for variance decomposition.
-- Calculates rate, volume, and mix effects between current and prior period.
-- Grain: one row per division, product_line, month.
-- This is the hardest view. The algebra is documented in docs/variance_taxonomy.md.
CREATE OR REPLACE VIEW reporting.v_rpt_margin_bridge AS
WITH current_period AS (
    SELECT
        division,
        product_line,
        month,
        net_revenue,
        cogs,
        units_sold,
        CASE WHEN units_sold = 0 THEN 0 ELSE net_revenue / units_sold END AS avg_price,
        CASE WHEN units_sold = 0 THEN 0 ELSE cogs / units_sold END       AS avg_cost
    FROM reporting.v_rpt_revenue_by_division
),
prior_period AS (
    SELECT
        division,
        product_line,
        month,
        LAG(net_revenue, 1) OVER w   AS net_revenue_pp,
        LAG(cogs, 1) OVER w          AS cogs_pp,
        LAG(units_sold, 1) OVER w    AS units_pp,
        LAG(CASE WHEN units_sold = 0 THEN 0 ELSE net_revenue / units_sold END, 1) OVER w AS avg_price_pp,
        LAG(CASE WHEN units_sold = 0 THEN 0 ELSE cogs / units_sold END, 1) OVER w        AS avg_cost_pp
    FROM reporting.v_rpt_revenue_by_division
    WINDOW w AS (PARTITION BY division, product_line ORDER BY month)
)
SELECT
    c.division,
    c.product_line,
    c.month,
    c.net_revenue,
    c.cogs,
    c.net_revenue - c.cogs AS gross_profit,
    p.net_revenue_pp,
    p.cogs_pp,
    COALESCE(p.net_revenue_pp, 0) - COALESCE(p.cogs_pp, 0) AS gross_profit_pp,

    -- Rate effect: change in price * prior period volume
    (c.avg_price - COALESCE(p.avg_price_pp, 0)) * COALESCE(p.units_pp, 0) AS rate_effect,

    -- Volume effect: change in volume * prior period price
    (c.units_sold - COALESCE(p.units_pp, 0)) * COALESCE(p.avg_price_pp, 0) AS volume_effect,

    -- Mix effect: residual (total change minus rate and volume)
    -- This captures the interaction term between price and volume changes.
    (c.net_revenue - COALESCE(p.net_revenue_pp, 0))
        - ((c.avg_price - COALESCE(p.avg_price_pp, 0)) * COALESCE(p.units_pp, 0))
        - ((c.units_sold - COALESCE(p.units_pp, 0)) * COALESCE(p.avg_price_pp, 0))
    AS mix_effect

FROM current_period c
JOIN prior_period p ON c.division = p.division
                   AND c.product_line = p.product_line
                   AND c.month = p.month;
