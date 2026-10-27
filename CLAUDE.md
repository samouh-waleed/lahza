# Lahza — project rules

## Documentation: `docs/` vs `plan-docs/`

This project keeps two documentation folders with different purposes. Follow this split for every doc you write or update.

### `docs/` — committed to the repo
- Architecture, product overview, problem statement, approach, and key decisions.
- Concise and simple: short sections, plain language, no exhaustive lists. A new contributor should understand the project from it in a few minutes.
- Record a decision here once it is made (what and why, briefly), not while it is still being debated.

### `plan-docs/` — local only, never committed
- Ignored by git (`.gitignore`). Never `git add -f` anything in it, and never move its content into `docs/` wholesale.
- Task tracking, progress, and backlog.
- Detailed research notes, competitor deep dives, sources, and benchmarks.
- Full feature lists, open items, risks, and **questions for Waleed**.
- Drafts and anything still undecided.

### When unsure
If it is detail, a working note, or a question, it goes in `plan-docs/`. If it is a stable summary someone needs to understand or build the project, it goes in `docs/`. Keep the two in sync: when a `plan-docs/` decision is settled, add the short version to `docs/`.
