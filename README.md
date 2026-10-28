# claude

Notas de uso y coste de Claude Code: qué consume los tokens, por qué, y qué
configuración lo acota. Nada de esto es código del producto; es el registro de las
mediciones hechas sobre sesiones reales y de las decisiones que salieron de ellas.

## Por qué existe

Dos sesiones de trabajo de siete horas costaron $66,83 y $28,50 sin que nada
fallara visiblemente: el caché funcionaba, el modelo era el mismo y el trabajo era
normal. La diferencia entre las dos era una sola cosa —seis subagentes `fork` que
heredaron 745k de contexto— y eso no se ve en ningún panel. Este repositorio
guarda la medición y el plan de guardrails para que no vuelva a pasar a ciegas.

## Contenido

| Documento | Qué es |
|---|---|
| [Auditoría de dos sesiones](docs/reviews/2026-10-28-claude-code-session-token-audit.md) | Qué se midió, qué se descartó y de dónde salió cada dólar |
| [Plan de guardrails](docs/plans/2026-10-28-claude-code-token-guardrails-plan.md) | Settings, hooks, skill, subagente y script de auditoría, por fases |

## Método

Todo sale de los transcripts que Claude Code escribe en
`~/.claude/projects/<proyecto>/<sesión>.jsonl`: cada registro `assistant` lleva el
`usage` real de la API y cada sesión cierra con un `cost-state` con el total. Los
comandos de reproducción están en el §9 de la auditoría.

## Convenciones

`docs/` sigue el esquema de `docs-architect`: una carpeta por tipo de documento,
frontmatter obligatorio y el índice en [`docs/README.md`](docs/README.md).
