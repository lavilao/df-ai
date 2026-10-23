# Informe: Estrategias y Blueprints del df-ai original (C++) y su porteo a DF 53.16

**Versión:** r3.7 · **Fecha:** 2026-10-23
**Alcance:** análisis sistemático del df-ai original en C++ (~29.400 líneas, DF 0.47.05-r8) y estado de su porteo a Lua puro sobre DFHack 53.16-r3. Este documento es la guía maestra del porteo: qué hacía cada estrategia, cómo lo hacía, qué ya está portado y qué falta.

---

## 1. Resumen ejecutivo

El df-ai original no "dibuja un fuerte": **hace crecer un fuerte como un árbol**. Cada sala se ancla a una *salida* (exit) de una sala ya colocada, registra su cadena de acceso (`accesspath`) hasta la entrada, y la excavación recursiva garantiza que nada se cava sin tener camino. La "inteligencia" del C++ vive en tres motores:

1. **Motor de blueprints** (`plan_setup_blueprint.cpp` + `blueprint_merge.cpp`): fusión plantilla×instancia, 4 conjuntos de colisión (`corridor/interior/no_room/no_corridor`), viabilidad de roca sólida (`can_add_room`), y crecimiento en 3 fases anclado a exits vivos.
2. **Motor de prioridades** (`plan_priorities.cpp`): 67 reglas ordenadas en `plans/generic01.json` que deciden QUÉ se cava y CUÁNDO (stockpile de comida → carpintero → granjas → … → decorar la fortaleza).
3. **Motor de stocks** (`stocks_*.cpp`, ~6.600 líneas): cuotas por categoría escaladas a población, órdenes del administrador con deduplicación, cadenas de producción (bebida → comidas → tela → jabón → papel), motor de forja con selección de metal por uso, y granjas por temporada.

**Estado del porteo r3.7:** los motores 1 y 2 están portados y verificados (895 salas colocadas en el test headless; E2E en vivo en la arena con colocación estricta, 67 reglas disparando, 56 trampas en posiciones únicas). El motor 3 conserva el port r3.5 (cuotas estáticas + órdenes al administrador) — el escalado por población y las cadenas completas son el siguiente gran hito (§9).

---

## 2. Arquitectura del C++ original

| Módulo C++ | Líneas | Responsabilidad | Port Lua (r3.7) |
|---|---|---|---|
| `plan.cpp` + `plan_task.cpp` | 2.374 | Bucle de update (240 ticks), colas de tareas (genérica + muebles), `nrdig`/`wantdig_max` | ✅ `plan.lua` (paridad r3.7) |
| `plan_setup*.cpp` | 2.400 | Colocación de blueprints, outposts de caverna, vetas | ✅ `blueprint.lua` (fases 1-3; vetas/cavernas: pendiente) |
| `plan_priorities.cpp` | 984 | Motor de reglas de prioridad | ✅ `priorities.lua` (7 acciones de 8) |
| `plan_construct.cpp` | 2.069 | Construcción de talleres/almacenes/granjas + mobiliario | ⚠️ parcial (sin selección de materiales ni `makeroom`) |
| `plan_assign.cpp` | 581 | Asignación de dormitorios/comedores/cuartel | ⚠️ parcial (3 niveles en getbedroom; usuarios de muebles: pendiente) |
| `room.cpp` | 511 | Ciclo de vida de sala, designaciones, `is_dug` | ✅ `rooms.lua` (paridad de formas r3.6) |
| `blueprint_*.cpp` | 1.817 | Formato de plantillas, fusión, cache de colisiones | ✅ `blueprint.lua` (fusión+cache completos) |
| `stocks*.cpp` | ~6.600 | Producción, cuotas, forja, granjas, comercio | ⚠️ parcial (§6) |
| `population*.cpp` | ~5.500 | Labores, militar, salud, nobleza, mascotas | ⚠️ parcial (§7) |
| `embark.cpp` | 866 | Selección de sitio y auto-embark | ✅ `embark.lua` (flujo v50 completo) |
| `camera.cpp` / `pause.cpp` | — | Cámara, despausa con guardián | ✅ portados |

---

## 3. Motor de blueprints (portado en r3.7)

### 3.1 Los datos

- **`plans/generic01.json`**: `start`, `outdoor[]`, `tags{}`, `count_as{}`, `limits{}`, `instance_limits{}`, `priorities[]` (67 reglas), `padding ±16`, `max_failures: 300`.
- **`rooms/templates/<tipo>/<variante>.json`**: `f[]` (muebles: `type, construction, dig, x/y/z` **relativos a `r.min`**, `target, has_users, ignore, makeroom, internal, stairs_special`) y `r[]` (salas: `type`, subtipos, `min/max`, `accesspath[]` (índices hermanos), `layout[]` (índices de muebles), `exits: [[tag,x,y,z]]` **relativos a `r.min`**, `level, noblesuite, queue, workshop, outdoor, in_corridor, require_walls/floor/stone, remove_if_unused, build_when_accessible`).
- **`rooms/instances/<tipo>/<instancia>.json`**: parches `p[N]` que se aplican sobre entradas con `placeholder: N` — así un template de taller 3×3 se convierte en "Carpintería" o "Destilería", y un template de almacén en "comida" o "piedra". Producto cartesiano: **227 variantes** resultantes.

### 3.2 Fusión y cache de colisiones (`build_cache`)

Por cada variante se precalculan 4 conjuntos de tiles (relativos):
- `corridor`: tiles por donde pueden pasar corredores (bbox de salas corridor/corridor planas, excepto `in_corridor`).
- `interior`: tiles consumidos por el interior de salas.
- `no_room`: donde NO puede ponerse el interior de otra sala (dilatación 3×3 de salas amuralladas; bbox completo de corredores/outdoor/`in_corridor`; los **exits propios quedan excluidos**; `Channel` envenena el tile de abajo, `Ramp` el de arriba).
- `no_corridor`: donde NO pueden pasar corredores (dilatación de salas amuralladas menos exits).

La colocación (`PlanSetup::add`) rechaza si: nuevo.corridor ∩ global.no_corridor, nuevo.interior ∩ global.no_room, nuevo.no_corridor ∩ global.corridor, nuevo.no_room ∩ global.interior.

### 3.3 Viabilidad del mapa (`can_add_room`)

- **Límites**: cada tile de `no_room` y el bbox±(2,2,1) de cada sala deben caer dentro del mapa.
- **Salas outdoor**: sin muros subterráneos, `surface_tile_at(x,y).z == z` (con `require_floor`), sin edificios (el carro de embark queda exento en el port), pasto/bioma si se pide.
- **Salas subterráneas**: el anillo (bbox + 1 en x/y, +1 z arriba) debe ser **roca natural sólida** (forma WALL, no TREE), sin agua (flow/POOL/RIVER/BROOK), sin edificios; además los muebles con `dig` descendente (DownStair/UpDownStair/Channel) no pueden estar sobre una caverna (3×3 debajo sólido).
- **Modo relajado (añadido del port)**: si la colocación estricta no cabe en ningún sitio, se reintenta sin validar roca — el C++ original ABANDONABA la fortaleza; el port prefiere un plan imperfecto a ninguno.

### 3.4 Las 3 fases de crecimiento

1. **start**: el template `generic01_start/stairs.json` (13 salas: entrada 7×7 con 9 DownStair + 40 trampas ignoradas, pozo de escaleras 3×3 en z-1..-4, almacén de comida, carpintería, albañilería, 2 despachos, jaula de liberación). El C++ lo pone en una posición aleatoria del mapa; el port lo ancla cerca del carro (búsqueda espiral desde la entrada).
2. **outdoor**: apiario / trampas de jaula (límite 20-100) / depósito / pozo de mina / granjas exteriores / pastos / torre de foso en tiles de superficie aleatorios.
3. **connect** (el corazón): se elige una **variante aleatoria** entre las disponibles y un **exit vivo aleatorio** que matchee su tag (vía expansión de `tags`: `generic01_generic` → 11 tipos, `generic01_wide` → 3, `generic01_corridor_any` → 2, `generic01_in_corridor` → talleres 1×1). El origen local (0,0,0) de la variante cae exactamente en el tile del exit, y la sala dueña del exit se convierte en el **padre** (`accesspath`). Bucle: re-escan tras cada éxito; parar tras `max_failures` (300) fallos consecutivos.

### 3.5 Post-procesos

- `remove_unused_rooms` (punto fijo): corredores `remove_if_unused` sin hijos se eliminan.
- `handle_stairs_special`: muebles `stairs_special` se adaptan (Up/Down/UpDown/suelo) según escaleras arriba/abajo en el plan final.
- Requisitos mínimos: si algún `limits[x][1]` no se alcanza, el C++ reintenta el plan entero (hasta 25 veces) o abandona; el port acepta el mejor esfuerzo (log).

### 3.6 La cadena de excavación (garantía de accesibilidad)

```
regla de prioridad → wantdig(r, cola) → tarea want_dig
  → hueco libre (nrdig[cola] < max(picos, 2)) → digroom(r)
      → r.status = 'dig' + designaciones REALES
      → RECURSIÓN: digroom(padre) para todo r.accesspath  ← nunca se cava sin camino
      → digroom(almacenes de entrada vinculados al taller)
      → tareas furnish para cada mueble
  → tarea dig_room → is_dug() (formas) → 'dug' → construct_room → …
```

**Bug raíz de r3.5/r3.6** (salas selladas en roca, enanos paralizados): el port radial colocaba salas SIN checks de roca y SIN cadena de acceso; `accesspath` guardaba índices crudos de template en vez de referencias a salas. r3.7 restaura la recursión completa.

---

## 4. Las 67 reglas de prioridad (portadas en r3.7)

Esquema de regla: `{name, action, continue, match{}, match_not[], count:{match, is}}`.
Acciones: `dig`, `dig_immediate`, `unignore_furniture`, `finish`, `past_initial_phase`, `deconstruct_wagons`, `start_ore_search` (`dig_next_cavern_outpost` no portado — requiere outposts de caverna).

**Orden exacto (el que hace al df-ai "listero"):**

| # | Regla | Acción | Condición clave |
|---|---|---|---|
| 0 | Stockpile de comida | dig_immediate (continue) | ningún almacén food nivel 1 sin taller vinculado |
| 1 | Carpintería | dig_immediate (continue) | sin Carpenters |
| 2 | Albañilería | dig_immediate | sin Masons |
| 3-4 | Granjas iniciales (comida/tela) | dig_immediate (continue) | sin farmplot subterráneo del tipo |
| 5 | Vertedero | dig | — |
| 6 | Depósito de comercio | dig | — |
| 7 | Enfermería | dig | sin infirmary |
| 8 | Mecánica | dig | sin Mechanics nivel 1 |
| 9 | Destilería | dig | sin Still nivel 1 |
| 10 | Segundo almacén de comida | dig | 1 solo almacén food |
| 11 | Cocina | dig | sin Kitchen nivel 1 |
| 12 | **Defensas estáticas de entrada** | unignore_furniture (continue) | corredor "fort entrance" → activa el anillo de 40 trampas |
| 13 | Puesto de minería | dig | — |
| 14 | Pozo (cisterna) | dig | — |
| 15 | Taller de artesanos | dig | sin Craftsdwarfs nivel 1 |
| 16 | Segunda albañilería | dig | 1 solo Masons |
| 17 | Horno de carbón | dig | sin WoodFurnace nivel 1 |
| 18 | **Iniciar búsqueda de menas** | start_ore_search (continue) | — |
| 19 | Fundición | dig | sin Smelter nivel 1 |
| 20 | Herrería | dig | sin MetalsmithsForge nivel 1 |
| 21 | Cementerio | dig | sin cemetery |
| 22 | Apiario | dig | — |
| 23-32 | Granjero / Faena / Pesquería / Telar / Sastrería / Jabonero / Carnicería / Lejía / Curtiembre / Marroquinería / Tintorería | dig | sin cada taller nivel 1 |
| 33 | Cárcel | dig | sin jail |
| 34 | **Trampas exteriores** | dig (continue) | corredor outdoor "cage trap" |
| 35-36 | Biblioteca, Templo | dig | sin location del tipo |
| 37 | Torre de foso | dig | — |
| 38 | Puesto de caverna | dig | — |
| 39 | Almacenes nivel 1 | dig | — |
| 40 | **Desmontar carros** | deconstruct_wagons (continue) | — |
| 41 | Talleres nivel 1 restantes | dig | — |
| 42 | **Permitir salas comunes no usadas** | past_initial_phase (continue) | — |
| 43-52 | Nivel 2-3: almacenes, hornos, talleres, cárceles, enfermerías, 2ª taberna/biblioteca/templo, decorar locations | — | — |
| 54 | Siguiente puesto de caverna | dig_next_cavern_outpost | — |
| 55-65 | Más cuarteles, granjas, mobiliario opcional, almacenes/talleres restantes, 3ª locations | — | — |
| 66 | **Decorar la fortaleza** | finish | toda sala no-plan → alisar+grabar |

Semántica `continue`: la regla sigue actuando sobre más salas (hasta que su `count` deje de cumplirse) sin bloquear a las siguientes. Sin `continue`: la primera acción bloquea el tick y la regla queda *latched* (`working`) hasta que ninguna tarea viva matchee sus filtros.

---

## 5. Catálogo de blueprints (templates)

| Template | Salas | Mobiliario clave | Notas |
|---|---|---|---|
| `generic01_start/stairs` | 13 | 9 DownStair, 4×9 UpDownStair, 40 cage_trap (ignore), puertas, sillas makeroom, palanca | el bootstrap completo: entrada → escaleras → primeros talleres |
| `generic01_corridor` (15 variantes) | 1 corredor 3×7 | 2 puertas (ignore) | 8 exits: continuar línea, salas laterales, talleres 1×1; `remove_if_unused` |
| `generic01_corridor_stair` | 1 | 9 UpDownStair `stairs_special` | conecta niveles ±1 |
| `generic01_bedroom` (4 orients.) | 1 dormitorio | cama, puerta | un dormitorio grande cuenta como 39 (`count_as`) |
| `generic01_bedrooms` (4) | 1 corredor + exits 8× bedroom | puertas | bloque de dormitorios |
| `generic01_stockpile` (4) | 3 almacenes apilados nivel 1/2/3 | puertas | placeholder 0 → instancia (food/stone/…) |
| `generic01_workshop_3x3` (4×23 inst.) | 3 talleres + 3 almacenes de entrada | puertas | placeholder 0 = taller, 1 = almacén vinculado |
| `generic01_workshop_1x1` (4×3) | 1 sala 1×1 | quern / nest_box / screwpress (Custom+raw_type) | `in_corridor` |
| `generic01_cage_trap` (1×1, 2×2) | 1 outdoor | trampas en cada tile | límite 20-100 |
| `generic01_cemetery` (4) | cementerio | fila de ataúdes | — |
| `generic01_infirmary` / `jail` / `barracks` | 1 | camas / restricciones+4 cadenas+9 jaulas | cárcel = 4 prisioneros |
| `generic01_location` (4×4 inst.) | 1 | mesas/sillas/estanterías | taberna/biblioteca/templo/gremio |
| `generic01_well` | cisterna + taller de palancas + acueducto | compuertas, palancas (target) | sistema de agua no portado aún |
| `generic01_outdoor_farm` / `underground_farm_*` | 1 granja | — | instancia food/cloth |
| `generic01_pasture` (5 tamaños) | 1 zona | — | presión de pastoreo por fórmula grazer |
| `generic01_depot` / `apiary` / `pitting_tower` / `mineshaft*` / `outpost_entrance` | 1 | — | exteriores |

---

## 6. Estrategia de stocks/producción (C++ — port parcial)

### 6.1 Lo que hace el C++ (resumen técnico)

- **Cadencia**: auditoría completa cada 600 ticks, fases repartidas 1/tick.
- **Cuotas**: `Needed` (base) + `NeededPerDwarf` (por cada 100 enanos) → `num_needed()`. Pedido = `num_needed × 3/2 − count_free`. Tope 30 por orden; mínimo +5 si ya hay cola.
- **`is_item_free`** estricto: no en trabajo/comercio/construcción, contenedor vacío, tile alcanzable desde la entrada.
- **Tier Watch (consumo de excedentes)**: `food_ingredients → PrepareMeal mat_type=4` (banquetes), `drink_plant/fruit → BREW_*` (elige la reacción con más materia prima; cantidad/5), `thread_plant → ProcessPlants`, `cloth_nodye → DyeCloth`, `metal_ore → SmeltOre`, `rough_gem → CutGems`, `tallow+lye → jabón`, `milk → queso`, `wool → SpinThread`, `quire escrito → BIND_BOOK`, goblinito → fundir.
- **Motor de forja** (`queue_need_forge` + `may_forge_bars`): presupuesto de barras por metal (− pedidos pendientes ×4), carbón salvo horno de magma, selección de metal por uso (filo→max_edge+cizalla, contundente→densidad, armadura→yield[IMPACT], proyectil→densidad baja, NO gastar adamantino en armas a distancia), planificador recursivo de fundición (mena → arrabio → acero), barras/item = material_size/3.
- **Granjas** (`stocks_farm.cpp`): por parcela × 4 estaciones, filtro de bioma, primeras parcelas solo EDIBLE_RAW+DRINK, hilanderas o tintóreas, ordenar por semillas disponibles y penalizar lo ya plantado (18/parcela).
- **Anti-bloqueo**: recorte mensual (−3 uds.) de la orden frontal validada que no avanza; `do_now` en tareas críticas; `ban-cooking booze honey tallow seeds`.

### 6.2 Estado del port (`stocks.lua` r3.7)

Portado: clasificación de categorías, conteo, órdenes al administrador con dedup (`compat.create_order`), rutas de mobiliario, granja básica (una planta/parcela).
**Pendiente (prioridad del siguiente hito):** cuotas escaladas por población (`Watch` completo), tier Watch completo (bebida/comidas/tinte/fundición), `is_item_free` estricto, motor de forja con selección de metal, granjas por estación, recorte mensual de órdenes atascadas.

---

## 7. Estrategia de población (C++ — port parcial)

- **Labores**: delegadas por completo a `autolabor`/`labormanager` (`enable` + `PLANT 5 200`, `HERBALIST 1 3`, redimensionado dinámico `HERBALIST 1 ciudadanos/4`). ✅ portado.
- **Militar**: **25% de los ciudadanos** en escuadras; tamaño de escuadra 10/8/6/4 según total; **1 de cada 3 escuadras es de proyectiles**; uniformes "Heavy melee"/"Heavy ranged" (armor entity, exact_matches, sobre la ropa); se recluta a los de MENOR XP primero (protege a los artesanos) y se licencia a los de mayor XP; exenciones (mineros/leñadores/cazadores, nobles, estados de humor); mercenarios residentes SIEMPRE; entrenamiento con `cur_alert_idx = 1`; órdenes de muerte con puntuación de escuadra; `tag_enemies` clasifica amenazas (megabestias → todas las escuadras; no-muertos/invasores → una). ❌ no portado.
- **Salud**: el Médico-Jefe recibe las 5 labores médicas; se nombra solo cuando hay enfermería más allá de 'plan'. ❌ pendiente.
- **Nobleza**: manager/contador/corredor siempre; sheriff/verdugo con cárcel terminada; candidatos = MENOR XP total; contador con precisión máxima; `attribute_noblerooms` excava suites según `required_office/dining/bedroom/tomb` de los raws y alisa/graba hasta el valor objetivo. ❌ pendiente.
- **Muertes**: `want_coffin = 3 + enterrados − ataúdes libres − planificados`; fantasmas → losa conmemorativa grabada (dedup por histfig). ❌ pendiente (el port solo loguea "Need a coffin").
- **Mascotas**: presión de pastoreo `1000 − 11×11×1000/grazer`; sacrificio de adultos no reproductivos (castrados/estériles) y "mantener los 3 más jóvenes" por casta; ordeño/esquilado con tope 30; huevos fértiles prohibidos. ❌ pendiente.
- **Peticiones**: residencia/ciudadanía SIEMPRE aceptadas; parley rechazado; templo/gremio solo si hay sala planeada. ❌ pendiente.

---

## 8. Defensas

- **Anillo de trampas de entrada**: 40 cage_trap con `ignore: true` en el template start; la **regla 12** las activa (unignore) — el C++ además esperaba a que las palancas del cisterno estuvieran enlazadas (los mecanismos son recurso compartido). ✅ portado vía regla 12.
- **Trampas exteriores**: regla 34 + templates 1×1/2×2 (límite 20-100). ✅ portado.
- **Cisterna/pozo + acueducto + compuertas con palancas + tapón de prueba** (`plan_cistern.cpp`, 603 líneas). ❌ pendiente.
- **Respuesta a asedios**: despausa forzada + `tag_enemies` + órdenes de muerte. ⚠️ parcial (despausa portada; tag_enemies en el port antiguo).

---

## 9. Estado del porteo y roadmap

### 9.1 Portado y verificado en r3.7

| Pieza | Verificación |
|---|---|
| Motor de blueprints (fusión × instancias, cache, 3 fases, remove_unused, stairs_special) | test headless: **895 salas** (200 corredores, 225 almacenes, 115 talleres, 18 hornos, 107 granjas, 30 dormitorios…) con invariantes de accesibilidad y sin ciclos |
| Motor de prioridades (filtros, count gates, continue, latching) | test headless: regla 0 dispara `dig_immediate` sobre el almacén de comida y queda latched |
| Cadena wantdig→digroom→dig_room→construct con recursión de accesspath | E2E arena: designaciones reales, salas DUG/FINISHED |
| Fix del bucle de trampas (filtros de items + dedup de tareas + ocupación + tope de reintentos) | E2E arena: **56 trampas, todas en coordenadas únicas** (antes: 7+ por tile); `df.item_type.TRAPPARTS`=67 verificado |
| Configuración de contenidos de almacenes (`bld.settings.flags`) | API verificada en probe (write food-only OK) |
| getbedroom de 3 niveles (cava dormitorio a demanda) | unit test |
| check_rooms/check_idle como tareas PERSISTENTES | unit test + E2E |
| Auto-embark, unpause watchdog, autolabor, heartbeat | sesiones previas |
| Texto de ayuda (`df-ai help`, cabecera para el menú in-game) | — |
| Herramientas DFHack: autochop, seedwatch (all 25), autoclothing (configurables) | E2E: se activan al cargar fortaleza |

### 9.2 Pendiente (ordenado por impacto)

1. **Stocks con cuotas escaladas + tier Watch** (bebida/comidas/tinta/fundición) — el mayor salto de autonomía.
2. **Selección de materiales para talleres** (C++: bloques → piedra no económica → madera; yunque refractario en herrería) y `makeroom` (extents + dueños — sin esto no hay "dormitorios" reales para el juego).
3. **Militar** (escuadras 25%, uniformes, entrenamiento, kill-orders, tag_enemies) + nombramiento de nobles y médico-jefe.
4. **Granjas por estación** (las semillas ya las cubre seedwatch, activo).
5. **Cementerio**: ataúdes con `users`, losas para fantasmas.
6. **Cisterna/pozo** (compuertas+palancas+enlace) — desbloquea el template well completo.
7. **Outposts de caverna + vetas de mena**.
8. **Usuarios de mobiliario compartido** (comedores: mesas/sillas con `users`; cuarteles por escuadra).
9. **Peticiones de residencia, justicia, mascotas.**

---

## 10. Decisión: herramientas DFHack vs código propio

| Herramienta DFHack 53.16 | ¿La usamos? | Justificación |
|---|---|---|
| **autolabor** | ✅ (desde r3.6) | exactamente lo que usaba el C++ (ai.cpp) |
| **autochop** (talar) | ✅ r3.7 | sustituye `Stocks::cuttrees` |
| **seedwatch** | ✅ r3.7 (`all 25`) | sustituye la contabilidad de semillas |
| **autoclothing** | ✅ r3.7 | sustituye las cuotas de ropa (`clothes_*`); gestiona niveles por enano |
| **autogems** | ❌ no existe en 53.16-r3 (verificado en vivo) | el corte de gemas sigue vía stocks |
| **buildingplan** | ❌ por ahora | nuestras colocaciones ya usan `constructBuilding` con filtros (verificado en vivo) |
| **quickfort** | ❌ (reservado) | quickfort aplica blueprints ESTÁTICOS en coordenadas fijas; el valor del df-ai es la colocación ADAPTATIVA. Un "modo legacy" con quickfort perdería la adaptación a la roca. Decisión: motor propio (portado); quickfort queda como plan B documentado |
| **workflow / stockflow** | ❌ | duplicaría el motor de stocks y competiría por las mismas órdenes |
| **automelt** | ⏳ candidato futuro | equivalente al goblinito del C++ |
| **autobutcher** | ⏳ candidato futuro | solapa con la política de mascotas (keep-youngest-3) |

**Conclusión de arquitectura:** híbrido — el "cerebro" (plan/prioridades/militar/comercio) es código df-ai porque ninguna herramienta estándar lo cubre; las automatizaciones repetitivas bien resueltas se delegan (labores, madera, semillas, ropa). Fiel al espíritu del C++: el propio df-ai delegaba labores a autolabor.

---

## 11. Apéndice: constantes críticas (para el porteo)

- Plan: `max_failures` 300 · `padding` ±16 · márgenes de mapa 2/3 · anillo de roca +1 (z+1 solo agua)
- Tareas: 1 genérica + 1 mueble por tick · reinicio de cola cada 240 ticks · `ncheck` 8 (ventana 4×) · `wantdig_max = max(picos, 2)` · peso extra nrdig si volumen ≥ 10
- Stocks: auditoría 600 ticks · pedido `×3/2 − libre` · tope 30 · mínimo +5 · recorte mensual 3 · destilería /5 · banquetes /5 · bloques /4 · flechas 25/tanda · barras/item = material_size/3 · carbón objetivo 12 · madera 16 (×2, tope 30, talas = cantidad/6+1)
- Granjas: penalización 18 por parcela-estación plantada · primera parcela = EDIBLE_RAW+DRINK
- Militar: 25% ciudadanos · escuadras 10/8/6/4 · 1/3 proyectiles · menor XP primero
- Cementerio: 3 + enterrados − libres − planificados · celdas de cárcel = ciudadanos/10
- Pastos: `1000 − 11×11×1000/grazer` acumulado · retiro con < 1/5 de pasto
