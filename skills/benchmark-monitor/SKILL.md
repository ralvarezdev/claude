---
name: benchmark-monitor
description: Follow a running benchmark or long job without inflating the session context. Reads a bounded status file instead of logs, picks a safe poll cadence, and reports in five lines. Use when asked to watch progress, poll a job, or check whether a run finished.
---

# Benchmark monitor

El estado vive en un archivo, no en el chat. El runner —no el agente— escribe
`/tmp/<run>/status.json` con `total`, `done`, `failed`, `current_trial`,
`elapsed_s` y `last_error`. El agente lee ese archivo y nunca el log completo.

## Procedimiento

1. Localizar el archivo de estado. Si no existe, crearlo con el runner antes de
   empezar: no arrancar un sondeo sobre un log.
2. Leer solo lo necesario:

   ```bash
   jq -c '{done: ([.trials[] | select(.status != "pending")] | length),
           total: (.trials | length),
           fails: [.trials[] | select(.status == "fail") | .id]}' /tmp/<run>/status.json
   ```

3. Reportar en ≤5 líneas: total, hechos, fallos, ETA y la primera acción
   sugerida. Sin tablas de los N trials.
4. Cadencia: **<5 min o >60 min, nunca en el medio**. Entre el TTL de 5 minutos y
   su doble, cada sondeo paga el contexto entero. Preferir `/loop 5m` (dispara a
   los 4m45s a propósito) antes que un `sleep` en `Bash`, que ocupa un turno.
5. Prohibido: `cat`, `tail` o `less` sobre `*.output`, transcripts JSONL o
   cualquier log de más de 200 líneas. Si hace falta un detalle, `grep` acotado
   con `| head -20`.

## Al terminar

Un párrafo con el resultado agregado y la ruta del artefacto. Nada de volcar la
tabla completa de trials: eso va al archivo, y el archivo no se lee.
