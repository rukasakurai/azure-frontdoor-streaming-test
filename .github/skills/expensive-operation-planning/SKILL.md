---
name: expensive-operation-planning
description: Use before executing, rerunning, or tearing down operations expected to take minutes, cost money, mutate external state, or require propagation/log-ingestion waits: provision/deploy/destroy, migrations, full or large test suites, benchmarks, data-pipeline runs, and GitHub Actions/CI reruns. Check prior evidence, estimate time/cost/risk, decide whether to keep resources alive, and plan parallel work. Do not use for routine local commands or merely editing workflow, pipeline, or migration code.
---
# Expensive Operation Planning

## Examples of expensive operations

- `azd provision` or an E2E workflow provision step: usually several minutes.
- `azd deploy` or a deploy-with-retries workflow step: several to tens of minutes.
- Waiting for Azure Front Door readiness/propagation: often tens of minutes.
- Streaming, KQL, or cache regression tests that depend on deployed services and Log Analytics ingestion: minutes, and sometimes delayed by propagation or ingestion.
- `azd down --purge` / cleanup after E2E: often tens of minutes; avoid doing it until you are sure the environment is no longer useful.
- Rerunning a full GitHub Actions E2E workflow: can be close to hour-scale once provision, deploy, propagation, tests, and cleanup are included.

## Checklist

1. Check existing evidence first: recent workflow runs, logs, deployed state, or prior local outputs.
2. If the task maps to GitHub Actions, use recent runs of the same workflow/branch as timing evidence.
3. Estimate directionally: seconds, minutes, tens of minutes, or hour-scale.
4. If a slow operation is expected, plan what can run in parallel before starting it.
5. Avoid teardown until validation is complete and the environment is no longer useful.
6. While waiting, do independent useful work instead of blocking on polling.

## Parallel work

Before starting a long operation, identify independent work that does not depend on its result: code review, docs, query drafting, local tests, log analysis, issue/PR preparation, or reading related files. Start the long operation only when it can either unblock the next decision or run while other useful work continues.

## GitHub Actions timing evidence

Prefer recent runs from the same workflow and the same branch or pull request. If none exist, use the closest comparable branch or the default branch, and say the estimate is weaker. Use successful runs for baseline duration and failed runs to identify slow or failing steps. Step timestamps are more useful than whole-run duration when provision, deploy, propagation, tests, or cleanup dominate different phases.

```bash
gh run list --workflow "<workflow name>" --limit 10
gh run list --workflow "<workflow name>" --branch "<branch>" --limit 10
gh run view <run-id> --json jobs
```

Do not overfit to one exact duration; cloud and CI timing varies.
