# DAX Measures

Every measure used in the Executive Financial KPI Dashboard. Each entry includes the business definition, the DAX formula, and notes on where it can break.

No implicit measures in this model. All aggregation happens through explicit DAX measures defined here.

---

## Revenue Measures

### Net Revenue
Total revenue after returns and adjustments. Excludes intercompany and test transactions (filtered in the Snowflake view, not in DAX).

```dax
Net Revenue =
SUMX(
    v_rpt_revenue_by_division,
    v_rpt_revenue_by_division[net_revenue]
)
```

Grain note: the source view is already aggregated to division, product_line, month. This measure sums across whatever filter context Power BI applies.

### Net Revenue YTD
Year-to-date revenue using the fiscal calendar.

```dax
Net Revenue YTD =
CALCULATE(
    [Net Revenue],
    DATESYTD(dim_date[calendar_date], "6/30")
)
```

The second argument sets the fiscal year-end to June 30. Change this if the fiscal year-end differs.

### Net Revenue Prior Year
Same period last year. Used for YoY comparison cards and variance calculations.

```dax
Net Revenue PY =
CALCULATE(
    [Net Revenue],
    SAMEPERIODLASTYEAR(dim_date[calendar_date])
)
```

### Net Revenue Rolling 12M
Trailing 12-month revenue. Smooths seasonality.

```dax
Net Revenue R12M =
CALCULATE(
    [Net Revenue],
    DATESINPERIOD(dim_date[calendar_date], MAX(dim_date[calendar_date]), -12, MONTH)
)
```

### Revenue YoY Change %
Percentage change vs. prior year.

```dax
Revenue YoY % =
VAR current_rev = [Net Revenue]
VAR prior_rev = [Net Revenue PY]
RETURN
IF(
    prior_rev = 0,
    BLANK(),
    DIVIDE(current_rev - prior_rev, prior_rev)
)
```

---

## Margin Measures

### Gross Margin %
Net revenue minus COGS, divided by net revenue.

```dax
Gross Margin % =
VAR rev = [Net Revenue]
VAR cost = SUMX(v_rpt_revenue_by_division, v_rpt_revenue_by_division[cogs])
RETURN
IF(
    rev = 0,
    BLANK(),
    DIVIDE(rev - cost, rev)
)
```

Collision risk: if someone filters to a single transaction and the view has already aggregated, the margin percentage is correct only at the view grain (division, product_line, month). Transaction-level margin requires a different source.

### Gross Profit
Absolute gross profit in dollars.

```dax
Gross Profit = [Net Revenue] - SUMX(v_rpt_revenue_by_division, v_rpt_revenue_by_division[cogs])
```

---

## OPEX Measures

### OPEX Actual
Total actual operating expenses.

```dax
OPEX Actual =
SUMX(
    v_rpt_opex_variance,
    v_rpt_opex_variance[actual_opex]
)
```

### OPEX Budget
Total budgeted operating expenses.

```dax
OPEX Budget =
SUMX(
    v_rpt_opex_variance,
    v_rpt_opex_variance[budget_opex]
)
```

### OPEX Variance
Actual minus budget. Positive = over budget.

```dax
OPEX Variance = [OPEX Actual] - [OPEX Budget]
```

### OPEX Variance %
Variance as a percentage of budget.

```dax
OPEX Variance % =
IF(
    [OPEX Budget] = 0,
    BLANK(),
    DIVIDE([OPEX Variance], [OPEX Budget])
)
```

### OPEX Actual YTD
Year-to-date actual OPEX.

```dax
OPEX Actual YTD =
CALCULATE(
    [OPEX Actual],
    DATESYTD(dim_date[calendar_date], "6/30")
)
```

---

## Variance Bridge Measures

These measures decompose total revenue variance into rate, volume, and mix components. The algebra is in docs/variance_taxonomy.md.

### Rate Effect
Change in average selling price, holding volume constant at prior period levels.

```dax
Rate Effect =
SUMX(
    v_rpt_margin_bridge,
    v_rpt_margin_bridge[rate_effect]
)
```

### Volume Effect
Change in units sold, holding price constant at prior period levels.

```dax
Volume Effect =
SUMX(
    v_rpt_margin_bridge,
    v_rpt_margin_bridge[volume_effect]
)
```

### Mix Effect
Residual variance after removing rate and volume effects. Captures shifts in product or customer mix.

```dax
Mix Effect =
SUMX(
    v_rpt_margin_bridge,
    v_rpt_margin_bridge[mix_effect]
)
```

### FX Impact
Currency translation impact from the constant-currency view.

```dax
FX Impact =
SUMX(
    v_rpt_constant_currency_revenue,
    v_rpt_constant_currency_revenue[fx_impact]
)
```

---

## Conditional Formatting Thresholds

These measures drive conditional formatting on the dashboard. They return 1, 0, or -1 for visual indicators.

### OPEX Variance Status
Red if variance exceeds 5% of budget. Amber if between 2% and 5%. Green otherwise.

```dax
OPEX Variance Status =
VAR var_pct = [OPEX Variance %]
RETURN
SWITCH(
    TRUE(),
    var_pct > 0.05, -1,
    var_pct > 0.02, 0,
    1
)
```

### Revenue Trend Status
Red if revenue dropped more than 10% YoY. Amber if between 0% and -10%. Green if positive.

```dax
Revenue Trend Status =
VAR yoy = [Revenue YoY %]
RETURN
SWITCH(
    TRUE(),
    ISBLANK(yoy), 0,
    yoy < -0.10, -1,
    yoy < 0, 0,
    1
)
```
