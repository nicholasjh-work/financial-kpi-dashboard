# Executive Financial KPI Dashboard

Board-quality P&L, margin, and OPEX dashboard built on Snowflake and Power BI. Covers revenue, gross margin, operating expenses, and variance analysis with a standardized taxonomy (rate, volume, mix, FX, returns). Refreshes from Snowflake and Databricks on a near real-time schedule.

Reduced manual report prep by 30% and cut executive decision turnaround by 25% for monthly and quarterly reviews. Includes a governed KPI dictionary so every metric means the same thing across divisions.

## What this solves

Finance teams at this org ran monthly and quarterly reviews off a patchwork of Excel files, ad hoc SQL pulls, and slide decks assembled by hand. Different analysts calculated gross margin differently. Nobody agreed on whether returns hit the current month or the original invoice month. The CFO's deck took 3 days to assemble and another day to reconcile when someone spotted a discrepancy.

This dashboard replaced that process. One governed data model in Snowflake, one set of DAX measures in Power BI, one KPI dictionary that pins down every formula, grain, and exclusion. The CFO opens the dashboard on Monday morning and it's current through Friday close.

## Repo structure

```
financial-kpi-dashboard/
  sql/
    snowflake_views.sql         Governed reporting views (window functions, CTEs)
    validation_queries.sql      Reconciliation and data quality checks
    refresh_procedure.sql       Snowflake task for scheduled refresh
  dax/
    measures.md                 All DAX measures with business context
    calculated_tables.md        Bridge tables and date intelligence
  docs/
    kpi_dictionary.md           Governed KPI definitions (formula, grain, exclusions)
    dashboard_spec.md           Page layout, slicers, conditional formatting rules
    data_model.md               Star schema, relationships, RLS
    variance_taxonomy.md        Rate, volume, mix, FX, returns decomposition
  scripts/
    validate_refresh.py         Post-refresh validation (row counts, null rates, totals)
    export_kpi_snapshot.py      Snapshot KPI values to CSV for audit trail
  data/
    sample/
      sample_revenue.csv        Synthetic revenue data for local testing
      sample_opex.csv           Synthetic OPEX data
      sample_fx_rates.csv       FX rate table
  tests/
    test_validation.py          Pytest checks for the validation script
  config/
    settings.yaml               Snowflake connection, refresh schedule, alert thresholds
  .env.example
  .gitignore
  requirements.txt
  README.md
```

## Data model

Star schema in Snowflake with three fact tables and six dimensions.

Facts:
- `fact_revenue`: transaction-grain revenue with product, division, customer, and date keys. Includes gross amount, returns, adjustments, net revenue, and COGS.
- `fact_opex`: cost-center-grain operating expenses with budget and actual amounts, expense category, and period.
- `fact_fx_rates`: daily FX rates by currency pair for constant-currency reporting.

Dimensions:
- `dim_division`: division hierarchy (division, region, segment)
- `dim_product`: product hierarchy (product, product line, therapeutic class)
- `dim_cost_center`: cost center with department and function rollups
- `dim_customer`: customer with channel and territory
- `dim_currency`: currency codes and names
- `dim_date`: standard date dimension with fiscal calendar overlay

Relationships are single-direction, many-to-one from fact to dimension. No bidirectional filters except on the date table (required for time intelligence). Row-level security filters the division dimension by user role.

## SQL layer

All reporting views live in `sql/snowflake_views.sql`. They sit between the raw tables and Power BI. The views handle:

- Period-over-period calculations using `LAG()` and `SUM() OVER (ORDER BY month ROWS BETWEEN 11 PRECEDING AND CURRENT ROW)` for rolling 12-month totals
- Gross margin calculation at transaction grain, then rolled up to division and month
- OPEX variance (actual minus budget) at cost center and month grain
- Constant-currency revenue using the FX rate table joined on transaction date
- YTD and QTD running totals using `SUM() OVER (PARTITION BY fiscal_year ORDER BY month)`

Window functions are used throughout. No correlated subqueries. CTEs for readability. Comments explain the business logic, not the SQL syntax.

## DAX measures

All measures are documented in `dax/measures.md` with the business definition, the DAX formula, and notes on where the measure can break if the data model changes.

Key measures:
- Net Revenue, Gross Margin %, OPEX Variance, OPEX Variance %
- Revenue YTD, Revenue QTD, Revenue Rolling 12M
- Prior Period Revenue (same month last year)
- Constant-Currency Revenue (strips FX impact)
- Variance decomposition: rate, volume, mix, FX, returns

Every measure uses `CALCULATE` with explicit filter context. No implicit measures. No `SUMMARIZE` inside measure definitions (known performance issue in large models).

## KPI dictionary

`docs/kpi_dictionary.md` pins down every metric using the governance framework:

- KPI name and business purpose
- Formula with numerator/denominator logic
- Calculation grain vs. reporting grain
- Source tables and views
- Inclusions and exclusions (returns timing, intercompany, test data)
- Date basis (invoice date vs. ship date vs. accounting date)
- Owner and refresh cadence
- Caveats and collision risks

This is the reference document. If a number on the dashboard doesn't match someone's spreadsheet, the dictionary is where the conversation starts.

## Variance taxonomy

The dashboard decomposes total variance into five components:

- **Rate**: change in average selling price, holding volume and mix constant
- **Volume**: change in units sold, holding price and mix constant
- **Mix**: shift in product or customer mix
- **FX**: currency translation impact (constant-currency vs. actual)
- **Returns**: change in return rates or timing

Each component has its own DAX measure and its own visual on the variance bridge page. The decomposition logic is documented in `docs/variance_taxonomy.md` with the algebra and edge cases.

## Dashboard pages

Documented in detail in `docs/dashboard_spec.md`. Six pages:

1. **Executive summary**: KPI cards (revenue, margin, OPEX variance), month-over-month trend, YTD vs. plan
2. **Revenue deep dive**: revenue by division, product line, and customer segment with drill-through
3. **Margin analysis**: gross margin % by division and product, margin bridge (rate/volume/mix)
4. **OPEX tracking**: actual vs. budget by cost center, variance heatmap, top 10 overruns
5. **Variance bridge**: waterfall chart decomposing total revenue variance into rate, volume, mix, FX, returns
6. **Data quality**: row counts, refresh timestamps, null rates, reconciliation checks

Every page has division and date slicers. Conditional formatting highlights items outside threshold (red if OPEX variance > 5% of budget, amber if > 2%).

## Validation

`scripts/validate_refresh.py` runs after each Snowflake refresh and checks:
- Row counts match expected ranges by table
- Null rates in required fields stay below threshold
- Revenue totals reconcile to the GL extract within 0.1%
- No orphan keys in fact-to-dimension joins
- Refresh timestamp is within expected window

Failures write to a log table and trigger an alert via the config threshold settings.

## Getting started

```bash
git clone https://github.com/nicholasjh-work/financial-kpi-dashboard.git
cd financial-kpi-dashboard

# For the Python validation scripts
pip install -r requirements.txt
cp .env.example .env  # fill in Snowflake credentials

# Run validation
python scripts/validate_refresh.py

# Run tests
pytest tests/ -v
```

To build the Power BI dashboard:
1. Connect Power BI Desktop to Snowflake using the views in `sql/snowflake_views.sql`
2. Import the DAX measures from `dax/measures.md`
3. Set up relationships per `docs/data_model.md`
4. Build pages per `docs/dashboard_spec.md`
5. Configure RLS per the security section in `docs/data_model.md`

## Disclaimer

The application code, SQL, and DAX in this repository reflect a financial KPI dashboard delivered for an enterprise finance organization. The actual data and proprietary business logic from that engagement remain confidential. Sample data included here are synthetic and do not represent real financial performance.
