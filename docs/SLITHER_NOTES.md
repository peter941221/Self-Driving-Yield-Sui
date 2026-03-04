# Slither Notes

This file records the latest Slither findings and rationale.


## Latest Run

- Command: `slither . --exclude-dependencies --exclude incorrect-equality,timestamp,low-level-calls,naming-convention,cyclomatic-complexity`

- Date: 2026-02-23

- Result: 0 findings after exclusions.


## Excluded Detectors (CLI)

The following detectors are excluded via CLI flags because they are expected for this design:

- `incorrect-equality`: zero checks are intentional guard clauses.

- `timestamp`: time-based controls are required for TWAP and cooldowns.

- `low-level-calls`: `staticcall` is required for ABI optionality.

- `naming-convention`: `IAsterDiamond.ALP()` is upstream ABI.

- `cyclomatic-complexity`: `_increaseLp()` branching is inherent to swap/add flow.


## Inline Suppressions

- `divide-before-multiply`: annotated in math-heavy sections to avoid false positives.

- `reentrancy-no-eth` / `reentrancy-benign`: guarded by `nonReentrant`, annotated on entrypoints.


## Action

- Run Slither with the exclude list and review only new warnings.
