# Protocolo de auditoría y uso de subagentes — `zargeant`

> **Archivo de contrato operativo.** Léelo completo antes de auditar, corregir findings, o delegar a `mcode`.
> **Agente principal**: MiniMax-M3 en OpenCode. **Subagente**: `mcode exec` → MiniMax-M3.1-Flash-Preview.
> **Versión**: 1.0 · **Fecha**: 2026-10-01

---

## 0. TL;DR

Eres M3, el agente principal. Escribes el código, lo entiendes, y decides. `mcode` es un **revisor con contexto limpio** que **no puede ejecutar nada**.

El flujo correcto es siempre de **tres etapas**:

```
1. ANÁLISIS     → tú, con acceso a §11 (27 incidentes) y al porqué de cada tradeoff
2. AUDITORÍA    → mcode, read-only, contexto limpio, 1M window
3. VERIFICACIÓN → tú, finding por finding, contra código + docs normativas
```

**La etapa 3 es la que carga el peso.** Un subagente genera hipótesis; tú las conviertes en findings. Si saltas la etapa 3, no tienes un informe — tienes ruido con formato de informe.

**Regla de una línea**: *no delegues nada que no vayas a verificar.*

---

## 1. Fuentes y precedencia

### 1.1 Jerarquía

```
1. CÓDIGO           ← manda siempre
2. man pages / kernel.org / ziglang.org   ← para validar comportamiento de plataforma
3. odd/tasks/*.md (feature docs activos)
4. AGENTS.md, docs/conventions.md
5. zargeant-context-for-ai-agent.md       ← contiene Lies conocidos (ver §1.3)
6. README.md                             ← el más desactualizado
```

Cuando 1 y 5 discrepan: **manda 1**. No lo "arregles" — documéntalo como drift y sigue.

### 1.2 Por qué importa aquí

Este proyecto es un caso patológico de documentación que miente. Slice 7 se mergeó con el sandbox en fail-open, 7 use-after-free y el path LLM muerto — y pasó: 500+ tests verdes, CI verde, `zig build run` verde. **La documentación y los tests mienten; el código no.**

Si auditas contra el doc, auditas contra fiction.

### 1.3 Lies conocidos (verificados 2026-10-01)

| Afirmación falsa | Realidad | Dónde |
|---|---|---|
| Existe `src/tls_conn.zig` | **No existe.** El TLS es `pub const tls_conn = struct{...}` inline en `api_client.zig:1736-1833` | README, context doc §4.3 |
| `tls_conn` es "handrolled, sin openssl" | Es un wrapper de `std.http.Client.connectTcp` / `std.crypto.tls.Client` | context doc §3.1, §4.3 |
| `static_messages_storage` es thread-local | Es un **global compartido** | context doc §3.1 vs `runtime.zig:120` |
| `PR_SET_DUMPABLE` se usa antes de cargar secrets | **No existe en el código** | context doc §10.7 |
| Todos los payloads de `Event` usan inline buffers | 4 variantes cruzan hilos con `[]const u8` | context doc §3.3 vs `channels.zig:88-132` |
| `startup_allow_syscalls` deniega `ptrace`/`mount`/`reboot` | Los comentarios dicen "NO, denied" pero **los números están en la allowlist** | `sandbox.zig:43-503` |
| Landlock es "best-effort FS hardening" | Esa es la política que **causó** P0-01. Debe ser fail-closed | `sandbox.zig:748-754` |

### 1.4 Drift de workflow

30 referencias a `sdd/*` en 18 archivos, 3 a `apply-progress` (fase cerrada), `root.zig:12` con un `id=` vacío. El proyecto migró de SDD → ODD (obs#1794) y la migración quedó a medias.

**No trates `sdd/*` como fuente. Trátalo como drift (finding P5).**

---

## 2. Los documentos `.md` y sus roles

Nunca son intercambiables.

| Archivo | Rol | Cómo lo usas |
|---|---|---|
| `zargeant-context-for-ai-agent.md` | Referencia de arquitectura + §10 convenciones duras + §11 incidentes + §14 anti-patterns | **Consulta.** Es el "porqué". Las líneas citadas (`runtime.zig:830`, `channels.zig:69`) están obsoletas en un punto: el conteo de variants de `Event`. Verifica contra el código. |
| `docs/conventions.md` | **BINDING.** Convención de inline buffer | **Aplica sin excepción.** Es la fuente de la regla que P0-06…P0-09 violan 7 veces. |
| `AGENTS.md` | Tiger Style + QA gate order §10 | **Aplica.** El orden de gates (`build → check → test-all → verify → ci`) no se negocia. |
| `odd/tasks/*.md` | Feature docs activos | **Consulta + escribe.** Cada WU nuevo empieza con un feature doc (ODD). |
| `docs/io-async-bug-investigation.md` | Contexto de `std.Io` sync/async + futex deadlock | **Consulta** antes de tocar cualquier networking. |
| `AUDIT-REPORT.md` | **Evidencia.** 41 findings con `archivo:línea` | **Consulta, no ejecutes.** Cita el finding ID cuando referencies un problema. |
| `ODD-REMEDIATION-PLAN.md` | **Contrato ejecutable.** 10 slices, ~34 WUs | **Sigue slice por slice.** Es una propuesta, no código verificado. |

### 2.1 Regla de oro

> **El código del plan es una *propuesta*, no código que compila.** Si no compila, corrígelo y **reporta la desviación**. No lo apliques a ciegas.

---

## 3. El protocolo de tres etapas

### ETAPA 1 — Análisis (tú, sin delegar)

Antes de considerar delegar, juega tu turno:

1. Lee el código directamente. No el resumen del doc.
2. Traza los call sites. Un finding sin call-site traceado es especulación.
3. Consulta `docs/conventions.md` y §10/§14 del context doc.
4. Formula **hipótesis explícitas**, no conclusiones. "Creo que X leakea en Y path" — no "X fuga".

**Salida de esta etapa**: una lista de hipótesis con confianza declarada.

### ETAPA 2 — Auditoría (mcode, read-only)

Ver §5 para el cuándo/cómo. El subagente:
- **No puede ejecutar nada.** Su output son hipótesis, no veredicto.
- **No conoce el porqué.** No tiene §11, no tiene los 27 incidentes. Pregúntale por *qué*, y toma su respuesta con escepticismo.
- Devuelve hallazgos con `archivo:línea`.

### ETAPA 3 — Verificación (tú, sin delegar)

**Ninguna etapa de esto se puede saltarse.**

Para **cada** finding del subagente, antes de que entre al informe:

```bash
# 1. El archivo y la línea existen y dicen lo que dice el finding
sed -n '<linea-3>,<linea+3>p' src/<archivo>.zig

# 2. ¿Hay un call site real? (traza, no asumas)
rg '<funcion>\(' src/ tests/

# 3. ¿El comportamiento de plataforma es el que creo?
#    man7.org / kernel.org / ziglang.org
```

Luego clasifícalo:

| Categoría | Criterio | Acción al informe |
|---|---|---|
| **Confirmado** | Leíste el código, la línea dice eso, el mecanismo es coherente | Finding con evidencia `archivo:línea` |
| **Refutado** | Leíste el código y dice otra cosa | **Mándalo explícitamente** — "hipótesis X refutada: Y" |
| **Hipótesis** | Plausible pero no verificable sin toolchain | **Márcalo como hipótesis.** No lo presentes como hecho |

**Refutar es tan valioso como confirmar.** En esta auditoría, una de las 6 hipótesis propias se refutó: `.host = host` parecía un Bug 1 class, y el trace de los 2 call sites mostró que ambos pasan literales compile-time. Eso evitó un WU innecesario.

---

## 4. Regla de evidencia (BINDING)

> **Ningún finding entra al informe sin verificación contra el código.**
> **Ningún WU se mergea sin el output del test RED capturado** (cómo falló, no "debería fallar").
> **Nada se reporta como "compila" sin haber corrido el comando y pegado la salida.**

Tres frases. Si el proyecto las hubiera tenido, 41 bugs no habrían sobrevivido a 7 slices verdes.

### 4.1 Formato de un finding verificado

```markdown
#### P0-01 · `src/sandbox.zig:755` + `:772` · Landlock nunca se aplica (fail-open)

**Qué pasa**: `Landlock.restrictSelf()` (`:755`) se llama ANTES de
`prctl(PR_SET_NO_NEW_PRIVS)` (`:772`). landlock_restrict_self(2) requiere
`no_new_privs` O `CAP_SYS_ADMIN` → `EPERM` determinista para usuario no-root.
El error se traga con `catch {}`.

**Evidencia normativa**: man7.org landlock_restrict_self(2) — *"either the caller
must have the CAP_SYS_ADMIN capability in its user namespace, or the thread must
already have the no_new_privs bit set"*.

**Evidencia en código**: `sandbox.zig:755`, `sandbox.zig:772`

**Test RED**: `tests/sandbox_order.zig` — guard de orden estático.
```

Cinco campos. Sin `archivo:línea` no es un finding, es una opinión.

---

## 5. Política de `mcode`

### 5.1 CUÁNDO delegar

Delegar si y solo si se cumplen **las dos**:

- **A1 — Superficie separable.** Hay un límite claro ("el sandbox", "el path TLS", "el canal X"), no "todo el proyecto".
- **A2 — Hay un answer key.** Existe un comportamiento esperado definible ("un tool sandboxed NO puede leer `/etc/shadow`"). Si la pregunta es "¿esto es buena arquitectura?", no hay answer key → no delegar.

Y **una condición adicional, la que más se olvida**:

- **A3 — Voy a verificar la salida.** Si no vas a leer `archivo:línea` por `archivo:línea` (§4), no delegues. Es peor que no delegar: te deja dos fuentes sin reconciliar y ninguna ejecutada.

### 5.2 CUÁNDO NO delegar

| Situación | Por qué no |
|---|---|
| Tarea trivial (typo, una línea, un import) | Overhead >> valor. Doc de Engram: "NUNCA usar para tareas triviales" |
| Implementación | El subagente no conoce tu intención. Pierde el porqué. Delegar implementación es la forma más rápida de perder contexto |
| Debugging interactivo | Necesitas el loop `ver → corregir → ver`. Un one-shot no itera |
| `src/terminal/` | La propia auditoría dice que es excelente. Baja consecuencia, confianza alta |
| Cuando estás apurado | Un audit sin tiempo para verificar es teatro con formato de rigor |

### 5.3 CÓMO

```bash
mcode exec \
  --model minimax-coding-plan/MiniMax-M3.1-Flash-Preview \
  --effort max \
  --prompt-mode work \
  --cwd /ruta/al/zargeant \
  --timeout 10m \
  -o /tmp/mcode-<slice>.log \
  "AUDITORÍA READ-ONLY (NO ESCRIBAS NADA).

   CONTEXTO: zargeant — AI agent harness TUI, Zig 0.16, cero third-party deps.
   Landlock + Seccomp deny-by-default. 3 hilos. Snapshot 2026-09-29.

   PRECAUCIÓN — el código y la documentación discrepan en puntos conocidos:
     - No existe src/tls_conn.zig; el TLS es inline en api_client.zig:1736-1833
     - static_messages_storage NO es thread-local (runtime.zig:120)
     - PR_SET_DUMPABLE no existe en el código
   El CÓDIGO MANDA sobre cualquier afirmación del doc.

   ARCHIVOS: src/sandbox.zig src/sandbox_linux.zig src/sandbox_profile.zig

   TAREAS:
   1. Verificar el orden de aislamiento contra landlock_restrict_self(2).
   2. Verificar que ningún error de prctl/restrictSelf/seccomp se descarta.
   3. Verificar que el BPF de producción valida seccomp_data.arch.
   4. Verificar que el seccomp instalado deriva de TOOLS_PROFILE, no de
      diagnostic_allow.
   5. Identificar allowlists con syscalls de escape (ptrace, mount, bpf...).

   DEVUELVE:
   - Por finding: archivo:línea, qué pasa, por qué importa, evidencia
   - Nivel de confianza explícito (confirmado / hipótesis)
   - Si un hallazgo depende de comportamiento de kernel, cita la man page

   NO modifiques archivos. Solo lectura y razonamiento."
```

**Invariantes del comando** (tu memoria de Engram acertó en estos):

- `-o <archivo>` **siempre**. Output >30KB mata el shell por SIGKILL.
- `--effort max` **siempre** para auditorías.
- `--prompt-mode work` **siempre** (nunca `tui`).
- `--cwd <abs>` **siempre**.
- `READ-ONLY (NO ESCRIBAS NADA)` **explícito** en el prompt.
- `DEVUELVE: <formato>` — sin formato pedido, te devuelve prosa.

### 5.4 DÓNDE

| Dónde | Quién | Por qué |
|---|---|---|
| `--cwd /workspace/zargeant` | mcode | Debe ver el árbol real, no `/tmp` (lección de Engram: `node_modules` no accesible desde `/tmp`) |
| `/tmp/mcode-<slice>.log` | mcode escribe, tú lees | Nunca al stdout. El límite de 30KB es real |
| `odd/tasks/<slice>.md` | Feature doc del WU | ODD: el feature doc va **antes** del primer write de producción |
| Engram `odd/<slice>/tasks` | Mirror | Por convención del proyecto (obs#1794) |
| **NO** en `AGENTS.md` | — | `AGENTS.md` es convención, no findings. Findings van a `AUDIT-REPORT.md` |

### 5.5 La debilidad que la doc no documentaba

**M3 y M3.1-Flash-Preview son la misma familia.** No son revisores independientes.

Si la familia tiene un punto ciego sistemático — y el de zargeant es *"el fail-open se siente bien"* — **lo comparten los dos**. Para fronteras de seguridad (sandbox, TLS, secrets), un revisor de otra familia **o un humano** no es opcional.

Añade esto a todo audit de seguridad:

> "Tu output es un conjunto de hipótesis. El agente principal verificará cada una contra el código. No afirmes que un bug 'existe' sin citar archivo:línea exacto."

---

## 6. Correcciones aplicadas a la memoria de Engram

La memoria original (`engram/mcode-usage.md`) tiene buena mecánica operativa y **tres defectos** que hay que corregir.

### 6.1 Defecto A — Afirmación sin medir presentada como hecho

**Original (línea 240)**:
> `7. M3.1-Flash-Preview es 10x más inteligente que M3 estándar para audits.`

Es una observación sensorial con N desconocido, escrita con la confianza de un benchmark. Es exactamente el tipo de afirmación que un audit reprobaría en otro proyecto.

**Corrección**:
> M3.1-Flash-Preview ha producido hallazgos relevantes en las auditorías probadas
> (N≈5, sin medición controlada). Trátalo como hipótesis, no como hecho medido.
> El valor real no es el delta de inteligencia: es el **contexto limpio sin
> racionalización previa**. Valóralo así.

### 6.2 Defecto B — Contradicción interna

**Original**: línea 174 dice `USE SIEMPRE QUE PUEDA`; líneas 274-277 dicen `NO usar para tareas triviales / implementación / debugging interactivo`.

**Corrección** — reemplazar la línea 174 por:
> Gratis no significa gratis. El costo real es tu atención y el wall-clock.
> Si no vas a verificar la salida (§3 ETAPA 3), no la pidas.

Y añadir la regla de A1/A2/A3 de §5.1.

### 6.3 Defecto C — Falta la etapa que carga el peso

El workflow documentado dice "Síntesis (yo): leo el log, cruzo con mi propio análisis". No dice **cómo**.

**Añadir**:
> **Ningún finding entra al informe sin verificación contra el código.**
> Para cada uno: (1) la línea existe y dice eso, (2) hay un call site real,
> (3) el comportamiento de plataforma coincide con la man page.
> Clasificar: confirmado / refutado / hipótesis. Los refutados se reportan
> explícitamente — previenen WUs innecesarios.

### 6.4 Lo que la memoria original acertó (no tocar)

- `-o <archivo>` siempre (límite 30KB del shell, real).
- `--effort max` para auditorías.
- `--prompt-mode work` para no-interactivo.
- `--cwd` explícito.
- `READ-ONLY` explícito.
- **"NO delego implementación a mcode"** (línea 199). Correcto: el subagente
  no conoce tu intención y pierde el porqué.
- Separación `mcode exec` (one-shot) vs `opencode TUI` (interactivo).

---

## 7. Anti-patterns

Cosas que **parecen** correctas y no lo son.

| Anti-pattern | Por qué falla |
|---|---|
| Aceptar el output del subagente sin verificar | El subagente no ejecuta nada. Produce hipótesis plausibles que no reproducen. Peor que no delegar |
| Delegar porque "es gratis" | El costo es tu atención. Un audit sin tiempo para verificar es teatro |
| Auditar "el proyecto" sin límite | Sin superficie separable no hay answer key, y el output es prosa |
| Auditar código que acabas de testear | Ya sabes la respuesta. Es confirmar lo obvio a 3 minutos de latencia |
| Confiar en el doc sobre el código | §1.3. Este proyecto tiene 7 lies documentados |
| Contar "tests verdes" como cobertura | 9 grep-tests + 5 tautológicos. Verifican que un string exista |
| `catch {}` / `_ = syscall()` en frontera de seguridad | Es un P0, no un estilo. P0-01 y P0-02 son exactamente esto |
| Aceptar "10x más inteligente" sin medir | Es una belief, no un dato. Y decide qué modelo usas |
| Un WU sin output del test RED capturado | 500+ tests verdes y 41 bugs vivos. El RED es la evidencia |

---

## 8. Checklist de salida

Antes de entregar cualquier informe, auditoría o fix:

```
[ ] ¿Leíste el código, o estoy resumiendo el doc?
[ ] ¿Cada finding tiene archivo:línea?
[ ] ¿Verifiqué cada finding contra el código (ETAPA 3)?
[ ] ¿Clasifiqué cada uno: confirmado / refutado / hipótesis?
[ ] ¿Los refutados están reportados explícitamente?
[ ] ¿Consulté man pages / kernel.org para lo que depende de plataforma?
[ ] ¿Las afirmaciones del doc que verifiqué como falsas están anotadas como drift?
[ ] ¿Separé "lo que arreglé" de "lo que propongo"?
[ ] Si ejecuté un gate, ¿pegué la salida real (no un resumen)?
[ ] ¿El commit va con -S, sin --no-verify, sin AI co-author?
```

---

## 9. Gate de QA (AGENTS.md §10, sin excepciones)

```
just build && just build-safe && just build-fast   # 1. builds PRIMERO
just check                                           # 2. guards estáticos
just test-all                                        # 3. tests
just verify                                          # 4. 3-mode compile
just ci                                              # 5. Podman, LAST
```

Recordatorio de la lección de Phase 2 (§11.4): **los tests compilan en targets
separados con su propio module wiring. Un test verde NO prueba que el binario
de producción compile.** Por eso builds van primero.

---

*Fin del protocolo. Para los 41 findings con evidencia completa: `AUDIT-REPORT.md`. Para la secuencia de remediación: `ODD-REMEDIATION-PLAN.md`.*
