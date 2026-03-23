# Data Model

Star schema connecting three fact tables to six dimensions in Snowflake. Power BI imports the governed views, not the raw tables.

## Fact tables

### fact_revenue
One row per invoice line. This is the transaction grain.

| Column | Type | Notes |
|---|---|---|
| transaction_id | VARCHAR | Primary key. One per invoice line. |
| division_id | VARCHAR | FK to dim_division |
| product_id | VARCHAR | FK to dim_product |
| customer_id | VARCHAR | FK to dim_customer |
| currency_id | VARCHAR | FK to dim_currency |
| date_key | INTEGER | FK to dim_date (invoice date) |
| gross_amount | DECIMAL(15,2) | Revenue before returns and adjustments |
| return_amount | DECIMAL(15,2) | Negative value. Netted against invoice month. |
| adjustment_amount | DECIMAL(15,2) | Credit memos, price corrections |
| cogs | DECIMAL(15,2) | Direct cost of goods sold |
| quantity | INTEGER | Units on the invoice line |
| is_intercompany | BOOLEAN | TRUE for intercompany transfers. Excluded from reporting views. |
| is_test_data | BOOLEAN | TRUE for test transactions. Excluded from reporting views. |
| _loaded_at | TIMESTAMP_NTZ | ETL load timestamp |

Join risk: transaction_id should be unique. Duplicates here inflate revenue. Validation query #5 in `sql/validation_queries.sql` checks for this.

### fact_opex
One row per cost center, expense category, and accounting month.

| Column | Type | Notes |
|---|---|---|
| cost_center_id | VARCHAR | FK to dim_cost_center |
| date_key | INTEGER | FK to dim_date (accounting period) |
| expense_category | VARCHAR | Expense line item category |
| actual_amount | DECIMAL(15,2) | Actual spend |
| budget_amount | DECIMAL(15,2) | Budgeted amount. Null if budget not loaded. |
| is_test_data | BOOLEAN | Excluded from reporting views |
| _loaded_at | TIMESTAMP_NTZ | ETL load timestamp |

Join risk: the grain is cost_center + expense_category + month. If the ETL loads the same month twice without deduplication, actuals double. The refresh procedure checks for this.

### fact_fx_rates
One row per currency pair per day.

| Column | Type | Notes |
|---|---|---|
| currency_pair | VARCHAR | Format: 'EUR/USD', 'GBP/USD' |
| rate_date | DATE | The trading date |
| rate | DECIMAL(12,6) | Exchange rate (units of USD per 1 unit of foreign currency) |

## Dimension tables

### dim_division
| Column | Notes |
|---|---|
| division_id | Primary key |
| division | Division name |
| region | Geographic region |
| segment | Business segment |

Used for row-level security in Power BI. The RLS filter sits on this table.

### dim_product
| Column | Notes |
|---|---|
| product_id | Primary key |
| product_name | |
| product_line | Groups products for mid-level reporting |
| therapeutic_class | Top-level product grouping |

### dim_cost_center
| Column | Notes |
|---|---|
| cost_center_id | Primary key |
| cost_center_name | |
| department | Department rollup |
| function_area | Function rollup (e.g., R&D, SG&A, Manufacturing) |

### dim_customer
| Column | Notes |
|---|---|
| customer_id | Primary key |
| customer_name | |
| channel | Sales channel (direct, distributor, retail) |
| territory | Sales territory |

### dim_currency
| Column | Notes |
|---|---|
| currency_id | Primary key |
| currency_code | ISO 4217 code |
| currency_name | |

### dim_date
Standard date dimension with fiscal calendar overlay. Generated for 5 years (current year plus/minus 2).

| Column | Notes |
|---|---|
| date_key | Integer key (YYYYMMDD format) |
| calendar_date | DATE |
| fiscal_year | Fiscal year (July-June) |
| fiscal_quarter | 1-4 |
| fiscal_month | 1-12 (fiscal month number) |
| calendar_month | 1-12 |
| calendar_quarter | 1-4 |
| day_of_week | Monday-Sunday |
| is_business_day | FALSE for weekends and US holidays |

## Relationships in Power BI

All relationships are single-direction, many-to-one, from fact table to dimension.

| From | To | Key | Direction |
|---|---|---|---|
| v_rpt_revenue_by_division | dim_division | division | Single |
| v_rpt_revenue_by_division | dim_product | product_line | Single |
| v_rpt_revenue_by_division | dim_date | month -> calendar_date | Single |
| v_rpt_opex_variance | dim_cost_center | cost_center -> cost_center_name | Single |
| v_rpt_opex_variance | dim_date | month -> calendar_date | Single |

The dim_date relationship is the only one marked as the date table for time intelligence. `DATESYTD`, `SAMEPERIODLASTYEAR`, and `DATESINPERIOD` all rely on this.

No bidirectional filtering except on dim_date (required for time intelligence DAX functions). Adding bidirectional filters elsewhere will break RLS and degrade query performance.

## Refresh strategy

Import mode. Scheduled refresh daily at 6:30 AM UTC via Power BI Service. Snowflake task completes by 6:00 AM. The 30-minute gap gives the validation script time to run and flag issues before Power BI pulls the data.

If the validation script reports a failure, the data engineering team is alerted. The Power BI refresh still runs (no automatic hold), but the Data Quality page shows the failure so the FP&A team knows the data may be stale or incomplete.
