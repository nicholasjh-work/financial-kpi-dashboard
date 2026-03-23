# Dashboard Specification

Build spec for the Executive Financial KPI Dashboard in Power BI.

## Business objective

Give the CFO and division heads a single view of financial performance that replaces the manual slide deck assembly process. The dashboard should answer "how did we do this month" and "where are we off plan" without anyone opening Excel.

## Primary audience

CFO, VP Finance, division heads, FP&A analysts.

## Decisions supported

- Monthly close review: is revenue on track, which divisions are underperforming
- OPEX management: which cost centers are over budget, by how much, and is it trending
- Quarterly board prep: variance decomposition for the earnings narrative
- Pricing review: rate vs. volume effects on revenue changes

## Data source

Power BI connects to the governed Snowflake views in `sql/snowflake_views.sql`. No direct table connections. The views handle joins, filtering (intercompany, test data), and pre-aggregation.

Import mode with scheduled refresh (daily at 6:30 AM UTC, 30 minutes after the Snowflake task completes). DirectQuery is not used because the variance bridge calculations require cross-row operations that perform better on an imported model.

## Global slicers (appear on every page)

- **Division**: multi-select dropdown from dim_division
- **Date range**: relative date slicer defaulting to current fiscal year
- **Fiscal quarter**: single-select buttons (Q1, Q2, Q3, Q4, Full Year)

Division slicer respects row-level security. A division head only sees their division. The CFO sees all.

---

## Page 1: Executive Summary

**Purpose:** High-level health check. The page the CFO opens first on Monday morning.

**Layout:**

Top row (4 KPI cards):
- Net Revenue (current month) with YoY % change indicator
- Gross Margin % (current month) with YoY pp change
- OPEX Variance (current month, absolute $) with red/amber/green indicator
- Net Revenue YTD vs. plan (bar-in-bar showing actual vs. budget)

Middle section:
- Line chart: monthly net revenue (current year vs. prior year), 13-month window
- Clustered bar: revenue by division (current month), sorted descending

Bottom section:
- Table: top 5 cost centers by OPEX variance %, with conditional formatting (red > 5%, amber > 2%)

**Conditional formatting:**
- KPI cards: green up arrow if improving YoY, red down arrow if declining
- Revenue bars: gray for current month, light gray for prior year
- OPEX table: cell background color based on OPEX Variance Status measure

---

## Page 2: Revenue Deep Dive

**Purpose:** Let FP&A analysts explore revenue by dimension without building ad hoc queries.

**Layout:**

Top: Slicer bar with product line (multi-select) and customer segment (multi-select) in addition to the global slicers.

Left half:
- Stacked bar chart: monthly revenue by product line, 13-month window
- Matrix: revenue by division (rows) and fiscal quarter (columns), with sparklines showing monthly trend in the last column

Right half:
- Treemap: revenue by customer segment, sized by net revenue, colored by YoY change %
- Table: top 20 customers by revenue, showing current month, prior year, and YoY %

**Drill-through:** Click any division or product line to open a detail page showing monthly revenue, units, and average price for that selection.

---

## Page 3: Margin Analysis

**Purpose:** Understand profitability drivers.

**Layout:**

Top row (2 KPI cards):
- Gross Margin % (current month)
- Gross Profit (current month, absolute $)

Left:
- Line chart: gross margin % by division, trailing 12 months
- Each division is a separate line. Limit to top 5 divisions by revenue; group others as "Other."

Right:
- Waterfall chart: margin bridge showing rate, volume, mix effects for selected period
- This chart uses the v_rpt_margin_bridge view. Each bar is one component.

Bottom:
- Scatter plot: divisions plotted by revenue (x-axis) vs. gross margin % (y-axis). Bubble size = units sold. This shows which divisions are high-revenue-low-margin vs. the reverse.

---

## Page 4: OPEX Tracking

**Purpose:** Budget vs. actual by cost center. Where are we overspending.

**Layout:**

Top: Slicer for department and expense category (in addition to global slicers).

Left:
- Clustered bar: actual vs. budget by department (horizontal bars, sorted by variance)
- Line chart: OPEX actual by month with 3-month rolling average overlay

Right:
- Heatmap matrix: cost centers (rows) by month (columns), cell color = OPEX variance %. Red cells are the problem areas.
- Table: top 10 cost centers by absolute variance, showing actual, budget, variance, variance %, and trend sparkline

**Conditional formatting:**
- Heatmap cells: continuous color scale from green (under budget) through white (on budget) to red (over budget)
- Table rows: bold font on any row where variance % exceeds 5%

---

## Page 5: Variance Bridge

**Purpose:** Decompose total revenue variance for the earnings narrative. This is the page that feeds the board deck.

**Layout:**

Single waterfall chart taking full page width:
- Starting bar: prior period revenue
- Rate effect bar (green if positive, red if negative)
- Volume effect bar
- Mix effect bar
- FX impact bar
- Returns impact bar (if applicable)
- Ending bar: current period revenue

Below the chart:
- Table showing the same numbers with division-level breakout. Each row is a division; columns are rate, volume, mix, FX, returns, total variance.

Period selector: toggle between month-over-month and year-over-year.

---

## Page 6: Data Quality

**Purpose:** Operational monitoring page for the FP&A team and data engineering. Not shown in executive presentations.

**Layout:**

Top row (3 cards):
- Last refresh timestamp
- Total row count in fact_revenue
- Total row count in fact_opex

Middle:
- Table: validation check results from the most recent run of `scripts/validate_refresh.py`. Columns: check name, status (pass/fail), detail.
- Bar chart: null rates by field for fact_revenue and fact_opex

Bottom:
- Line chart: daily row counts over the past 30 days (should be stable; spikes or drops indicate load issues)
- Table: orphan key counts by join path

---

## Row-Level Security

Configured in Power BI Desktop using roles:

| Role | Filter | Who gets it |
|---|---|---|
| CFO | No filter (sees all divisions) | CFO, VP Finance |
| Division Head | `dim_division[division] = USERNAME()` | Division heads |
| FP&A Analyst | No filter (sees all, needed for cross-division analysis) | FP&A team |

Security is enforced on the `dim_division` table. Because all fact tables join to dim_division through a single-direction relationship, the filter propagates automatically.

Test RLS before publishing by using "View as Role" in Power BI Desktop with a test account for each role.

---

## Performance Notes

- Model size is under 500 MB in import mode. Refresh takes about 4 minutes.
- The variance bridge view (`v_rpt_margin_bridge`) is the heaviest query. It joins the revenue view to itself via LAG windows. Pre-aggregation in Snowflake keeps this under 10 seconds.
- Avoid adding bidirectional relationships beyond the date table. Each bidirectional filter multiplies query complexity.
- Do not use implicit measures. Every visual references an explicit DAX measure from `dax/measures.md`.
