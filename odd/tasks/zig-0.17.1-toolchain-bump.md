# Zig 0.17.1 — bump del toolchain y retirada de `gga`

**Feature**: `zig-0.17.1-toolchain-bump`
**Mode**: ODD
**Branch**: `feat/zig-0.17.1-toolchain` (desde `main @ c9c9654`)
**Source-of-truth priority**: code > este doc. Si el código y el doc discrepan, el código gana y el doc se actualiza.
**Alcance**: los pines de toolchain del repo y la documentación que declara la versión. Fuera de alcance: cambiar semántica de runtime, adoptar capacidades nuevas de Zig, cerrar los gaps de sandbox que dejaron abiertos features anteriores.

## Goal

Que Zargeant declare, pinneé y se construya bajo **Zig 0.17.1**, y que el repo no conserve ninguna referencia funcional a `gga`.

## Context

El host ya corre **Zig 0.17.1** (`zig version` → `0.17.1`), pero el repo sigue pineado en **0.17.0** en 4 ficheros de toolchain y 6 de documentación. El tarball de 0.17.1 está publicado (`https://ziglang.org/download/0.17.1/zig-x86_64-linux-0.17.1.tar.xz` → HTTP 200); no hay release notes de patch (`/download/0.17.1/release-notes.html` → 404), lo que es lo esperable en un release de parche. La documentación de lenguaje existe para 0.17.1 (`/documentation/0.17.1/` → HTTP 200, mismo `<title>` que 0.17.0).

ZLS sigue en **0.17.0** en el host. El repo no pinea ZLS en ningún fichero, así que no hay nada que actualizar ahí.

Sobre `gga`: **ya fue retirado por completo** el 2026-10-27 (L24 del doc `zig-0.17-migration.md`). Verificado en esta sesión: no existe `.gga` ni `.gga/` en disco, no hay hook `pre-commit` en `.git/hooks/`, `git ls-files | grep gga` no devuelve nada, y no hay ninguna mención a `gga` en `.github/`, `tools/`, `src/`, `tests/` ni `build.zig*`. Los únicos matches restantes son (a) entradas de logbook en `odd/tasks/` — historia de features ya cerradas, que no se reescribe — y (b) falsos positivos de subcadena ("Plu**gga**ble" en `src/terminal/term.zig` y `tests/terminal/term.zig`).

## Specs

### S1 — El toolchain del repo debe quedar pineado en 0.17.1

Requisito: `build.zig.zon` (`.minimum_zig_version`), `.github/workflows/ci.yml` (`env.ZIG_VERSION`), `tools/local-ci.sh` (`readonly ZIG_VERSION`) y `tools/zargeant-ci.Containerfile` (`ARG ZIG_VERSION`) pasan de `0.17.0` a `0.17.1`.

Verbatim del usuario: *"También debo decir que Zig ahora está en 0.17.1"*.

### S2 — La documentación del repo debe declarar 0.17.1 como toolchain vigente

Requisito: los puntos que **declaran el toolchain actual** pasan a `0.17.1`: `README.md` (badge + "exact toolchain pinned"), `AGENTS.md` (§9.1 tabla de recipes, §9.3 runtime stack, §10 paso 5), `justfile` (cabecera + receta `ci`), `.github/PULL_REQUEST_TEMPLATE.md` (checklist), `docs/methodology.md` (enlace al Language Reference).

Verbatim del usuario: *"Bump del toolchain a Zig 0.17.1"*.

**Restricción explícita**: los enunciados que son **hecho histórico sobre el release 0.17.0** NO se reescriben, porque seguirían siendo ciertos y falsearlos sería un error de documentación: `AGENTS.md` §9.2 ("hang is FIXED (Zig 0.17.0 migration, T-10)"), `AGENTS.md` §9.4 ("Zig 0.17.0 added three capabilities…"), `justfile` ("fixed as of Zig 0.17.0"), `docs/methodology.md` §2 ("In Zig 0.17.0 the runtime libraries moved to `lib/`").

### S3 — El repo no debe conservar ninguna referencia funcional a `gga`

Requisito: no queda hook, configuración, step de CI ni script que invoque `gga`. Las menciones en logbooks de features cerradas no son referencia funcional.

Verbatim del usuario: *"Quita todo lo relacionado a 'gga' debido a que no lo tengo instalado y ya no se hará uso de él"*.

### S4 — El repo no debe declarar dos toolchains distintos

Requisito: un mismo documento no afirma a la vez `0.17.1` y `0.16` sobre el código actual. `README.md` declaraba "Zig 0.16" en tres sitios (descripción del harness, "Minimal binary", árbol de ficheros) mientras el badge decía `0.17.0` — incoherencia preexistente que el bump deja visible.

Verbatim del usuario: *"Bump del toolchain a Zig 0.17.1"* (interpretación: el repo declara **un** toolchain, el vigente).

### S5 — El CI local no debe verificar un toolchain distinto del declarado

Requisito: `tools/local-ci.sh` re-bakea la imagen `localhost/zargeant-ci:latest` cuando el `zig version` que hay dentro no es el `ZIG_VERSION` que el script espera. Sin esto, cambiar el toolchain pineado produce un **verde falso**: el CI verifica la imagen vieja.

Evidencia verbatim del gate (2026-11-20):

```
 Local CI (Podman, --rm, no garbage)
 Zig:    0.17.0
```

con `build.zig.zon` exigiendo `.minimum_zig_version = "0.17.1"`.

## Tasks

| # | Specs | Cambio | Ruta | Riesgo | Commit |
|---|---|---|---|---|---|
| T-1 | S1 | Pins de toolchain `0.17.0` → `0.17.1` en los 4 ficheros | `build.zig.zon`, `.github/workflows/ci.yml`, `tools/local-ci.sh`, `tools/zargeant-ci.Containerfile` | item 5 | `38ebdd9` |
| T-2 | S2, S4 | Docs que declaran el toolchain vigente → `0.17.1`; residuos `0.16` del README → `0.17` | `README.md`, `AGENTS.md`, `justfile`, `docs/methodology.md`, `.github/PULL_REQUEST_TEMPLATE.md` | none | `38ebdd9` |
| T-3 | S3 | Verificar la retirada de `gga` (huella funcional = 0) | — | none | sin diff (verificado) |
| T-4 | S5 | Detección de imagen Podman stale: re-bakear si el Zig de la imagen ≠ el esperado | `tools/local-ci.sh` | item 5 | `b794425` |
| T-5 | S1..S5 | Gate completo AGENTS.md §10 sobre el host con 0.17.1 (incluye re-bake del CI) | — | item 5 | L14 |
| T-6 | S1..S5 | Cierre: Log + commit final | `odd/tasks/` | none | este commit |

## Log

**L1** (2026-11-20, verbatim) — "Recupera el estado del proyecto y hazme question tool para proceder con su construcción. También debo decir que Zig ahora está en 0.17.1"

**L2** (2026-11-20, verbatim, decisión del usuario en el question tool) — "Bump del toolchain a Zig 0.17.1"

**L3** (2026-11-20, verbatim, decisión del usuario en el question tool) — "Quita todo lo relacionado a 'gga' debido a que no lo tengo instalado y ya no se hará uso de él"

**L4** (2026-11-20) — **Estado recuperado antes de empezar**: `main` limpio y al día con `origin/main` en `c9c9654`, sin PRs ni issues abiertos. PR #59 (migración a 0.17.0) y PR #60 (sandbox seccomp P0) están **MERGED**. El último gate registrado en `odd/tasks/sandbox-seccomp-p0-fix.md` (L10) está **verde completo**: builds ×3, `just check`, `just test` 9/9, `just test-embedded` 224/224, `just verify` 21/21 steps · 314/314 tests. El verificador independiente de ese feature dio PASS-WITH-ADVISORIES con 1 blocker corregido (denylist con 5 números que no son el ABI x86_64) y 3 advisories corregidos.

**L5** (2026-11-20) — **Gaps heredados de features anteriores** (NO en alcance de este feature, se registran para el work unit que los recoja):
1. Landlock v1: una herramienta enjaulada no puede escribir en `/dev/null` ni en char devices (`sandbox-seccomp-p0-fix.md` L17) → requiere Landlock v2+ o reglas por directorio.
2. `TOOLS_PROFILE.denied_syscalls` (179/230/316) no lo aplica el filtro seccomp, que es único y comptime (`sandbox-seccomp-p0-fix.md` L16) → requiere construir el BPF en runtime.
3. S8 (barrido de deprecaciones) diferido a 0.18-prep y D4 (compilación incremental) a medias (`zig-0.17-migration.md`).
4. `tools/local-ci.sh:10` sigue diciendo "197 tests" — el conteo real del artefacto umbrella es **224** (`AGENTS.md` §9.2). Comentario obsoleto, no tocado por estar fuera del alcance del bump.

**L6** (2026-11-20) — **RDD está `on` (global)** en este host — en la fecha del doc de migración (L14, 2026-10-26) estaba `off`. Consecuencia: al cerrar la implementación se ejecuta el ciclo nativo de review (`gentle_review` assess → inspect → START → capturas → acknowledgement), que es una vista externa y no autoriza entrega.

**L7** (2026-11-20) — **Decisión de alcance sobre S4**: el bump deja al README declarando `0.17.1` en el badge y `0.16` en tres frases sobre el código actual. Se incluye su corrección (3 líneas) porque un README que afirma dos toolchains distintos es un defecto de documentación del propio cambio, no un extra. Se **mantienen** sin tocar las dos menciones a "Zig 0.16" que describen el *contenido* de `docs/investigation-2.md` (README:228 y README:242), porque ese documento se escribió contra 0.16 y la referencia es histórica.

**L8** (2026-11-20) — **Implementación T-1 + T-2 aplicada**: 17 líneas cambiadas en 9 ficheros (`git diff --stat`), exactamente el inventario previsto — 4 pines de toolchain (`build.zig.zon`, `.github/workflows/ci.yml`, `tools/local-ci.sh`, `tools/zargeant-ci.Containerfile`) + 5 ficheros de documentación (`README.md` ×5, `AGENTS.md` ×3, `justfile` ×2, `docs/methodology.md` ×1, `.github/PULL_REQUEST_TEMPLATE.md` ×1). Ningún cambio de comportamiento: solo cadenas de versión y tres frases de prosa del README.

**L9** (2026-11-20) — **T-3 verificado: la huella funcional de `gga` es cero.** `.gga` y `.gga/` no existen en disco; `.git/hooks/` no contiene ningún hook (solo los `*.sample` que trae git); `git ls-files | grep -i gga` no devuelve nada; no hay mención a `gga` en `.github/`, `tools/`, `src/`, `tests/` ni `build.zig*`. Los únicos matches en todo el repo son entradas de logbook de features ya cerradas y los falsos positivos de subcadena "Plu**gga**ble" en `src/terminal/term.zig` y `tests/terminal/term.zig`. **No hay nada que eliminar**: la retirada ya se había ejecutado el 2026-10-27 (L24 del doc `zig-0.17-migration.md`). El pedido del usuario queda **satisfecho por el estado previo**, verificado, no por una acción nueva.

**L10** (2026-11-20) — **Observación diferida, fuera de alcance**: 25 comentarios de código en `src/*.zig` siguen diciendo "Zig 0.16" al describir el comportamiento del stdlib (p. ej. `src/sandbox_linux.zig:316` "future Zig 0.16.1+ stdlib upgrade"). Son afirmaciones técnicas sobre el stdlib y no sobre el toolchain pinneado, así que no son un defecto de este cambio; barrerlos es una feature de higiene propia, no parte del bump.

**L11** (2026-11-20) — **El gate encontró un verde falso.** Los 7 pasos de AGENTS.md §10 pasaron, pero el banner del CI local imprimió `Zig: 0.17.0`: la imagen `localhost/zargeant-ci:latest` (creada 3 semanas antes) se reutilizó. Causa: `tools/local-ci.sh` solo re-bakea cuando la imagen **no existe** o cuando se pasa `--rebuild-image` — cambiar `ZIG_VERSION` no invalida la imagen. Consecuencia: el `just ci` validó **0.17.0**, no 0.17.1. El toolchain pinneado no estaba verificado dentro del contenedor, que es justo donde el gate tiene que ser independiente.

**L12** (2026-11-20) — **`.minimum_zig_version` no es un guard.** Con `build.zig.zon` exigiendo `0.17.1`, el build dentro de la imagen con Zig **0.17.0** pasó (`zig build check` + los 14 steps del CI local). El pin documenta la exigencia pero no la impone. El único detector real del toolchain en uso es la versión que hay dentro de la imagen — por eso el banner del CI (`podman run … zig version`) sí era honesto y delató la imagen stale.

**L13** (2026-11-20) — **Fix S5 aplicado** en `tools/local-ci.sh`: antes de reusar la imagen, el script compara el `zig version` real de la imagen con el `ZIG_VERSION` esperado y re-bakea ante cualquier diferencia, con mensaje explícito (`CI image has Zig X, expected Y: re-baking`). Se reutiliza el mismo mecanismo del banner, que es el único que no puede mentir. El pin `.minimum_zig_version` se mantiene (documenta la exigencia) pero deja de ser la única defensa: ya no se apoya en él como verificación.

**L14** (2026-11-20) — **Gate completo verde sobre Zig 0.17.1**, en el orden de AGENTS.md §10: `just build` ✓ · `just build-safe` ✓ · `just build-fast` ✓ · `just check` ✓ (fmt + ast-check + syscalls + TDD + co-author) · `just test-all` ✓ (9 steps nombrados + umbrella **226/226**) · `just verify` ✓ (**21/21 steps, 314/314 tests**) · `just ci` ✓ (**14 steps OK**). La última corrida del CI local corrió contra la imagen **re-horneada con Zig 0.17.1**, con el banner verificado en `Zig: 0.17.1`; el re-bake se disparó solo con `CI image has Zig 0.17.0, expected 0.17.1: re-baking`. El gate previo (7/7 verde) queda registrado en L11 como verde falso; este es el verde real.

**L15** (2026-11-20) — **Commits** (rama `feat/zig-0.17.1-toolchain`): `38ebdd9` `chore(toolchain): bump Zig 0.17.0 to 0.17.1` (9 ficheros, 17 líneas) · `b794425` `ci: re-bake the CI image when its Zig does not match` (`tools/local-ci.sh`, +10). El work unit de riesgo **item 5** (el fix del harness) va en su propio commit para que el review pueda tomarlo solo. (Hashes originales sin firma: `1967f52` y `965bf82` — ver L18.)

**L17** (2026-11-20) — **Verificador independiente (verification rule, item 5)**: `gentle-ai-verify` sobre `git diff main..HEAD`. Veredicto: **PASS en S1, S2, S2-restricción, S3, S4, S5 y alcance del diff — cero bloqueadores**. Evidencia: `git grep "0.17.0"` sobre el árbol trackeado → 0 pines vivos (solo los 4 enunciados históricos, byte-idénticos a `main`); los 4 pines declaran 0.17.1; la matriz de comportamiento del fix de `tools/local-ci.sh` probada con `podman` stubbeado en un scratch: (a) mismatch → mensaje + `rmi` + `build`, (b) match → **sin** `build`, (c) `podman run` fallando → el script **no aborta** y re-bakea (`|| true` neutraliza `set -e`), (d) `podman build` fallando → exit 1 **sin banner**, (e) `--rebuild-image`/`--clean`/`--shell`/`--skip-build` y el `trap cleanup` intactos. La comparación es **fail-safe**: cualquier salida extra de `podman run` ⇒ mismatch ⇒ re-bake, nunca un verde falso.

**L18** (2026-11-20) — **Commits firmados con la GPG del usuario**. La verificación de firma encontró los 3 commits **sin firmar** (`sig=N`) pese a que el global del host tiene `commit.gpgsign=true` y `user.signingkey=3335F4A0D9DBBA95`: la causa era un override **repo-local** `commit.gpgsign=false` en `.git/config`, que anulaba la política global (todos los commits previos de `main` sí están firmados). Fix: `git config --unset commit.gpgsign` → la política global vuelve a regir y los próximos commits salen firmados. Los 3 commits se reconstruyeron firmados (`git commit-tree -S`) conservando tree, mensaje y fechas byte a byte: `1967f52 → 38ebdd9`, `965bf82 → b794425`, `050c8df → 7827ea1`. `git verify-commit` OK en los tres (RSA `51DCA8B4FD63F3309B7196473335F4A0D9DBBA95`, firmante *Kat's GPG Key (Mi llave GPG Personal para GitHub)*), `git log %G?` = `G`. La rama se movió con `git update-ref` **atómico** (con el valor viejo esperado) para no reescribir historia bajo el verificador, que estaba leyendo `git diff main..HEAD`; los objetos firmados se construyeron antes como colgantes, sin tocar el working tree.

**L19** (2026-11-20) — **Advisories del verificador, ninguno bloqueante**: (1) la comparación de versión es exacta → cualquier línea extra en el stdout de `podman run` (un warning) o una futura `0.17.1-dev.x` provoke re-bake en cada invocación (dirección segura, coste alto en ese caso); (2) la sonda añade un arranque de contenedor extra por invocación (~1 s); (3) el banner no lleva `|| true` (preexistente; tras S5 la exposición es mínima porque la sonda previa ya re-bakeó); (4) `tools/local-ci.sh:10` dice "197 tests" y el real es 226 (preexistente, ya en L5.4); (5) `docs/decisions/0001-libvaxis-to-mibu.md:50` dice "Zig 0.16 stays the only toolchain" — es el registro fechado (Accepted 2026-08-10) de una decisión pasada; los ADR no se reescriben, y la migración a 0.17.0 ya lo había dejado igual, así que **no se toca**; (6) el paso embedded aborta con exit 1 sin mensaje "FAILED" si el grep no encuentra nada (preexistente; no es verde falso, solo menos informativo).

**L20** (2026-11-20) — **Probes de regresión propuestos por el verificador, pendientes de decisión del usuario** (no son bloqueantes): (P1) `tests/toolchain_pins.zig` — guards estáticos que comprueban que los 4 pines declaren la misma versión, que ninguna superficie funcional mentione `gga`, que el README declare un único toolchain y que `local-ci.sh` compare la versión de la imagen; requiere wiring en `build.zig` + receta en `justfile`. (P2) `tools/local-ci-stale-image.test.sh` — prueba **conductual** del S5 con `podman` stubbeado (imagen stale → re-bake; imagen correcta → sin re-bake), que es la que cubre el caso que el gate no detecta solo.

**L16** (2026-11-20) — **Review nativo (RDD `on` global)**: `gentle_review assess` sobre el rango commiteado devolvió `risk: high`, `nativeRisk: unassessable` (`package-local-binary-missing`: el binario nativo de review no está instalado en este host, así que la vía nativa no puede clasificar el riesgo), `candidate: null`, `outcome_source: unknown`, `writerProfile: large`. El plan exige **writer self-verification** + **verificador independiente** (el escalado nombra item 5). **La revisión nativa de 4 lentes no es ejecutable en este host**: se reporta como **unavailable**, nunca como aprobada.
