# Snippet for `~/.claude/CLAUDE.md`

Paste the block below into the global `~/.claude/CLAUDE.md`. It's in English
to match the rest of that file. It assumes `lease` and `lease-supabase` are on
the PATH of the agents' Bash tool (see `install.sh`) and that the heartbeat
hook is installed.

---

```markdown
## Shared resources: `lease` (parallel worktrees/agents)

Many agents run in parallel on this machine. Scarce local resources (above all a
local Supabase stack) are arbitrated with `lease` (TTL leases + fencing tokens,
SQLite at ~/.local/state/lease). Rules:

- **Before** `supabase start`, `supabase db reset`, migrations or integration tests
  against local Supabase: run `lease-supabase up` (add `--wait` to queue up to 30m).
  It gives you a slot with its own stack (project_id `<id>_lease<k>`, ports +k*100)
  and prints them. Do **not** run plain `supabase start`.
- Run every Supabase CLI command and anything that talks to the local stack through
  the slot env: `lease-supabase exec -- supabase db reset`,
  `lease-supabase exec -- pnpm test:integration`, or `eval "$(lease-supabase env)"`
  inside a single Bash call. A bare `supabase …` targets the project's default
  stack, which is not yours.
- **When done** with Supabase: `lease-supabase down` (keeps the stack running for a
  warm restart; `--stop` to free RAM). Don't sit on a slot while doing unrelated work.
- Acquire leases on demand, only when you actually need the resource (at any point in
  the session), and release them when done. Your leases are renewed automatically by a
  hook on every tool call. If you go
  idle >15 min they expire, but are only taken if someone else needs
  the slot (no free slot left).
- If you see **"lease: you LOST …"** (hook message) or any `lease` command exits **3**:
  stop using that resource immediately (its stack may now be someone else's) and
  run `lease-supabase up` again before touching Supabase.
- Exit codes: 0 ok · 2 busy (someone holds it; `--wait` or try later) · 3 LOST ·
  4 timeout. On 2, tell the user who holds it instead of fighting for it.
- Never `supabase stop`, `docker stop/rm` or reset a stack you did not get from
  `lease-supabase up` in this session. `lease-supabase status` / `lease ls` show who
  has what.
- Long commands (>15 min) on a leased resource: `lease hold supabase -- <cmd>`.
- Generic resources: `lease acquire <name> [--ttl 30m]` → `<token> <slot>`;
  `lease release <name>`; `lease wait <name>`; `lease ls`.
```
