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
  `lease-supabase exec -- pnpm test:integration`. A bare `supabase …` targets the
  project's default stack, which is not yours. `exec` also exports the names apps
  read (`SUPABASE_URL`, `NEXT_PUBLIC_SUPABASE_URL`, `VITE_SUPABASE_ANON_KEY`…; more
  with `LEASE_SUPABASE_ALIASES=NAME=SOURCE,…`), which win over the app's `.env`.
- **Dev servers and anything long-running against the stack go through
  `lease-supabase exec -- pnpm dev`**: it keeps the slot renewed while the process
  lives and stops the process if the slot is lost. A dev server started any other
  way silently ends up talking to another project's database once your lease
  expires and someone else takes the slot. Each stack has its own JWT secret, so a
  stale app gets 401s: if you see unexpected 401s, check `lease-supabase status`.
  `exec` keeps renewing for at most 4h (`lease hold --max`); after that the slot is
  kept only while nobody else needs it.
- **When done** with Supabase: `lease-supabase down` (keeps the stack running for a
  warm restart; `--stop` to free RAM). It also stops what you launched with `exec`.
  Don't sit on a slot while doing unrelated work.
- Acquire leases on demand, only when you actually need the resource (at any point in
  the session), and release them when done. Your leases are renewed automatically by a
  hook on every tool call. If you go
  idle >15 min they expire, but are only taken if someone else needs
  the slot (no free slot left).
- If you see **"lease: you LOST …"** (hook message or an Orca message) or any `lease`
  command exits **3**: stop using that resource immediately (its stack may now be
  someone else's) and run `lease-supabase up` again before touching Supabase.
- Exit codes: 0 ok · 2 busy (every slot held; `--wait` to queue) · 3 LOST ·
  4 timeout. On 2, tell the user who holds it instead of fighting for it. The number
  of slots (`lease capacity`) is the user's decision: never change it yourself.
- Never `supabase stop`, `docker stop/rm` or reset a stack you did not get from
  `lease-supabase up` in this session. `lease-supabase status` / `lease ls` show who
  has what.
- Long commands (>15 min) on a leased resource that don't go through
  `lease-supabase exec`: `lease hold <res> -- <cmd>`.
- Generic resources: `lease acquire <name> [--ttl 30m]` → `<token> <slot>`;
  `lease release <name>`; `lease wait <name>`; `lease ls`. App ports that clash
  between worktrees (3000, Redis…): `lease acquire app-port` and use
  `PORT=$((3000 + slot))` (the user sets `lease capacity app-port N` once).
```
