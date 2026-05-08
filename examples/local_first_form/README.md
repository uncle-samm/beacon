# Local First Form

Focused example for Beacon's `Model` + `Local` split.

It exercises:

- Draft input, filter selection, and dropdown state in `Local`
- Submit/save state in `Model`
- Instant client rendering for local-only interactions
- Server-authoritative update only when the form is submitted

```sh
cd examples/local_first_form
gleam run -m local_first_form
```

Open http://localhost:8080.
