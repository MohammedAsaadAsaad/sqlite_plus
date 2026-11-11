# Jobs processing performance follow-up

| Step | Status |
| --- | --- |
| Preserve baseline binary/source fingerprints and profile claim/complete | Complete |
| Optimize measured hot paths without weakening lease/transaction checks | Complete |
| Regression/native/fault/VM+JS checks | Complete locally |
| Repeated AOT depth comparisons and ordinary-operation checks if core changes | Complete; 76 final samples |
| Update README, compatibility matrix and log with actual evidence | Complete |

Preserve existing uncommitted work. No schema migration, publication or push.

## Implementation (frozen for final checks)

- Jobs reads queue scheduling metadata through an ordinary bound equality query,
  selecting priority/creation/ID order in the same exclusive transaction. No
  persistent scheduler cache, payload scan, schema change or weakened lease SQL.
- Core narrows integer rowid AND predicates conservatively; the original WHERE
  still runs on the candidate. Functions, subqueries, generated columns, coercions
  and shadowed aliases retain fallbacks. All row constraints/trigger/FK paths stay.
- Index-preservation checks skip shared unchanged records and resolve the union
  of referenced column offsets once per check. Compare values, never cached values.
- Fix a discovered existing stale equality-read cache after prepared plain INSERT;
  invalidate it before following reads. Regression covers append/rollback/failure.
- First full regressions passed (core 10681+one optional skip, add-ons 514, search 86).
  Final repetition follows the resolved-column optimization. First stage timing
  samples are archived as stage1_runs.json, not mixed into final medians.

## Final result

Original workload median 4016.599 -> 34.278ms (117.2x); file phase 5173.096
-> 1753.273ms. Full 1000-job in-memory drain 3139.026ms; depth 10000/ten pairs 179.613ms.
Core 10681 pass/one optional skip; add-ons 514 and search 86 pass. Final 77 targeted
cases pass after retaining the original append-order cache. Expanded native
subquery comparisons pass separately in all three encodings. VM/JS examples and
fatal-info/affected format checks pass. Evidence: benchmark_results/jobs_performance.

Processing remains O(retained queue depth), and file tests run on tmpfs, not a
physical device. General production/platform/publication gates remain open.
No schema migration, push, merge or publication performed.
