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
│   └── df-ai-blueprints/instances/ (instancias: talleres/almacenes tipados)
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

> **Embark automático (nuevo)**: con `enable df-ai` activo, df-ai conduce el
> flujo pre-fortaleza: título → crear mundo → worldgen → "Play now!" →
> tipo Fortress → selección de sitio → Embark → "Play Now". Sigue los
> mensajes `[df-ai embark]` en la consola; si un paso no avanza solo (la
> inyección de input depende del entorno), la consola te dice exactamente
> qué botón pulsar — como máximo 1-2 clicks. Config en
> `dfhack-config/df-ai.json`: `embark_mode` = `"quick"` (el juego elige el
> sitio, 100% automático) o `"scored"` (df-ai puntúa todos los tiles del
> mundo y elige el mejor: tierra, calmado, no malvado, vegetado, templado).
> Si ya estás dentro de una fortaleza, `enable df-ai` arranca el AI al
> momento.

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
cp -r rooms/instances "<DF dir>/df-ai-blueprints/instances"
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

### Auto-embark

With `enable df-ai` active from the title screen, df-ai drives the whole
pre-fortress flow: worldgen guidance, "Play now!" after worldgen, Fortress
mode, site selection, Embark, and Play Now. Watch the `[df-ai embark]`
console messages — if a step cannot advance on its own (input injection
depends on the environment), the console tells you exactly which button
to click (at most 1-2 clicks).

Config options in `dfhack-config/df-ai.json`:
- `embark_mode`: `"quick"` (default — the game's quick start picks a
  forested mineral-rich site, fully automatic) or `"scored"` (df-ai scores
  every world tile — land, calm, not evil, vegetated, temperate — writes
  the best embark rectangle into the site screen, then presses Embark).
- `random_embark`: set to `false` to disable auto-embark entirely.

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


### Auto-embark behavior (r3.3)

With `enable df-ai` active at the title screen:

- **Fort save present** (default): df-ai selects "Continue Playing" and
  loads your most recent fortress automatically. Set
  `"embark_continue_fort": false` in `dfhack-config/df-ai.json` to always
  start a NEW fortress instead.
- **World present, no fort**: "Start Playing" → first world → Fortress.
- **No saves at all**: "Create New World" → world generation runs
  automatically → "Play now!" → Fortress.
- The site screen runs a quick start (the game's own recommended site) or,
  if that dialog is unavailable, our scored site selection (calm, non-evil,
  vegetated, temperate land — the chosen tile's raw values are printed to
  the console).
- On the embark screen the last green **[Embark]** button may need one
  manual click on some setups — the console tells you when. Once the map
  loads, the AI takes over: `[df-ai] AI starting up` → templates → rooms →
  digging.

### Why Lua? (for former C++ users)

The original df-ai was a C++ DFHack plugin. DF v50+ removed/rewrote almost
every structure the C++ code depended on (renderer hooks, viewscreen
internals, `ui` → `plotinfo`, etc.), so the port is a ground-up Lua rewrite
on DFHack's first-class Lua plugin API. The old C++ sources remain in the
repo for reference. See `MIGRATION_TO_50.md` and `WORKLOG.md` for the full
analysis.


## r3.7 notes

- The blueprint placement engine + 67 priority rules are active: the fort
  now GROWS from the entrance (rooms anchor to live exits, accesspath
  recursion digs parents first). See `docs/INFORME_ESTRATEGIAS.md` for the
  full strategy report (Spanish).
- df-ai now enables stock DFHack automation: autochop, seedwatch,
  autoclothing (each toggleable in `dfhack-config/df-ai.json`, set
  `dfhack_tools` to `false` to disable all).
- `df-ai help` prints the full command list; the script header now shows
  a description in the DFHack in-game menu.
