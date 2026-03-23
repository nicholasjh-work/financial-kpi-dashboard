# Calculated Tables

Bridge tables and date intelligence setup in Power BI.

## Date table marking

The `dim_date` table must be marked as the date table in Power BI for time intelligence functions to work.

```
In Power BI Desktop:
1. Select dim_date in the model view
2. Table tools > Mark as date table
3. Select calendar_date as the date column
```

Without this, `DATESYTD`, `SAMEPERIODLASTYEAR`, and `DATESINPERIOD` will fail silently or return wrong results.

## Fiscal calendar columns

The dim_date table includes fiscal calendar columns (fiscal_year, fiscal_quarter, fiscal_month) loaded from Snowflake. No DAX calculated columns needed for fiscal periods.

If the fiscal year-end changes from June 30, update the Snowflake dim_date generator and the DAX `DATESYTD` measures (which use the `"6/30"` parameter).

## No calculated tables in this model

All aggregation and bridge logic lives in Snowflake views. The Power BI model imports pre-shaped data. No DAX calculated tables or `SUMMARIZE`-based tables are used.

This is a deliberate choice. Calculated tables that duplicate or reshape imported data increase model size and create a second source of truth. If the shape needs to change, change the Snowflake view.
