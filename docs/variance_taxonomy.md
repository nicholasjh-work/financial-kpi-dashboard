# Variance Taxonomy

How the dashboard decomposes total revenue variance into five components. This is the math behind the variance bridge page.

## The five components

| Component | What it measures | Formula |
|---|---|---|
| Rate | Price change impact | (avg_price_current - avg_price_prior) * units_prior |
| Volume | Unit change impact | (units_current - units_prior) * avg_price_prior |
| Mix | Product/customer mix shift | Total variance - rate - volume |
| FX | Currency translation impact | revenue_actual_usd - revenue_constant_currency |
| Returns | Change in return rates | Calculated separately from return_amount delta |

## Why this decomposition

The CFO and board need to understand whether revenue grew because we sold more units, charged higher prices, shifted toward higher-value products, or just got lucky on FX. "Revenue was up 8%" is not actionable. "Revenue was up 8%, driven by 5% volume growth in Division A and 4% pricing, partially offset by unfavorable FX of -1%" is.

## The algebra

Start with total revenue variance:

```
delta_revenue = revenue_current - revenue_prior
```

Decompose into rate and volume using prior period as the base:

```
rate_effect   = (price_current - price_prior) * units_prior
volume_effect = (units_current - units_prior) * price_prior
```

The interaction term (price changed AND volume changed simultaneously) lands in mix:

```
mix_effect = delta_revenue - rate_effect - volume_effect
```

This is a standard decomposition. The rate and volume formulas use the prior period as the base. Some finance teams use the current period as the base, which flips where the interaction term lands. We use prior-period base because it matches how most board decks present the walk.

## FX impact

FX impact is calculated separately using the constant-currency view:

```
fx_impact = revenue_at_actual_rates - revenue_at_prior_year_rates
```

The constant-currency view (`v_rpt_constant_currency_revenue`) multiplies local-currency revenue by the prior year average FX rate. The difference between actual-rate revenue and constant-currency revenue is the FX impact.

## Edge cases

**Division with zero prior-period revenue.** Rate and volume effects are undefined (division-by-zero on avg_price_prior). The SQL view returns 0 for rate and volume effects. All variance lands in mix. This is correct behavior for a new division.

**Product line discontinued mid-year.** Current period revenue is zero. Rate effect is zero (no current price). Volume effect is negative (units dropped to zero at prior price). Mix absorbs the rest. The variance bridge will show a large negative volume bar, which is accurate.

**Large returns in a single month.** Returns reduce net_revenue in the invoice month, not the return month. A $5M return posting in March against January invoices makes January revenue drop retroactively. The variance bridge for January will show a large negative, but the March bridge will not. If someone asks why January "changed," point them to the return_amount column.

**FX on zero-revenue currencies.** If a currency has transactions in the current period but none in the prior year (new market entry), there's no prior-year rate. The view uses the current-year rate as a fallback, so FX impact is zero. This is the right behavior: there's no FX comparison to make for a new market.

## Implementation

The decomposition happens in two places:

1. `sql/snowflake_views.sql` in the `v_rpt_margin_bridge` view, which calculates rate, volume, and mix at the division + product_line + month grain.
2. `dax/measures.md` in the Rate Effect, Volume Effect, Mix Effect, and FX Impact measures, which sum the pre-calculated components across whatever filter context the user selects.

The SQL does the heavy math. DAX just aggregates. This keeps the Power BI model simple and the calculations auditable in SQL where they're easier to test.
