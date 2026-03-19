# Multi-File Domains

Demonstrates importing custom types from separate domain modules.

## Features

- Types split across files: `domains/auth.gleam` (User, Role) and `domains/items.gleam` (Item)
- Model references external types (`auth.User`, `List(items.Item)`)
- Role selector (Admin/Member/Guest) and toggleable todo list
- Build-time codec generation works across module boundaries

## Run

```bash
cd examples/domains
gleam run
```

Open http://localhost:8080 -- change user role, add items, and toggle completion.
