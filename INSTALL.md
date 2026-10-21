# Installing df-ai for Dwarf Fortress 53.16 (DFHack 53.16-r3)

## Instalación rápida (español)

**No hay nada que compilar** — df-ai es ahora un plugin 100% Lua.

1. Descarga `df-ai-53.16-r3.zip` desde la página de [**Releases**](../../releases)
   (o desde *Actions* → última ejecución → *Artifacts*).
2. Extrae el ZIP **dentro de tu carpeta de Dwarf Fortress** (la que contiene
   `hack/`). Debe quedar así:
   ```
   dwarf fortress/
   ├── hack/scripts/df-ai.lua
   ├── hack/scripts/df-ai/          (10 módulos .lua)
   ├── df-ai-blueprints/plans/      (generic01.json)
   ├── df-ai-blueprints/templates/  (82 plantillas de salas)
   └── ...
   ```
3. Arranca el juego con DFHack 53.16-r3 (Steam: simplemente lanzar el juego;
   Classic: ejecutar `dfhack` / `./Dwarf Fortress`).
4. En la consola de DFHack escribe:
   ```
   enable df-ai
   ```
5. Carga o crea una fortaleza. Al entrar al mapa verás
   `[df-ai] AI starting up` en la consola.
6. Consulta el estado con `df-ai` o `df-ai status`.

> Nota: crea tu fortaleza manualmente (embark normal, "Prepare carefully" o
> "Play now"). La automatización de embark existe (`df-ai/embark`) pero está
> desactivada por ahora. `enable df-ai` debe ejecutarse ANTES de cargar el
> mapa para que arranque solo; si ya estás en la fortaleza, escribe
> `enable df-ai` de nuevo y recarga (`die` no es necesario).

Si algo falla, copia el texto de error de la consola de DFHack y repórtalo
en [Issues](../../issues).

---

## Quick start (English)

**Nothing to compile** — df-ai is now a pure-Lua plugin. The Lua scripts run
directly inside DFHack's embedded Lua 5.3 interpreter on any platform
(Windows / Linux / macOS).

### Requirements

- Dwarf Fortress **53.16** (Steam or Classic — Linux Classic 64-bit is the
  tested platform)
- DFHack **53.16-r3**

### Option A — from a release archive (recommended)

1. Download `df-ai-53.16-r3.zip` from the [Releases page](../../releases)
   (or grab the `df-ai-53.16-r3-<run>` artifact from the latest successful
   [Actions run](../../actions)).
2. Extract it into your Dwarf Fortress installation folder — the folder that
   contains `hack/`. Merge folders if asked.
3. Start the game (with DFHack) and type in the DFHack console:
   ```
   enable df-ai
   ```

### Option B — from a git checkout

```sh
git clone -b lua-53.16-r3 https://github.com/lavilao/df-ai.git
cd df-ai
# scripts
cp -r hack/scripts/df-ai.lua hack/scripts/df-ai "<DF dir>/hack/scripts/"
# fortress blueprints (REQUIRED — the plan loader needs these)
mkdir -p "<DF dir>/df-ai-blueprints"
cp -r plans "<DF dir>/df-ai-blueprints/plans"
cp -r rooms/templates "<DF dir>/df-ai-blueprints/templates"
```

> You can also drop the whole repo folder inside your DF folder and symlink
> `hack/scripts/df-ai*` — the loader tries both
> `df-ai-blueprints/templates/` (release layout) and
> `df-ai-blueprints/rooms/templates/` (repo layout).

### Commands

| Command | Effect |
|---|---|
| `enable df-ai` | Activate the AI (persists in `dfhack-config/df-ai.json` via `enable` scripts init) |
| `df-ai` / `df-ai status` | Population / plan / stocks summary |
| `df-ai version` | Print version |
| `df-ai report` | Write `df-ai-report.json` |
| `df-ai abandon` | Abandon the fortress (dangerous!) |

Once enabled, the AI starts automatically whenever a fortress map loads
(`SC_MAP_LOADED`). It will dig and furnish the planned fortress, manage
labors, queue manager orders, and watch stocks. Configuration lives in
`dfhack-config/df-ai.json`.

### Port status (what to expect)

Ported to 53.16 and load-tested headless (all 11 modules load, 0 API audit
failures, 82 room templates parse). The in-fortress behavior is the current
testing focus — when you load a fortress you should see:

```
[df-ai] AI starting up
[df-ai] Loaded plan config + 82 templates
```

...followed by periodic `[df-ai]` log lines as it plans rooms and queues
digging. If you hit an error or a silent stop, please open an issue with
the console output — the `WORKLOG.md` at the repo root tracks known issues.

### Why Lua? (for former C++ users)

The original df-ai was a C++ DFHack plugin. DF v50+ removed/rewrote almost
every structure the C++ code depended on (renderer hooks, viewscreen
internals, `ui` → `plotinfo`, etc.), so the port is a ground-up Lua rewrite
on DFHack's first-class Lua plugin API. The old C++ sources remain in the
repo for reference. See `MIGRATION_TO_50.md` and `WORKLOG.md` for the full
analysis.
