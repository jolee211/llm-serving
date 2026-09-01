# Guardrails

Two layers, because they catch different things.

## 1. Budget alarm (lagging, catches spend)

AWS Budgets, $25/month, email at 40% actual, 100% actual, and 100% forecasted. Budgets emails direct, so there is no SNS topic and no subscription confirmation.

```bash
aws budgets create-budget \
  --account-id 976545639267 \
  --budget file://budget.json \
  --notifications-with-subscribers file://budget-notifications.json \
  --profile personal
```

Verify:

```bash
aws budgets describe-budgets --account-id 976545639267 --profile personal \
  --query 'Budgets[].[BudgetName,BudgetLimit.Amount,CalculatedSpend.ActualSpend.Amount]' --output text
```

Caveat: Budgets evaluates roughly daily. A GPU left running Friday evening surfaces Saturday, maybe Sunday. That is a real improvement over Monday, but it is not fast.

## 2. Idle resource check (immediate, catches the actual mistake)

`idle-resource-check.sh` lists running instances, clusters, and filesystems. Exits 0 when clean, 1 with a report when not. No lag.

This is the one that matches the failure mode. The lab has now been left running twice, and both times the problem was a resource nobody looked at, not a budget nobody watched.

Run it at the end of every session, or wire it to a scheduled task that pings in the evening.

## Why $25

Normal lab shape is $3-5 per session and $0 on idle weeks. A $25 monthly ceiling is roughly five good sessions, so 40% ($10) is a real signal rather than noise. August 2026 hit $115.83 with a $67.58 extended-support line, and the Aug 28-30 weekend leak added $66.01, so both incidents would have tripped the 40% notice within a day.
