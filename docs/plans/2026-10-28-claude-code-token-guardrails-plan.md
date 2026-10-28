---
status: draft
project: claude
date: 2026-10-28
related: [reviews/2026-10-28-claude-code-session-token-audit.md]
---

# Plan: guardrails de contexto y coste para las sesiones de Claude Code (2026-10-28)

## 1. Alcance

**Dentro.** Cambios en la configuración personal de Claude Code (`~/.claude/`), en
el `.claude/` de los repositorios donde se trabaje y en sus `AGENTS.md`, que
reduzcan el coste por sesión y
hagan imposibles las dos causas medidas en
[la auditoría](../reviews/2026-10-28-claude-code-session-token-audit.md): el
contexto sin techo y los forks que lo heredan.

**Fuera.** El agente PLC, el benchmark, el pipeline de `plc-prompts` y cualquier
cosa que pueda mover el resultado de una corrida. Este plan no cambia el
comportamiento del agente que se evalúa; cambia cómo trabajamos nosotros con
Claude Code encima de él. Por eso no lleva entrada en `CHANGELOG.md` mientras se
quede en herramientas de sesión, y sí la llevaría si alguna pieza acaba
versionada como parte del repo.

## 2. Diagnóstico que justifica cada pieza

| Causa medida | Evidencia | Palanca |
|---|---|---|
| Contexto sin techo (754k y 841k) | Ventana nativa de 1M; auto-compact cerca de 950k nunca se activó | `autoCompactWindow` |
| Coste cuadrático en turnos | 440 peticiones, 167 M de lectura en el principal | ventana + `/clear` |
| Forks que heredan el contexto | 6 forks, 38,39 $ = 57% de la sesión | modo fork + guardrail |
| TTL de 5 min en los forks | 7 rebuilds de 787k cada 10 min en `a642592f` | TTL 1 h + cadencia |
| Hooks que inyectan contexto | 272 KB de `hook_success`; 146 KB en `SessionStart:resume` | auditoría del plugin |
| Pastes de terminal de la VM | 15 pastes, 157k chars, ~52k tokens | hábito + skill |
| Thinking nunca limpiado | 213.574 tokens con `keep: "all"` | no configurable; solo acotar turnos |

El principio que ordena el plan: **cuanto más cerca de la configuración y más
lejos de las instrucciones, más garantía y menos coste en contexto.** Un
`CLAUDE.md` que pide moderación se paga en cada turno y no impide nada; un
`autoCompactWindow` se paga una vez y se cumple siempre.

## 3. Propuestas por tipo de herramienta

### 3.1 Settings — prioridad 0

En `~/.claude/settings.json` (alcance usuario: aplica a todos los proyectos).

```json
{
  "autoCompactWindow": 200000,
  "promptCacheTtl": "1h",
  "subagentPromptCacheTtl": "1h",
  "env": { "CLAUDE_CODE_FORK_SUBAGENT": "0" }
}
```

| Clave | Efecto | Coste del cambio |
|---|---|---|
| `autoCompactWindow: 200000` | Compacta cerca de 190k en vez de 950k | Se pierde historial antiguo; la compactación cuesta una lectura completa, amortizada en los turnos siguientes |
| `promptCacheTtl: "1h"` | Fija el TTL del hilo principal en 1 h | Escrituras a 2x en vez de 1,25x; con 1,39 M de escritura por sesión, despreciable |
| `subagentPromptCacheTtl: "1h"` | Igual para subagentes, forks y compactación | Igual; break-even en el segundo sondeo de un fork |
| `CLAUDE_CODE_FORK_SUBAGENT: "0"` | Claude deja de abrir forks por su cuenta | `/subtask` sigue disponible para abrirlos a mano |

Notas:

- `200000` es el mínimo razonable: por debajo de 100k Claude Code ignora el valor.
  Si algún proyecto necesita más, se sobreescribe por sesión con `/autocompact 400k`
  o con `--autocompact`.
- Todo esto requiere un build ≥ 2.1.296 (`autoCompactWindow`, `omitClaudeMd`) y
  ≥ 2.1.242 (TTLs). Verificado en 2.1.310.
- La alternativa a apagar el modo fork es dejarlo y confiar en el guardrail de
  §3.3.1. Se prefiere apagarlo: el guardrail protege del caso caro, pero no del
  fork innecesario.

### 3.2 Reglas de permisos — prioridad 0

```json
{
  "permissions": {
    "deny": [
      "Read(//tmp/claude-*/**)",
      "Read(//tmp/**/*.output)"
    ]
  }
}
```

Reglas **con scope**: no cambian las definiciones de herramientas y por tanto no
invalidan el prefijo del caché. Una regla desnuda (`"Read"`) sí lo invalidaría.

### 3.3 Hooks — prioridad 1

Cinco obligatorios, cuatro opcionales y una lista de descartados. Todos son
`command` con `jq`: sin red y con `timeout` corto, porque `PreToolUse` corre en el
camino crítico de cada llamada a herramienta (366 en la sesión auditada).

Los scripts canónicos están en `hooks/*.sh` y los aplica `task install`; los
fragmentos de abajo muestran la forma y la decisión de cada uno. La diferencia
importa en un detalle: los scripts reales no usan `set -e`, porque un
`(( condición )) && exit 0` que falla termina el hook con código 1 y Claude Code
lo reporta como error de hook. Usan `if` explícito y cierran con `exit 0`.

#### 3.3.1 `guard-deep-fork.sh` — bloquear forks con el padre profundo

Por qué aquí y no en `SubagentStart`: ese evento **no puede bloquear** la creación
de un subagente. El único punto de bloqueo es `PreToolUse` sobre `Agent`.

```bash
#!/usr/bin/env bash
# PreToolUse · matcher: Agent
# Niega el fork si el contexto de la sesión ya supera DEEP_FORK_LIMIT.
set -euo pipefail
input=$(cat)
transcript=$(jq -r '.transcript_path // empty' <<<"$input")
[[ -z $transcript || ! -f $transcript ]] && exit 0

limit=${DEEP_FORK_LIMIT:-150000}
ctx=$(jq -s -r '[.[] | select(.type=="assistant" and .message.usage)
  | .message.usage.input_tokens
  + .message.usage.cache_read_input_tokens
  + .message.usage.cache_creation_input_tokens] | last // 0' "$transcript")

(( ctx < limit )) && exit 0

jq -n --argjson c "$ctx" --argjson l "$limit" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason:
      ("Contexto en " + ($c|tostring) + " tokens (límite " + ($l|tostring) + "). "
       + "No forkear: usar un subagente con contexto fresco y un brief, o /clear antes.")
  }
}'
```

Pendiente antes de activar: confirmar con `claude --debug` cómo llega el fork en
`tool_input` (`subagent_type` u otro campo). Si no se distingue, la versión
conservadora niega **todo** `Agent` por encima del umbral, que es aceptable porque
por encima de 150k casi ningún subagente compensa.

#### 3.3.2 `guard-transcript-reads.sh` — hacer ejecutable la advertencia

```bash
#!/usr/bin/env bash
# PreToolUse · matcher: Read|Bash
set -euo pipefail
input=$(cat)
tool=$(jq -r '.tool_name' <<<"$input")
target=$(case $tool in
  Read) jq -r '.tool_input.file_path // empty' <<<"$input" ;;
  Bash) jq -r '.tool_input.command // empty' <<<"$input" ;;
esac)

[[ $target =~ (\.output|/tmp/claude-[0-9]+/.*tasks) ]] || exit 0
[[ $tool == Bash && ! $target =~ (cat|tail|head|less|bat|Read) ]] && exit 0

jq -n '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason:
      "Transcript de subagente. No se lee ni se hace tail: usá el reporte final del agente o jq sobre el estado del job."
  }
}'
```

#### 3.3.3 `guard-subagent-report.sh` — contrato de salida verificable

```bash
#!/usr/bin/env bash
# SubagentStop · sin matcher
set -euo pipefail
input=$(cat)
msg=$(jq -r '.last_assistant_message // empty' <<<"$input")
(( ${#msg} <= 4000 )) && exit 0

jq -n --argjson n "${#msg}" '{
  decision: "block",
  reason: ("El reporte final tiene " + ($n|tostring) + " caracteres. Comprimilo a un JSON de ≤20 líneas con las métricas; el detalle va a un archivo, no al mensaje.")
}'
```

#### 3.3.4 `loop-concision.sh` — sondeos cortos

```bash
#!/usr/bin/env bash
# UserPromptSubmit · sin matcher
# Se dispara también en cada tick de /loop y en cada reporte de subagente.
set -euo pipefail
prompt=$(jq -r '.prompt // empty')
[[ $prompt =~ (task-notification|\[loop|scheduled) ]] || exit 0

jq -n '{hookSpecificOutput: {hookEventName: "UserPromptSubmit",
  additionalContext: "Sondeo: respondé en ≤5 líneas con el estado. No repitas logs ni el plan."}}'
```

#### 3.3.5 `guard-model-switch.sh` — sin saltos a un modelo superior con el contexto profundo

No es solo Opus: **cualquier** salto a un modelo de gama superior multiplica el
coste por token, y **cualquier** salto de modelo, en cualquier dirección, tira el
prefijo del caché porque cada modelo tiene el suyo. Así que el guardrail compara
gamas, no nombres.

El input de este evento ya trae lo necesario (`from_model`, `to_model`,
`context_tokens`, `prompt_cache_warm`): no hay que leer el transcript.

```bash
#!/usr/bin/env bash
# PreModelSwitch · sin matcher (los modelos de gateway no tienen nombre canónico)
set -euo pipefail
input=$(cat)
from=$(jq -r '.from_model // ""' <<<"$input")
to=$(jq -r '.to_model // ""' <<<"$input")
ctx=$(jq -r '.context_tokens // 0' <<<"$input")
warm=$(jq -r '.prompt_cache_warm // false' <<<"$input")

tier() {
  case ${1,,} in
    *haiku*)  echo 1 ;;
    *sonnet*) echo 2 ;;
    *opus*)   echo 3 ;;
    *fable*|*mythos*) echo 4 ;;
    *)        echo 9 ;;   # desconocido: se trata como superior
  esac
}

tf=$(tier "$from"); tt=$(tier "$to")

# Bajar de gama se permite: paga un rebuild, pero abarata todos los turnos siguientes.
(( tt < tf )) && exit 0
# Misma gama: se permite (el cambio de caché no lo evita un hook).
(( tt == tf )) && exit 0

limit=${DEEP_SWITCH_LIMIT:-150000}
(( ctx < limit )) && exit 0

jq -n --arg from "$from" --arg to "$to" --argjson ctx "$ctx" --argjson warm "$warm" '{
  hookSpecificOutput: {
    hookEventName: "PreModelSwitch",
    permissionDecision: "deny",
    permissionDecisionReason:
      ("Salto a un modelo de gama superior (" + $from + " → " + $to + ") con "
       + ($ctx|tostring) + " tokens de contexto y el caché "
       + (if $warm then "caliente" else "frío" end)
       + ". Cada turno pasa a costar más y el prefijo se reenvía entero. "
       + "Terminá la tarea o hacé /clear antes de cambiar.")
  }
}'
```

Notas verificadas sobre el evento:

- `matcher` compara contra el nombre canónico del modelo destino; un alias, un ID
  con fecha y un ID de proveedor matchean igual. Por eso el filtro real va en el
  script y el matcher se omite: un modelo custom de gateway hace que Claude Code
  corra **todos** los hooks `PreModelSwitch` de todos modos.
- El hook **no** se ejecuta en los cambios que Claude Code hace por su cuenta, como
  el fallback automático. Ese caso queda fuera del guardrail.
- Se puede bloquear con `permissionDecision: "deny"` o con `exit 2` y el motivo en
  stderr.

Registro de los cinco en `~/.claude/settings.json`:

```json
{
  "hooks": {
    "PreToolUse": [
      { "matcher": "Agent", "hooks": [{ "type": "command", "command": "~/.claude/hooks/guard-deep-fork.sh", "timeout": 5 }] },
      { "matcher": "Read|Bash", "hooks": [{ "type": "command", "command": "~/.claude/hooks/guard-transcript-reads.sh", "timeout": 5 }] }
    ],
    "PreModelSwitch": [
      { "hooks": [{ "type": "command", "command": "~/.claude/hooks/guard-model-switch.sh", "timeout": 5 }] }
    ],
    "SubagentStop": [
      { "hooks": [{ "type": "command", "command": "~/.claude/hooks/guard-subagent-report.sh", "timeout": 5 }] }
    ],
    "UserPromptSubmit": [
      { "hooks": [{ "type": "command", "command": "~/.claude/hooks/loop-concision.sh", "timeout": 5 }] }
    ]
  }
}
```

#### 3.3.6 Opcionales, con su contrapartida

| Hook | Qué haría | Por qué no por defecto |
|---|---|---|
| `PostToolUse` + `updatedToolOutput` | Recortar cada salida a ~8k chars conservando cabeza y cola | Recortar a ciegas esconde el error que se estaba buscando. Solo con lista blanca de comandos. |
| `PostToolBatch` | Medir tokens por lote y avisar cuando un batch mete >20k | Interviene en caliente sobre el criterio del agente; ruido si se calibra mal. |
| `PostCompact` | Registrar cada compactación en un log de coste | Solo telemetría; útil para saber si el techo de 200k se está rozando. |
| `InstructionsLoaded` | Registrar qué `CLAUDE.md` y `.claude/rules/*.md` se cargan y cuánto pesan | Solo auditoría del prefijo permanente. |

#### 3.3.7 Descartados, y por qué

| Evento | Motivo |
|---|---|
| `PreCompact` (`auto`) | Permite bloquear la compactación automática: justo lo contrario de lo que hace falta aquí. |
| `FileChanged` | No tiene control de decisión: no puede inyectar contexto. El "que el job avise en vez de sondear" no es viable por esta vía. |
| `SubagentStart` | Solo `additionalContext`, sin bloqueo. |
| `MessageDisplay` | Cambia lo que se ve en pantalla, no lo que ve el modelo. |
| Hooks de tipo `prompt` o `agent` | Cuestan tokens en cada disparo: contraproducentes para ahorrar tokens. |

### 3.4 Skill `benchmark-monitor` — prioridad 1

Una skill genérica de "economía de tokens" no se invoca nunca. Esta tiene forma de
tarea, así que matchea cuando el usuario dice "seguí el progreso del job".

`.claude/skills/benchmark-monitor/SKILL.md`:

```markdown
---
name: benchmark-monitor
version: 1.0.0
description: Follow a running benchmark or long job without inflating the session context. Reads a bounded status file instead of logs, picks a safe poll cadence, and reports in five lines. Use when asked to watch progress, poll a job, or check whether a run finished.
---

# Benchmark monitor

## Regla

El estado vive en un archivo, no en el chat. El runner (no el agente) escribe
`/tmp/<run>/status.json` con: total, done, failed, current_trial, elapsed_s,
last_error. El agente lee ese archivo con `jq -c` y nunca el log completo.

## Procedimiento

1. Localizar el archivo de estado. Si no existe, crearlo con el runner antes de
   empezar; no arrancar un sondeo sobre un log.
2. Leer solo: `jq -c '{done:([.trials[]|select(.status!="pending")]|length),
   total:(.trials|length), fails:[.trials[]|select(.status=="fail")|.id]}' status.json`
3. Reportar en ≤5 líneas: total, hechos, fallos, ETA, primera acción sugerida.
4. Cadencia: <5 min o >60 min, nunca en el medio. Preferir `/loop 5m` sobre un
   `sleep` en `Bash`, que ocupa un turno entero.
5. Prohibido: `cat`/`tail`/`less` sobre `*.output`, transcripts JSONL o logs de
   más de 200 líneas. Si hace falta un detalle, `grep` acotado con `| head -20`.

## Al terminar

Un párrafo con el resultado agregado y el enlace al artefacto. Nada de volcar la
tabla de los N trials.
```

### 3.5 Subagente `benchmark-runner` — prioridad 1

Reemplaza al fork para trabajo de benchmark: contexto fresco y contrato de salida.

`.claude/agents/benchmark-runner.md`:

```markdown
---
name: benchmark-runner
description: Runs PLC benchmark trials or long local jobs and returns aggregate metrics only. Use for benchmark runs, batch trials, or any task whose stdout is large.
tools: Bash, Read, Write
model: sonnet
effort: low
maxTurns: 40
autoCompactWindow: 100000
omitClaudeMd: true
isolation: worktree
experimental:
  cacheTtl: 1h
---

Nunca leas transcripts JSONL ni vuelques stdout. Escribí el detalle en
/tmp/bench/<run>.log y devolvé EXCLUSIVAMENTE un JSON de ≤20 líneas:
{"run","trials","passed","failed","duration_s","first_error"}.
Si algo falla, devolvé el JSON con status:"error" y el primer error. Nada más.
```

`autoCompactWindow` aquí es 100000 porque es el mínimo aceptado; 50000 se ignora
en silencio.

### 3.6 `AGENTS.md` — prioridad 2

Solo el criterio que no se puede automatizar. Tres líneas, no un párrafo:

```markdown
## Coste de la sesión

- No abrir un fork si el contexto supera 150k: delegar con subagente fresco y brief.
- Los monitores leen un archivo de estado; nunca volcar logs ni transcripts al chat.
- Al cambiar de repositorio o de tarea, `/clear`.
```

### 3.7 Observabilidad — prioridad 0 (script) y 2 (OTel)

`scripts/audit-session-cost.py`: recibe un id de sesión, localiza el JSONL y los
`subagents/`, y devuelve la tabla del review en una pasada (por fork, por hora,
lecturas/escrituras/output, y el contrafactual a un tope dado).

Interfaz:

```
$ scripts/audit-session-cost.py 01a5c123 --cap 200000
sesión     reqs   lectura   escritura  output   coste   con tope 200k
main        440   166.0M    1.39M      397k     $26.12  $12.9
agent-a642   48    31.8M    5.52M       34k     $17.34  $4.2
...
TOTAL       705   344.5M    8.66M      630k     $64.51  $31.7
```

Además: la statusline ya muestra `ctx remaining %`; conviene añadir el coste
acumulado si se quiere ver en vivo. OTel queda para cuando haya varias máquinas:
es lo único que da tokens por subagente en tiempo casi real.

### 3.8 Revisión del plugin `context-mode` — prioridad 1

`SessionStart:resume` inyectó **146.512 bytes** (~40k tokens) y `PreToolUse:Agent`
65.277 bytes en 6 eventos. El script `~/.claude/hooks/context-mode-cache-heal.mjs`
es un auto-heal, no el inyector: el contenido sale del plugin
`context-mode@context-mode` (`~/.claude/context-mode/`).

Propuesta: medirlo una semana con el plugin apagado. Si no se echa de menos, se
queda apagado. Si se echa de menos, se busca cuál de sus hooks emite los 146 KB y
se recorta ese, no el plugin entero.

### 3.9 Hábitos — prioridad 2

1. `/clear` en cada corte de repositorio o de tarea. Es gratis y es el mayor
   ahorro por unidad de esfuerzo.
2. No pegar terminal de la VM en el chat: 15 pastes fueron ~52k tokens
   permanentes. Alternativas: que el agente ejecute el comando, o escribir la
   salida a un archivo y leer un rango acotado.
3. Sondeo: `<5 min` o `>60 min`. La franja 5–60 es el peor caso posible.

## 4. Fases

| Fase | Qué | Esfuerzo | Resultado |
|---|---|---|---|
| 0 | Settings de §3.1 y §3.2 + `audit-session-cost.py` | 30 min | Techo de contexto y medición reproducible |
| 1 | Hooks §3.3.1 y §3.3.2 | 45 min | Los dos casos caros quedan imposibles |
| 2 | Subagente §3.5 + skill §3.4 | 45 min | El trabajo de benchmark deja de necesitar forks |
| 3 | Hooks §3.3.3 a §3.3.5 + auditoría del plugin §3.8 | 45 min | Contrato de salida, sondeos cortos, plugin decidido |
| 4 | `AGENTS.md` §3.6 + OTel si hace falta | 20 min | Criterio explícito y telemetría |

## 5. Criterios de salida

- [ ] Una sesión de benchmark de 6 h termina por debajo de **$20** (línea base: $66,83).
- [ ] Ninguna sesión abre un fork con el contexto por encima de 150k.
- [ ] Ninguna lectura de `*.output` ni de transcripts llega al contexto.
- [ ] `audit-session-cost.py` reproduce los totales de `cost-state` con un error < 5%
      (la diferencia por deduplicación documentada en el review es ~3,5%).
- [ ] El arranque de una sesión nueva no inyecta más de ~10k tokens de hooks.
- [ ] Revisión a las dos semanas con los mismos comandos del review §9.

## 6. Ahorro estimado

| Pieza | Ahorro | Se solapa con |
|---|---|---|
| `autoCompactWindow: 200000` | ~$22–25 | lectura de los forks (que heredan menos) |
| `subagentPromptCacheTtl: "1h"` | ~$12–14 | — |
| No forkear en profundidad | ~$16 solo en `a642592f`; hasta $38 con los seis | ventana |
| Cadencia `<5` o `>60` | ~$12 en el caso del sondeo | TTL 1 h (ambos evitan el mismo rebuild) |
| Menos pastes y más `/clear` | ~$10–20 | ventana |

No son aditivos: el contrafactual calculado con el tope de 200k deja la sesión en
**~$32**, y eliminando además los forks, en **~$20–25**. Cifra de trabajo:
**la mitad o un tercio de la factura actual**, sin tocar el modelo ni la calidad
del trabajo.

## 7. Riesgos

| Riesgo | Mitigación |
|---|---|
| Un hook lento frena cada llamada a herramienta | `jq` puro, sin red, `timeout: 5`, `matcher` estrecho |
| El guardrail de forks bloquea un caso legítimo | El mensaje de `deny` explica la alternativa; se sube `DEEP_FORK_LIMIT` por sesión |
| La compactación a 200k pierde contexto útil | `/compact Focus on …` antes de un corte; subir el techo por proyecto con `/autocompact` |
| `autoCompactWindow` global afecta a proyectos que necesitan más | Override por sesión con `--autocompact` o `/autocompact` |
| Recortar salidas (`PostToolUse`) esconde errores | No se activa por defecto; solo en la lista blanca de §3.3.6 |
| Sobrecargar `AGENTS.md` | Tres líneas; el resto va a hooks o settings |

## 8. Preguntas abiertas

1. ¿`CLAUDE_CODE_FORK_SUBAGENT=0` permanente, o solo el guardrail de profundidad?
   La primera opción es más barata y quita una decisión al agente; la segunda
   conserva el fork para casos donde el historial sí hace falta.
2. ¿`autoCompactWindow` global o por proyecto? Global es más simple; por proyecto
   respeta repos con contexto legítimamente largo.
3. ¿El plugin `context-mode` aporta lo suficiente para sus 40k tokens por resume?
4. ¿Vale la pena OTel ahora, o alcanza con `audit-session-cost.py` mientras haya
   una sola máquina?
