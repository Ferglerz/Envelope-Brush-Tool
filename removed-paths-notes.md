## Removed Paths (Do Not Reintroduce)

Date: 2026-05-30

- Removed create-path dependence on `BR_EnvGetProperties` min/max in `modules/ops.lua`:
  - no early-return gate on missing `min_val/max_val`
  - no clamping of newly created point values to `min_val/max_val`
- Removed sculpt-path dependence on `BR_EnvGetProperties` min/max in `modules/ops.lua`:
  - no early-return gate on missing `min_val/max_val`
  - no value clamping using `min_val/max_val` during nudge/smooth writeback
- Replaced clamp helper with raw-value sanitization only:
  - old: `clamp_raw_value(v, min_val, max_val, fallback)`
  - current: `sanitize_raw_value(v, fallback)`

Rationale:
- These paths were repeatedly implicated in volume-envelope floor snapping and vertical nudge failure.
- Pan and most other envelopes already behaved correctly without these clamp stages.
