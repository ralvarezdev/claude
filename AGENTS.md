# AGENTS.md — claude

Registro personal de uso y coste de Claude Code. El producto son los documentos,
no el código: aquí no hay build ni tests, y una afirmación sin medición no vale.

## Reglas

- **Todo dato lleva su fuente.** Un número sale del `usage` de un transcript o del
  `cost-state` de una sesión, y se dice cuál. Si es una estimación, se marca como
  tal y se declara el supuesto.
- **No se reescribe un documento fechado.** `docs/reviews/` y `docs/changes/` son
  registros: si algo cambia, va un documento nuevo que enlaza al anterior.
- **Frontmatter obligatorio** en todo lo que esté bajo `docs/`, salvo
  `docs/README.md` y `docs/templates/`. Los enlaces son relativos.
- **Los secretos no entran.** Ni API keys, ni rutas con credenciales, ni el
  contenido de `~/.claude/.credentials.json`. Los IDs de sesión son locales y sí
  pueden aparecer.
- **No se empuja nada** (`git push`) salvo que el dueño lo pida.

## Estructura

- `docs/reviews/` — mediciones y auditorías, fechadas, inmutables.
- `docs/plans/` — lo que se propone construir, con fases y criterios de salida.
- `docs/templates/` — las plantillas de cada tipo.

## Comprobación

```bash
python3 ~/.config/rsk/cache/registry/docs-architect/1.0.0/scripts/docs_lint.py docs
```
