# KPI Dictionary

Governed definitions for every metric on the Executive Financial KPI Dashboard. If a number on the dashboard doesn't match someone's spreadsheet, start here.

---

## Net Revenue

**Business purpose:** Total revenue recognized after returns and adjustments. The primary top-line metric for executive reporting.

**Formula:** `SUM(gross_amount + return_amount + adjustment_amount)`

**Numerator/denominator:** Not a ratio. Additive measure.

**Calculation grain:** Transaction (one row per invoice line in fact_revenue).

**Reporting grain:** Division, product line, month on the dashboard. Can drill to customer and product.

**Source:** `fact_revenue` via `reporting.v_rpt_revenue_by_division`

**Inclusions:** All revenue transactions where `is_intercompany = FALSE` and `is_test_data = FALSE`.

**Exclusions:**
- Intercompany transfers (filtered in the Snowflake view)
- Test transactions (filtered in the Snowflake view)
- Pending orders not yet invoiced (not in fact_revenue until invoiced)

**Date basis:** Invoice date (`dim_date.calendar_date` joined via `date_key`).

**Owner:** FP&A. Refresh cadence: daily by 6 AM UTC.

**Caveats:**
- Returns are netted against the original invoice month, not the return processing month. This matches the accounting treatment but can make recent months look lower than expected if a large return posts late.
- Credit memos reduce gross_amount in the same row. They are not separate transactions.

**Governance risks:**
- Confusion between gross and net revenue. Gross is before returns. Net is after. The dashboard shows net by default.
- Accounting date vs. invoice date. This KPI uses invoice date. The GL uses accounting date. The two can differ by up to 5 business days at period close. Expect small variances against the GL until the period is final.

---

## Gross Margin %

**Business purpose:** Measures profitability after direct costs. Used to compare product lines and divisions.

**Formula:** `(net_revenue - cogs) / net_revenue`

**Numerator:** Net revenue minus cost of goods sold.
**Denominator:** Net revenue.

**Calculation grain:** Transaction grain in the Snowflake view, then aggregated by DAX in Power BI at whatever grain the user selects.

**Reporting grain:** Division, product line, month. Can drill to customer.

**Source:** `reporting.v_rpt_revenue_by_division` (pre-aggregated), consumed by the `Gross Margin %` DAX measure.

**Inclusions:** Same as Net Revenue.

**Exclusions:** Same as Net Revenue. Additionally, COGS only includes direct material and direct labor. Allocated overhead is in OPEX, not COGS.

**Date basis:** Invoice date.

**Owner:** FP&A. Refresh cadence: daily.

**Caveats:**
- Margin at the product level can shift based on how overhead allocation is handled. This KPI does not include overhead. If someone compares this to a fully-loaded margin from the GL, the numbers will differ.
- Division-level margin is a weighted average of product-level margins. A shift in product mix changes division margin even if no individual product margin changed.

**Governance risks:**
- Two analysts can get different gross margin numbers if one uses transaction-level data and the other uses the pre-aggregated view. The view aggregates to division, product_line, month before calculating margin. Transaction-level margin weighted up to division will differ slightly due to rounding. The view is the governed source.

---

## OPEX Variance

**Business purpose:** Tracks spending against plan. Positive values mean over budget.

**Formula:** `SUM(actual_opex) - SUM(budget_opex)`

**Calculation grain:** Cost center, expense category, month.

**Reporting grain:** Cost center, department, month. Can roll up to function area.

**Source:** `reporting.v_rpt_opex_variance`

**Inclusions:** All actual and budget amounts where `is_test_data = FALSE`.

**Exclusions:**
- Capitalized items (these are in the capital budget, not OPEX)
- One-time restructuring charges (excluded by expense category filter if applicable)

**Date basis:** Accounting period (month). Actuals post to the accounting month. Budget is loaded monthly at the start of the fiscal year and does not change after approval.

**Owner:** Corporate Controller. Refresh cadence: actuals daily, budget monthly (or after mid-year reforecast).

**Caveats:**
- Budget is static after approval. If a mid-year reforecast occurs, the reforecast replaces the original budget in the same table. Historical comparisons to the original budget require pulling from the budget version history.
- Timing differences: a $200K vendor payment might hit one month early or late depending on AP processing. The 3-month rolling average in the view smooths this.

**Governance risks:**
- Cost center hierarchy changes. If a cost center is reorganized mid-year, historical actuals stay under the old structure. Budget may have been loaded under the new structure. The variance for that cost center will look wrong until the history is restated.
- Blank budget rows. If a cost center has no budget loaded for a month, the variance equals the full actual amount, which inflates the overrun. The validation query in `sql/validation_queries.sql` (check #6) catches this.

---

## OPEX Variance %

**Business purpose:** Variance normalized by budget. Used for conditional formatting and alerts.

**Formula:** `(actual_opex - budget_opex) / budget_opex`

**Denominator:** Budget OPEX. Returns BLANK when budget is zero.

**Calculation and reporting grain:** Same as OPEX Variance.

**Thresholds:**
- Green: variance % <= 2%
- Amber: variance % between 2% and 5%
- Red: variance % > 5%

---

## Rate Effect (Variance Bridge)

**Business purpose:** Isolates the revenue impact of price changes, holding volume and mix constant.

**Formula:** `(avg_price_current - avg_price_prior) * units_prior`

**Calculation grain:** Division, product line, month.

**Source:** `reporting.v_rpt_margin_bridge`

**Caveats:** The rate effect is calculated using average selling price. If the product mix within a product line shifts (e.g., more units of a lower-priced SKU), some of that shows up in rate rather than mix. True SKU-level decomposition requires a more granular fact table.

---

## Volume Effect (Variance Bridge)

**Business purpose:** Isolates the revenue impact of volume changes, holding price and mix constant.

**Formula:** `(units_current - units_prior) * avg_price_prior`

**Calculation grain:** Division, product line, month.

---

## Mix Effect (Variance Bridge)

**Business purpose:** Captures the interaction between price and volume changes. Represents shifts in product or customer mix.

**Formula:** Total variance minus rate effect minus volume effect (the residual).

**Calculation grain:** Division, product line, month.

**Caveats:** Mix is the catch-all bucket. If the rate and volume decomposition is off, the error lands here. Review this number critically when it's large relative to rate and volume.

---

## FX Impact

**Business purpose:** Strips currency translation effects from revenue comparison. Shows what revenue would have been at prior year exchange rates.

**Formula:** `net_revenue_usd - net_revenue_constant_currency`

**Source:** `reporting.v_rpt_constant_currency_revenue`

**Date basis:** Monthly average FX rate for both current and prior year.

**Caveats:** Uses monthly average rates, not spot rates. Intra-month FX volatility is smoothed out. For entities with high daily transaction volume, this is fine. For entities with a few large transactions, the monthly average may not reflect the actual rate at the time of the transaction.
