Audit the Beacon codebase for TigerStyle compliance.

Read `docs/TIGERSTYLE.md` and `CLAUDE.md` for the full rules. Then scan the target code for violations.

If $ARGUMENTS is provided, audit only that file. Otherwise audit all `.gleam` files in `src/beacon/`.

## What to Check

### 1. No Error Swallowing
- `Error(_) -> Nil` — error silently discarded
- `Error(_) -> []` — error masked as empty result
- `_ -> Nil` catch-all that hides failures
- Any `case` arm that ignores the error variant without logging

### 2. Log Everything
- Public functions in transport/runtime/store/session should log on entry/exit/error
- State transitions must be logged
- Errors must be logged at `error` or `warning` level with context

### 3. Proper Assertions
- `let assert` must have a comment explaining why the invariant is safe
- No `todo` or `panic` in shipped code

### 4. No Fallbacks
- If something fails, it fails loudly with a clear error
- No silent degradation

### 5. No Shortcuts
- No quick fixes that paper over the real problem
- Fix root causes, not symptoms

### 6. No Error Swallowing in FFI
- Check `.erl` files for `catch _:_ -> nil` patterns
- Check `.mjs` files for empty `catch(e) {}` blocks

## Output Format

For each violation:
```
[VIOLATION] file.gleam:42 — Error swallowed: Error(_) -> Nil
  Fix: log.warning("module", "Failed: " <> string.inspect(err))
```

Summary at end:
```
TigerStyle Audit: N files scanned, N violations found
```
