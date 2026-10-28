---
status: done
project: claude
date: 2026-10-28
related: []
---

# Auditoría: por qué dos sesiones de Claude Code costaron $66.83 y $28.50 (2026-10-28)

Escrito 2026-10-28. Origen: la sospecha de que una sesión de Claude Code en
`automation-labs-openhands-plc` había consumido ~800.000 tokens "en 10 minutos" por una fuga de logs de
un subagente. La sospecha era incorrecta en el mecanismo y en la magnitud temporal.
Este documento registra qué se midió, qué se descartó y qué queda por cambiar.

"Leído" significa leído en el transcript o en el `cost-state` de la sesión;
"calculado" significa derivado de esos registros; "estimado" significa una
proyección con supuestos declarados. Nada se cambió en el entorno durante la
auditoría.

## 1. Método

Todo sale de los transcripts locales que Claude Code escribe en
`~/.claude/projects/<proyecto>/<sesión>.jsonl` y en el subdirectorio
`<sesión>/subagents/`. Cada registro `assistant` lleva el `usage` real de la API
(`input_tokens`, `cache_read_input_tokens`, `cache_creation_input_tokens`,
`output_tokens` y el desglose `ephemeral_1h` / `ephemeral_5m`), y cada sesión
cierra con un registro `cost-state` que declara el total.

Sesiones auditadas:

| Sesión | Proyecto | Archivo |
|---|---|---|
| `01a5c123-d98d-4d1b-89b6-2241604af590` | `automation-labs-openhands-plc` | 7,0 MB, 2.862 líneas |
| `bd4861f2-42da-470f-a8ba-c373f12875c5` | `automation-labs-openevolve` | 18 MB |

Entorno leído: Claude Code `2.1.310`, modelo `claude-sonnet-5-5` (ventana nativa
de 1M), `querySource: sdk` (camino ACP desde Zed), `effort: medium`.

## 2. Los números

| | openhands-plc (principal) | openhands-plc (6 forks) | openevolve |
|---|---|---|---|
| Peticiones | 440 | 265 | 353 |
| `cache_read` | 166,03 M | 178,50 M | 191,92 M |
| Escrituras 1 h | 1,39 M | 0,01 M | 0,83 M |
| Escrituras 5 m | 0 | **7,27 M** | 0 |
| Output | 397 k | 233 k | 593 k |
| Contexto mín → máx | 37.709 → 754.654 | 617 k → **802.674** | 33.112 → **841.451** |
| Duración de pared | — | — | 7,3 h |
| **Coste** | **$26,12** | **$38,39** | **$28,50** |

`cost-state` de la sesión de `openhands-plc`: **$66,83**, con 366.574.046 tokens de
lectura de caché, 8.751.538 de escritura y 600.034 de output, en 7 h 21 min de
pared y 1 h 48 min de API.

Los costes de la tabla son recalculados por petición y suman $64,51 frente a los
$66,83 declarados; la diferencia (~3,5%) es la deduplicación descrita en §10. Las
proporciones y las comparaciones entre objetos se mantienen.

Dos observaciones que ordenan todo lo demás:

1. **Las dos conversaciones principales costaron casi lo mismo** (~$26–28, con la
   misma forma). `openevolve` llegó incluso a un contexto mayor (841 k frente a
   754 k).
2. **Toda la diferencia son los forks**: $38,39, el 57% de la sesión de
   `openhands-plc`.

El pico de `openevolve`, que es la sesión "que volaba en una hora", fue
**18:00–19:00Z**: $6,50 con 68 peticiones y un contexto de 781 k, y dentro de esa
hora el tramo más caro fue 18:10–18:20 (26 peticiones, 18,9 M tokens leídos,
$1,89 en diez minutos). No hubo nada anómalo ahí: es la misma aritmética de §3,
sin forks que la amplifiquen. A modo de contraste, la hora 15 de la misma sesión
costó $0,28 con 5 peticiones.

Desglose del coste de la sesión cara (calculado):

| Componente | Tokens | Precio | Coste | % |
|---|---|---|---|---|
| Lecturas de caché | 366,6 M | $0,10/M | $36,66 | 55% |
| Escrituras 5 m (forks) | 7,27 M | $2,50/M | $18,18 | 27% |
| Escrituras 1 h (principal) | 1,39 M | $4,00/M | $5,58 | 8% |
| Output | 0,60 M | $10/M | $6,00 | 9% |

## 3. El mecanismo: coste = Σ contexto

Cada turno reenvía el contexto completo. El coste total no es
`contexto × turnos` sino la suma del contexto de cada turno, y como el contexto
crece con los turnos, el resultado es cuadrático en la duración de la sesión.

Contexto del hilo principal de `openhands-plc` por décimos de la sesión (leído):

```
req   1 (12:41)   37.709
req  89 (13:35)  176.070
req 177 (13:55)  269.546
req 265 (15:31)  440.188
req 353 (17:04)  605.846
req 440 (20:02)  754.654
```

Consecuencia práctica: **un turno con 754 k de contexto cuesta $0,075 — lo mismo
que una sesión nueva de 30 turnos desde cero**. El descuento del caché (0,05x en
Sonnet 5.5) no sustituye acotar el contexto; abarata un número que ya era enorme.

Contrafactual calculado, recalculando cada petición con el contexto topado en
200 k:

| | Lectura real | Con tope 200 k | Factor |
|---|---|---|---|
| Principal | 167,4 M | 80,7 M | 2,1x |
| Fork `a642592f` | 37,4 M | 9,6 M | 3,9x |
| Fork `abb9cae3` | 75,6 M | 22,2 M | 3,4x |
| Resto de forks | 72,8 M | 20,4 M | 3,5x |
| **Total** | **353,2 M** | **132,9 M** | **2,7x** |

Solo en lecturas: $35,32 → $13,29. Con escrituras y output, la sesión habría
quedado en ~$32 en lugar de $66,83.

## 4. Los forks: qué son y cuáles hubo

Un **fork** es un subagente que hereda la conversación completa — system prompt,
herramientas, modelo e historial — en vez de arrancar con contexto limpio. Sus
llamadas a herramientas no entran en el hilo principal, pero **su contexto sí es
una copia, no una referencia**. El modo fork viene activado por defecto: Claude
puede crear forks por su cuenta, y así ocurrió aquí (no hubo `/subtask`).

`openevolve`: **cero forks**. No existe el directorio `subagents/` y hay 0
llamadas a `Agent` en 353 peticiones (271 `Bash`, 16 `Read`).

`openhands-plc`: seis forks, todos `agentType: "fork"`, `model: inherit`.

| Fork | Inicio (Z) | Fin (Z) | Dur. | Req | Coste |
|---|---|---|---|---|---|
| `abb9cae3` | 16:40:17 | 17:03:54 | 24 min | 111 | $8,94 |
| `ae4e49d2` | 16:40:25 | 16:42:16 | 2 min | 11 | $0,90 |
| `a64f02a6` | 17:33:26 | 17:41:41 | 8 min | 26 | $2,05 |
| `a1e0eb66` | 17:48:04 | 18:29:09 | 41 min | 37 | $6,46 |
| `add42bf5` | 18:36:40 | 18:42:39 | 6 min | 28 | $2,67 |
| **`a642592f`** | **18:45:27** | **20:01:08** | **76 min** | **48** | **$17,34** |

El fork `a642592f` — el mismo `agentId` que aparecía en la alerta original — costó
el 26% de la sesión completa en 76 minutos. Su primera petición leyó 745.037
tokens del caché del padre: **no llegó a 800 k leyendo logs, nació en 745 k**
porque el padre ya estaba ahí. El máximo de 802.674 es herencia más trabajo propio.

Regla que sale de esto: el fork es proporcional al contexto del padre. Con el padre
en 40 k es un atajo; con el padre en 745 k es una segunda sesión completa a tu
cargo. Umbral práctico: **por encima de ~150 k, delegar con subagente fresco y un
brief explícito, no con fork**.

## 5. El TTL de 5 minutos: cuánto explicó

Explica $18 de $67, todo en los forks. El hilo principal corría con `ttl: "1h"`
desde el inicio y tuvo **un solo** fallo de caché por expiración en 7 horas (el
hueco de 76 minutos entre 18:45 y 20:01, que reescribió 736.876 tokens, $2,95).

La huella del TTL, leída en `a642592f`:

| Hora | `cache_read` | `cache_creation` |
|---|---|---|
| 18:49:13 | 778.215 | 904 |
| 18:55:12 | 14.592 | 765.120 |
| 19:01:38 | 14.592 | 766.331 |
| 19:07:37 | 800.378 | 598 |
| 19:17:33 | 14.592 | 786.796 |
| 19:27:32 | 14.592 | 787.117 |
| 19:37:28 | 14.592 | 787.438 |
| 19:47:32 | 14.592 | 787.759 |
| 19:57:32 | 14.592 | 788.080 |

Cadencia de exactamente 10 minutos, TTL de 5 minutos, 787 k reescritos en cada
disparo. Regla general: **cualquier intervalo entre el TTL y su doble es el peor
caso posible** — garantiza el fallo sin amortizar la escritura de 1 h. O menos de
5 min (`/loop 5m` dispara a los 4m45s a propósito), o más de 60.

## 6. Qué se descartó

| Hipótesis | Veredicto | Evidencia |
|---|---|---|
| Fuga del JSONL del subagente al hilo principal vía ACP | **Falsa** | 1 sola llamada a `Read` en 7 h; 366 `Bash`; los 4 comandos que tocaron un `.output` fueron `cat … \| tail -3 \| cut -c-200`. ACP no transporta tráfico al modelo. |
| El proxy ACP absorbió la salida del subagente | **Falsa** | El proceso habla con la API directamente (`querySource: sdk`, `cacheControl` propio). |
| Mutación del entorno invalidó el prefijo del caché | **Falsa** | 440/440 peticiones del principal con `cache_read > 0`: cero fallos. Editar archivos no invalida el prefijo; solo lo que está antes del breakpoint. |
| El bucle de 10 min disparó el consumo del hilo principal | **Falsa en el principal, cierta en un fork** | El principal no tenía bucle; el patrón de 10 min aparece solo dentro de `a642592f`, de 18:55 a 19:57. |
| 14 pruebas en paralelo | **Falsa** | 6 forks en 5 oleadas (dos solapados a las 16:40) y ~9 tareas de `Bash` en segundo plano. |

## 7. De dónde salió el contexto de 754 k

Composición medida (caracteres → tokens aproximados):

| Componente | Medida | ~Tokens |
|---|---|---|
| Thinking retenido | 213.574 declarados en `cost-state` | 213.574 |
| Salidas de `Bash` | 553.353 chars / 366 llamadas | ~150.000 |
| Hooks | 272.000 chars / 77 eventos | ~80.000 |
| System prompt, tools, skills, CLAUDE.md | — | ~90.000 |
| Pastes manuales del usuario | 156.932 chars / 15 pastes | ~52.000 |
| Texto del asistente e inputs de tools | 97.000 chars | ~28.000 |

Dos detalles que no se ven leyendo el transcript por encima:

- Los 420 bloques de thinking están guardados con `"thinking": ""` y solo la
  `signature`. El texto no está, pero sí está en el contexto: cada petición lleva
  `context_management: {"edits": [{"type": "clear_thinking_20251015", "keep": "all"}]}`.
  Nunca se limpia, así que es el mayor contribuyente individual y es invisible en
  una auditoría basada en caracteres.
- El mayor salto en un solo turno en 7 horas fue **+22.089 tokens** (2,9% del
  total), y fue un paste de 46.087 caracteres de una transcripción de terminal de
  la VM. No hubo ningún pico: hubo una integral.

Hooks que inyectaron contexto en el principal: `PreToolUse:Agent` 65.277 bytes en
6 eventos, `Stop` 20.637 bytes en 67 eventos, `SessionStart:startup` 5.247 bytes.
Queda además un `SessionStart:resume` de **146.512 bytes** que se disparó al
final: si esa sesión se retoma, inyecta ~40 k tokens en un contexto que ya está
en 750 k.

## 8. Recomendaciones

Ordenadas por ahorro estimado, con el efecto calculado sobre esta sesión:

1. **`autoCompactWindow: 200000`** — ahorro ~$22–25. Es la palanca mayor: acota las
   lecturas del principal y, en cascada, el contexto que hereda cada fork. El
   default sobre un modelo de 1M compacta cerca de 950 k, así que la protección
   existía y nunca llegó a activarse.
2. **`subagentPromptCacheTtl: "1h"`** — ahorro ~$12–14. Convierte los ~10 rebuilds
   de 787 k en una escritura más lecturas. Break-even en el segundo sondeo. La
   clave equivalente en el frontmatter de un agente es
   `experimental.cacheTtl: 1h`.
3. **No forkear con el padre profundo** — ahorro ~$16 solo en `a642592f`. Por
   encima de ~150 k de contexto en el padre, delegar con subagente fresco.
4. **Cadencia de sondeo: nunca entre 5 y 60 minutos.** `<5 min` o `>60 min`.
5. **Auditar los hooks**: 272 KB de `hook_success` es tanto texto como las 366
   llamadas a `Bash` juntas, y una vez inyectado es permanente.
6. **Descartar `.claudeignore`**: no existe en Claude Code. Para bloquear rutas es
   `permissions.deny` con reglas con scope (`Read(//tmp/claude-*/**)`), que no
   invalidan el prefijo; una regla desnuda (`"Read"`) sí lo invalida.

Todas las claves requieren un build ≥ 2.1.296 y existen en 2.1.310, así que no hay
riesgo de que se ignoren en silencio.

## 9. Cómo repetir la medición

El total autoritativo de una sesión:

```bash
jq -c 'select(.type=="cost-state") | {totalCostUSD, modelUsage}' <sesión>.jsonl
```

El perfil por petición, que distingue volumen de fallos de caché:

```bash
jq -r 'select(.type=="assistant" and .message.usage!=null)
  | [.timestamp, .message.id,
     .message.usage.cache_read_input_tokens,
     .message.usage.cache_creation_input_tokens,
     .message.usage.output_tokens] | @tsv' <sesión>.jsonl \
| awk '!seen[$2]++'
```

Firmas de lectura:

- `cache_creation` ≈ tamaño del contexto y `cache_read` ≈ 14 k, repetido cada
  N minutos → expiración de TTL.
- `cache_read` ≈ contexto de forma sostenida → caché sano, gasto por volumen.
- Un salto de contexto de decenas de miles en un turno → contenido inyectado
  (paste, hook o lectura de archivo), no acumulación.

Los forks se miden aparte, en `<sesión>/subagents/agent-*.jsonl`, con el mismo
comando. `cost-state` **no** incluye el desglose por fork en un solo campo: hay
que sumar los transcripts de `subagents/`.

## 10. Límites de este análisis

- Los totales salen de `cost-state`; los repartos por hora y por fork son
  recalculados y subestiman ~3,5% (openhands-plc) y ~14% (openevolve) respecto al
  total, porque se deduplican escrituras parciales del streaming. Las
  proporciones se mantienen; los totales oficiales mandan.
- El thinking está redactado en el transcript (`thinking: ""` + `signature`), así
  que su peso se toma de `cost-state`, no de medir caracteres.
- No se contrastó con la factura real de Anthropic. Los precios usados son los de
  lista de Sonnet 5.5: $2/M base, $0,10/M lectura de caché (0,05x), $2,50/M
  escritura 5 m (1,25x), $4/M escritura 1 h (2x), $10/M output.
- `advisorModel: claude-opus-5-5` aparece en los registros; no se pudo aislar si
  generó peticiones facturables adicionales fuera de los `modelUsage` leídos.
