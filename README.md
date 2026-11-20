# lease

## Para empezar (explicado fácil)

### El problema

Tienes varios agentes de Claude trabajando a la vez, cada uno en su worktree.
En la máquina hay cosas que **no se pueden usar dos a la vez**, sobre todo el
Supabase local: solo hay un juego de puertos, y si un agente hace
`supabase db reset` mientras otro está pasando tests, le rompe el trabajo.

### La idea: un semáforo con préstamos que caducan

`lease` es como el **mostrador de préstamo de una biblioteca**:

1. Un agente pide el recurso → `lease acquire supabase`. Si está libre, se lo
   prestan **por 15 minutos** y le dan un número de préstamo (el *token*).
2. Si otro agente lo pide mientras tanto → le dicen **"ocupado, lo tiene X"**
   (exit 2). Puede esperar (`lease wait`) o hacer otra cosa.
3. Cuando termina, lo devuelve → `lease release supabase`.
4. ¿Y si se olvida de devolverlo o se cuelga? El préstamo **caduca solo**: a los
   15 min sin renovar, o en cuanto su sesión de Claude muere. Nadie se queda
   bloqueado para siempre.
5. Si a alguien le caducó el préstamo y otro se lo llevó, cuando el primero
   vuelva le dicen **"lo has perdido"** (LOST, exit 3) para que no siga
   tocando algo que ya no es suyo.

### ¿Quién renueva el préstamo? El hook (automático)

Para que un agente que **está trabajando** no pierda el préstamo a los 15 min,
hay un hook de Claude Code que en cada tool call dice "sigo aquí" y renueva
**los préstamos que ese agente tenga**.

- **No hay que hacer nada al empezar la sesión.** El hook está siempre
  instalado y, si el agente no tiene nada prestado, no hace nada (una consulta
  de ~30 ms y fuera).
- El agente pide el recurso **cuando lo necesita**, a mitad de sesión, las veces
  que quiera. Desde ese momento el hook lo mantiene vivo; cuando lo devuelve, el
  hook vuelve a no hacer nada.
- Si el agente se queda parado (>15 min sin tool calls) o se cierra, el
  préstamo caduca y otro puede usarlo.
- Lo único ligado al arranque: Claude lee `settings.json` al iniciar, así que
  las sesiones que ya estaban abiertas al instalar el hook puede que no lo
  tengan hasta reiniciarlas. Sin hook, `lease` funciona igual, pero el préstamo
  caduca a los 15 min aunque estés trabajando (usa `--ttl 2h` o `lease hold`).

### Supabase: un stack por "plaza"

Con `lease-supabase` el recurso tiene **plazas** (slots). Cada plaza es un
Supabase entero y separado, con sus propios puertos:

| plaza | puertos (API / DB / Studio) | nombre del stack |
|---|---|---|
| 0 | 54321 / 54322 / 54323 | `<proyecto>_lease0` |
| 1 | 54421 / 54422 / 54423 | `<proyecto>_lease1` |
| k | +k·100 | `<proyecto>_lease<k>` |

Con `lease capacity supabase 2` pueden trabajar dos agentes a la vez, cada uno
en su plaza. No se toca el `config.toml` del repo.

### El día a día de un agente (5 comandos)

```sh
lease-supabase up                            # "préstame una plaza" (arranca su Supabase)
lease-supabase exec -- supabase db reset     # usar SU Supabase (no el de por defecto)
lease-supabase exec -- pnpm test:integration
lease-supabase down                          # "ya he terminado" (devuelve la plaza)
lease ls                                     # ¿quién tiene qué?
```

`exec` es importante: un `supabase …` a secas apunta al stack por defecto, que
no es el tuyo. `exec` le pasa los puertos y el nombre de tu plaza.

### Ver cómo va todo: `lease top`

Abre una pestaña y deja corriendo:

```sh
lease top              # se refresca cada 2 s; q para salir
lease top --once       # una sola foto (para pegarla en un chat)
```

Verás tres bloques:

1. **Quién tiene qué**: cada recurso y plaza, quién la tiene (`worktree@rama`),
   desde cuándo y cuánto le queda. Verde = ocupada y renovándose; amarillo =
   lleva más de 2 min sin renovar (agente parado o comando largo); rojo =
   caducada o con la sesión muerta (cualquiera puede quedársela); gris = libre.
2. **Stacks de Supabase**: lo que corre de verdad en docker, cruzado con las
   plazas: stack con dueño, plaza libre con su stack aún encendido ("warm"),
   stacks que no gestiona `lease` (p. ej. el de `myapp`), o plaza
   ocupada sin stack.
3. **Últimos movimientos**: préstamos, devoluciones, caducidades y "robos"
   (en rojo). Las renovaciones del hook no salen, serían ruido.

Solo mira: no libera ni para nada. Sin colores fuera de una terminal o con
`NO_COLOR=1`.

### Puesta en marcha (una vez)

```sh
./install.sh                                    # pone lease y lease-supabase en el PATH
./install.sh --settings ~/.claude/settings.json # instala el hook (ver "Instalación" para Orca)
lease capacity supabase 2                       # cuántos Supabase a la vez
```

Y pega [`docs/claude-snippet.md`](docs/claude-snippet.md) en `~/.claude/CLAUDE.md`
para que los agentes sepan usarlo.

### Palabras raras

- **Lease**: préstamo con fecha de caducidad (no un candado eterno).
- **TTL**: cuánto dura el préstamo si nadie lo renueva (15 min por defecto).
- **Token**: número del préstamo. Cada préstamo nuevo tiene uno distinto, así se
  sabe si el tuyo sigue valiendo.
- **Holder**: quién tiene el préstamo (tu pestaña de Orca / sesión de Claude).
- **Slot / plaza**: una de las N copias de un recurso.
- **Steal**: alguien se queda un préstamo caducado. Es normal y queda registrado
  en `lease log`.

---

## Referencia

Semáforo de recursos compartidos para agentes en paralelo (worktrees de Orca +
Claude Code). Leases con TTL y fencing tokens sobre SQLite: sin daemon, sin
servidor, sin dependencias (bash 3.2 + `sqlite3` + `ps`, todo de serie en macOS).

```
$ lease ls
RESOURCE       SLOT STATE    HOLDER                           PID SINCE     LEFT      META
supabase          0 held     myapp@feature-x        38187 10:32:59  14m12s    {"project_id":"myapp_lease0",…
supabase          1 free     -                                  - -         -         (last: {"project_id":"myapp_lease1",…
```

- **Lease, no lock**: "es mío hasta las 10:42". Si no se renueva antes, cualquiera puede quedárselo.
- **Fencing token**: cada acquire nuevo genera uno. Si te dan por muerto y otro se lo queda, tu `renew`/`release` devuelve **LOST** (exit 3).
- **Capacidad N** (v2): un recurso tiene N slots; acquire da el slot libre más bajo.
- **Heartbeat sin depender del modelo**: un hook de Claude Code renueva los leases del agente en cada tool call.
- **`lease-supabase`**: un stack de Supabase por slot (project_id y puertos propios) sin tocar el `config.toml` commiteado.

## Instalación

```sh
./install.sh                 # symlinks lease, lease-supabase, lease-heartbeat (idempotente)
./install.sh --print-hook    # muestra el JSON del hook
./install.sh --settings <ruta/settings.json>   # además mete el hook (backup + diff; idempotente)
./install.sh --uninstall [--settings …]        # deshace ambas cosas
tests/run.sh                 # tests (bash puro, ~1 min)
```

`install.sh` elige el primer directorio **escribible y presente en `$PATH`** de
`~/.local/bin`, `/opt/homebrew/bin` y `/usr/local/bin` (o `--bin-dir`). Ojo: el
Bash tool de Claude Code en esta máquina **no** tiene `~/.local/bin` en el PATH
(sí `/opt/homebrew/bin`), así que ejecútalo desde la misma clase de shell que
usan los agentes, o pasa `--bin-dir`. Settings solo se tocan con `--settings`.

### ¿Qué `settings.json` cargan de verdad los agentes? (Orca)

Lo investigado en esta máquina:

- Las sesiones de Orca corren con `CLAUDE_CONFIG_DIR=~/Library/Application Support/orca/claude-profiles/<id>/home`, y Claude Code lee **`$CLAUDE_CONFIG_DIR/settings.json`**, no `~/.claude/settings.json`.
- Ese `settings.json` del perfil es una **copia** (otro inodo) de `~/.claude/settings.json`. Orca la sincroniza clave a clave (`hooks`, `env`, `permissions`…) desde `~/.claude/settings.json` al preparar el perfil, y guarda hashes por clave en `claude-profiles/<id>/settings-sync.json`. Además inyecta sus propios hooks.
- Hay 3 perfiles. `claude-profiles/selected-host` apunta al activo; los otros dos están desfasados (los sincroniza cuando se usan).

Recomendación: meter el hook en **`~/.claude/settings.json`** (fuente de verdad, y
la que usa `claude` fuera de Orca) **y** en el `settings.json` del perfil activo,
para que aplique ya sin esperar a la resincronización:

```sh
./install.sh --settings ~/.claude/settings.json \
             --settings "$HOME/Library/Application Support/orca/claude-profiles/<id>/home/settings.json"
```

Las sesiones de Claude ya abiertas pueden no recargar los hooks: el heartbeat
aplica con seguridad a los agentes que arranquen después.

## Uso

```
lease ls [<res>] [--json] [--mine]
lease acquire <res> [--ttl 15m] [--meta JSON] [--json]   → "<token> <slot>"
lease wait <res> [--timeout 30m] [--interval 5s] [opts de acquire]
lease renew <res> [<token>] [--ttl D]
lease release <res> [<token>]
lease hold <res> [<token>] [--pid P] [--interval D] [-- cmd …]
lease renew-mine [--hook]
lease token <res>                         → "<token> <slot>" si lo tienes
lease meta <res> [<token>] --set JSON      (merge en el meta de tu lease)
lease slot-meta <res> <slot> [--set JSON]  (meta persistente del slot; set exige tenerlo)
lease capacity <res> [<N>]
lease resource-meta <res> [--set JSON]   (config compartida del recurso, p. ej. puertos de lease-supabase)
lease log [<res>] [-n 50]
lease whoami
lease top [--interval 2s] [--once] [-n N]
```

- `token` es opcional en `renew`/`release`/`hold`/`meta`: si no lo pasas se usa el lease del holder actual. Cada Bash tool call es un shell nuevo, así que los agentes no tienen que guardarlo. Si lo pasas, se valida (fencing).
- Re-adquirir siendo el mismo holder es idempotente: devuelve el mismo token y slot y renueva.
- Duraciones: `90s`, `15m`, `2h`, `1d` o segundos a secas.
- `hold … -- cmd` renueva mientras corre `cmd`, devuelve su exit code y, si el lease se pierde, mata `cmd` y sale con 3. Sin `-- cmd`, renueva mientras viva `--pid` (por defecto el proceso que lo llama). No libera el lease al terminar.

### `lease top`

`lease top [--interval 2s] [--once] [-n LINEAS_LOG]`: vista en vivo de solo
lectura (tabla de slots + paneles + log sin `renew`). Los **paneles** son
cualquier ejecutable `lease-*` junto a `bin/lease` que responda a `panel`
(hoy `lease-supabase panel`); la primera línea es el título. `LEASE_TOP_PANELS`
(lista separada por `:`) los fija a mano; vacío = ninguno. Así `lease` sigue
sin saber nada de Supabase. Cada panel tiene 8 s de límite.

El log guarda el id del holder (`orca:<pane>`); la tabla `holders` (schema v2,
se migra sola desde v1) recuerda su última etiqueta `worktree@rama` para
mostrarla.

### Exit codes (estables)

| code | significado |
|---|---|
| 0 | ok |
| 1 | error / uso incorrecto |
| 2 | **BUSY**: no hay slot libre (stderr dice quién lo tiene) |
| 3 | **LOST**: ese token ya no es tuyo (caducó y se lo quedaron, o lo liberaste) / no tienes lease |
| 4 | **TIMEOUT** en `wait` |
| 5 | no encontrado (p. ej. `lease-supabase` fuera de un proyecto con `supabase/`) |

### Variables de entorno

`LEASE_DB` (default `~/.local/state/lease/lease.db`), `LEASE_HOLDER`, `LEASE_PID`
(`0` = solo TTL), `LEASE_LABEL`, `LEASE_TTL` (default `15m`),
`LEASE_AGENT_PROCS` (default `claude`), `LEASE_BUSY_TIMEOUT_MS` (15000).

## Protocolo para agentes

Snippet listo para `~/.claude/CLAUDE.md`: [`docs/claude-snippet.md`](docs/claude-snippet.md). En resumen:

1. Antes de Supabase/tests de integración: `lease-supabase up` (o `lease acquire <res>`). Si da 2, `--wait` o avisar.
2. Comandos contra el stack, siempre con el entorno del slot: `lease-supabase exec -- …`.
3. Al acabar: `lease-supabase down` / `lease release <res>`.
4. Mensaje del hook "you LOST" o exit 3 → dejar de tocar el recurso y volver a pedirlo.
5. Nunca parar/resetear stacks ajenos. `lease ls` / `lease-supabase status` para ver el estado.

## Diseño

### Almacén

SQLite en WAL. Cada mutación es un único `sqlite3` con `BEGIN IMMEDIATE`
(writer lock) y `.timeout` (busy wait), así que acquire/renew/release son atómicos
entre procesos. La lógica (buscar el slot libre más bajo, recoger leases muertos,
idempotencia, log) vive en SQL dentro de esa transacción. Además las constraints
`PRIMARY KEY(resource, slot)` y `UNIQUE(resource, holder)` impiden dobles
asignaciones aunque hubiera un fallo de lógica.

Tablas: `resources(name, capacity, meta)`, `leases(resource, slot, holder, label,
token, pid, pid_start, ttl, acquired_at, renewed_at, expires_at, meta)`,
`slots(resource, slot, meta)` (persistente: sobrevive a los leases),
`log(ts, resource, slot, holder, action, detail)` y `lost(…)` (avisos pendientes
para el hook).

### Holder (quién eres)

Primero que exista: `LEASE_HOLDER` → `orca:$ORCA_PANE_KEY` → `orca:$ORCA_TERMINAL_HANDLE`
→ `claude:$CLAUDE_CODE_SESSION_ID` → `pid:<host>:<owner pid>:<cwd>`.

`ORCA_PANE_KEY` (`<tab>:<pane>`) es estable mientras viva el pane y llega tanto al
Bash tool como a los hooks (verificado). Si reinicias el agente en el mismo pane,
el holder es el mismo: el agente nuevo puede re-adquirir y hereda el token. El
hook no renueva leases cuyo PID dueño no sea el agente actual (ver abajo), así que
un lease olvidado por el agente anterior muere solo. Los subagentes (Agent tool)
comparten proceso y entorno, así que son el mismo holder.

### PID dueño (liveness)

Desde el Bash tool, `$PPID` es un `zsh` efímero (verificado: `zsh → claude → zsh
de login → login → Orca Terminal Host`). Desde un hook es un `/bin/sh -c`. El PID
de un lease se decide así:

1. `LEASE_PID` (o `--pid` en `hold`); `0` = sin chequeo de PID.
2. `CLAUDE_PID`, si está y vive. Claude Code lo exporta al Bash tool **y** a los hooks, y es el propio proceso `claude` (verificado).
3. El ancestro más cercano cuyo comando sea `claude` (`LEASE_AGENT_PROCS` para añadir otros agentes), con un solo `ps -A`.
4. `$PPID` (shell interactivo, script…).

Junto al PID se guarda su hora de arranque (`ps -o lstart`): si el PID se reutiliza
con otro proceso, el lease cuenta como muerto.

Un lease está **muerto** si `expires_at <= now` o si su PID ya no existe. Un
acquire sobre un lease muerto es un **steal**: el log registra `expire` (holder
anterior, motivo `ttl|pid`) y `steal` (nuevo holder, "from <anterior>"), y se
encola un aviso `lost` para el holder anterior.

### Heartbeat (hook)

`hooks/lease-heartbeat.sh`, en `PreToolUse` y `PostToolUse` con matcher `*`:

- **No hay que activarlo al empezar la sesión**: corre siempre, y sin leases del agente no hace nada. Los leases se piden a demanda en cualquier momento; desde ese momento el hook los renueva, y al liberarlos vuelve a no hacer nada.
- Ejecuta `lease renew-mine --hook`: extiende en su propio `ttl` cada lease con el mismo holder **y** el mismo PID dueño. Agente activo = renueva solo; agente parado = caduca; agente muerto = PID muerto.
- Si un lease de este agente fue recogido por otro, imprime JSON de hook con `additionalContext` (y `systemMessage`), así que **el modelo se entera de que lo perdió**. Probado de punta a punta con un `claude -p` real: el modelo citó el aviso.
- Siempre exit 0 y en silencio. Sin DB sale al instante. Coste de 30–60 ms por tool call en esta máquina, casi todo arranque de procesos (bash + sqlite3).
- `PreToolUse` además de `PostToolUse`: un comando largo arranca con el TTL entero. Aun así, si un comando dura más que el TTL, usa `--ttl` mayor o `lease hold … -- cmd`.

## `lease-supabase`

```
lease-supabase up [--wait] [--timeout 30m] [--ttl 15m] [--reset | --no-reset] [-x svc,…]
lease-supabase down [--stop | --purge]
lease-supabase status
lease-supabase env [--dotenv | --json]
lease-supabase exec -- <cmd…>          # `supabase` a secas = CLI del proyecto
lease-supabase ports [<slot>]
```

Antes de usarlo: `lease capacity supabase 2` (o los stacks que quepan; default 1) y, si hay un stack sin gestionar en los puertos por defecto, `lease resource-meta supabase --set '{"slot_offset":1}'`.

### Puertos y project_id sin tocar `config.toml` (decisión)

El Supabase CLI acepta **overrides por variable de entorno** de cualquier clave de
`config.toml`, con la forma `SUPABASE_<SECCION>_<CLAVE>`. Lo verifiqué arrancando
stacks de juguete con el CLI 2.120:

| Clave | Variable | Slot k |
|---|---|---|
| `project_id` | `SUPABASE_PROJECT_ID` | `<project_id del config>_lease<k>` |
| `api.port` | `SUPABASE_API_PORT` | 54321 + k·100 |
| `db.port` / `db.shadow_port` | `SUPABASE_DB_PORT` / `SUPABASE_DB_SHADOW_PORT` | +k·100 |
| `db.pooler.port` | `SUPABASE_DB_POOLER_PORT` | +k·100 |
| `studio.port` | `SUPABASE_STUDIO_PORT` | +k·100 |
| `local_smtp.port` (`inbucket.port` en CLI < 2.108) | `SUPABASE_LOCAL_SMTP_PORT` **y** `SUPABASE_INBUCKET_PORT` | +k·100 |
| `…smtp_port` / `…pop3_port` | idem (solo si están definidos en el config) | +k·100 |
| `analytics.port` | `SUPABASE_ANALYTICS_PORT` | +k·100 |
| `edge_runtime.inspector_port` | `SUPABASE_EDGE_RUNTIME_INSPECTOR_PORT` | 8083 + k·100 |
| red docker (`--network-id`) | `SUPABASE_NETWORK_ID` | `lease-supabase` (compartida) |

Los puertos base salen del `config.toml` del proyecto (si los cambió) o de los
defaults. Fórmula: `base + (k + slot_offset) * port_step` (por defecto 0 y 100). Se
configuran para todos con `lease resource-meta supabase --set '{"slot_offset":1,"port_step":100}'`
(o por proceso con `LEASE_SUPABASE_SLOT_OFFSET` / `LEASE_SUPABASE_PORT_STEP`).

Descarté:
- **`env()` en `config.toml`**: obliga a modificar el archivo commiteado.
- **`--workdir` con una copia parcheada**: las edge functions, migraciones y seeds se leerían de la copia y no del worktree, y `db reset` y `migration new` apuntarían al sitio equivocado.

Con variables de entorno el CLI sigue trabajando sobre el worktree real.

**Red compartida**: cada stack de Supabase crea su red docker, y en esta máquina
los address pools de Docker **están agotados** (32 redes, muchas de compose):
`supabase start` fallaba con `all predefined address pools have been fully
subnetted`. `lease-supabase` crea una sola red `lease-supabase` con subnet
explícita (`10.213.0.0/24`, `LEASE_SUPABASE_SUBNET`) que no consume pools, y todos
los slots la comparten. Los nombres de contenedor llevan el project_id, así que no
chocan. `LEASE_SUPABASE_NETWORK=` vuelve al comportamiento normal.

### `up`: el traspaso

1. `lease acquire supabase` (o `wait`), con meta `{repo, worktree, branch, project_id, migrations_hash, slot}`.
2. Busca stacks corriendo con project_id `*_lease<k>`, que son los del slot `k`, de cualquier repo. Si es el suyo y lo arrancó este worktree, lo **reutiliza**. Si no, hace `supabase stop --project-id <ese>`, que **conserva volúmenes**. Solo para stacks de *su* slot: lo comprueba por el sufijo `_lease<k>`.
3. Si algún puerto del slot sigue ocupado (p. ej. un stack sin gestionar en los puertos por defecto, como hoy `myapp` en 5432x), **no lo toca**: libera el lease y falla diciendo qué contenedor es.
4. `supabase start` con el entorno del slot (`-x` para excluir servicios).
5. **Deriva de migraciones**: el meta del slot guarda, por project_id, el hash de `supabase/migrations/` y qué worktree migró esa BD.
   - volúmenes recién creados → nada que hacer (`start` aplica todo);
   - mismo hash → nada;
   - lo migró *este* worktree y ahora hay migraciones nuevas → aviso para `lease-supabase exec -- supabase migration up` (no resetea tu trabajo);
   - lo migró *otro* worktree/rama → `supabase db reset` (por defecto), o solo un aviso con `--no-reset`. `--reset` fuerza el reset.
6. Guarda el nuevo estado en el meta del slot e imprime slot y puertos.

`down` libera y deja el stack corriendo (el siguiente `up` del mismo worktree es
instantáneo). `--stop` lo para conservando volúmenes y `--purge` además borra
los volúmenes.

### Exponer URLs/keys al proyecto

- `lease-supabase exec -- <cmd>`: entorno del slot (`SUPABASE_*` para el CLI) más la salida de `supabase status -o env` (`API_URL`, `DB_URL`, `ANON_KEY`, `SERVICE_ROLE_KEY`, `STUDIO_URL`…). Es lo recomendado para agentes, porque cada Bash call es un shell nuevo.
- `eval "$(lease-supabase env)"`: lo mismo en el shell actual. `--dotenv` / `--json` para otros formatos.
- `LEASE_SUPABASE_OVERRIDE_NAMES=api.url=NEXT_PUBLIC_SUPABASE_URL,auth.anon_key=NEXT_PUBLIC_SUPABASE_ANON_KEY` renombra variables (lo pasa a `supabase status --override-name`).

### Limitaciones conocidas

- **Todo comando `supabase` tiene que ir por `lease-supabase exec`**. Un `supabase db reset` a pelo usa el project_id del config, o sea el stack sin gestionar en los puertos por defecto. Es el riesgo principal y el snippet de CLAUDE.md insiste en ello.
- Si el proyecto tiene URLs/puertos fijos en `.env*`, el entorno del proceso tiene que ganar. Next.js, Vite y dotenv no sobrescriben variables ya definidas, pero hay que usar los mismos nombres (ver `OVERRIDE_NAMES`).
- Mientras siga vivo un stack sin gestionar en los puertos por defecto, el slot 0 choca con él. Desplaza los slots para todos los agentes a la vez con
  `lease resource-meta supabase --set '{"slot_offset":1}'` (slot 0 → +100), o migra ese stack a un slot. La configuración vive en la DB compartida, así que todos usan los mismos `port_step`/`slot_offset`. Las variables `LEASE_SUPABASE_PORT_STEP`/`SLOT_OFFSET` la sobrescriben solo para un proceso.
- La BD de un slot se comparte entre worktrees del mismo repo (volúmenes por repo × slot). Los datos de prueba de uno pueden verlos otros hasta que haya un reset. Los volúmenes se acumulan como mucho repos × slots; `down --purge` los borra.
- `auth.site_url` y las redirect URLs del config no se tocan (son puertos de la app, no de Supabase).
- El `supabase` global de esta máquina (npm, 2.105.0) **muere con SIGKILL** al arrancar (binario con firma ad-hoc). `lease-supabase` usa `node_modules/.bin/supabase` del proyecto, `LEASE_SUPABASE_BIN` o, como último recurso, el del PATH.
- Algún servicio pesado (p. ej. analytics) puede arrancar aunque esté en `-x`, si otro servicio depende de él (pasó en las pruebas).

## Limitaciones de `lease`

- Una sola máquina: los PIDs y el reloj son locales. No uses la DB en un FS de red.
- `wait` es polling con jitter, no una cola FIFO: no hay garantía de orden.
- Un lease caducado pero no reclamado por nadie se **revive** en el siguiente renew de su dueño. Es a propósito: nadie lo tenía.
- El hook solo renueva por actividad del agente. Un agente pensando más de 15 min sin tool calls pierde el lease.
- `capacity` menor que los slots ocupados no expulsa a nadie: esos slots se marcan `held*` hasta que se liberen.
- El holder fallback (`pid:host:pid:cwd`) cambia con cada shell. Fuera de Claude/Orca, fija `LEASE_HOLDER`.

## Tests

`tests/run.sh [filtro]`, en bash puro con una `LEASE_DB` temporal por test. Cubren:
acquire/release, ocupado, expiración por TTL, PID muerto, reutilización de PID,
steal + LOST con token viejo (renew/release/meta), idempotencia del mismo holder,
agente reiniciado en el mismo pane, renew, capacidad y slots (incluido reducirla),
**carreras** (20 procesos con capacidad 1 y 24 con capacidad 3 → exactamente N
ganadores con slots distintos; tormenta de acquire/renew/release sin exceder la
capacidad), `wait` y timeout, `hold` (por PID, `-- cmd`, LOST), `renew-mine`
(incluido no renovar leases de otro PID), el hook (aviso LOST en JSON válido, una
sola vez, nunca falla), meta/slot-meta, `ls --json`, inferencia de holder y PID, y
`lease-supabase` con `docker`/`lsof`/`supabase` simulados (puertos, negarse ante
stacks ajenos, traspaso que solo para el stack de su slot, deriva de migraciones,
env/exec/down).
