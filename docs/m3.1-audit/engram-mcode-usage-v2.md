# Cómo usar `mcode` (MiniMax Code CLI) + modelos MiniMax

> **Versión**: 2.0 (corregida) · **Fecha**: 2026-10-01
> **Cambios v1.0 → v2.0**: tres defectos corregidos (afirmación sin medir, contradicción interna, falta de la etapa de verificación). Ver §0.

---

## 0. Qué cambió y por qué

La v1.0 tenía buena mecánica operativa pero tres defectos que la hacen contraproducente en fronteras de seguridad:

| # | Defecto v1.0 | Corrección v2.0 |
|---|---|---|
| **A** | *"M3.1 es 10x más inteligente que M3 para audits"* — afirmación sin medir, presentada como hecho | Reformulado como observación con N declarado. El valor es el **contexto limpio**, no el delta de inteligencia (§4) |
| **B** | Contradicción: línea 174 `USE SIEMPRE QUE PUEDA` vs línea 274 `NUNCA usar para triviales` | Regla de decisión única: A1/A2/A3 (§3) |
| **C** | El workflow decía "cruzo con mi propio análisis" sin decir **cómo** | **Etapa 3 obligatoria** con criterios de clasificación (§2, §5) |

**Lo que NO cambió y no hay que tocar**: la mecánica de la CLI (`-o`, `--effort`, `--prompt-mode`, `--cwd`). Eso está bien y costó descubrirlo.

---

## 1. TL;DR

`mcode exec` es la CLI para invocar modelos MiniMax como subagentes.
**NO es un agente principal.** Es un revisor con **contexto limpio** que **no puede ejecutar nada**.

Su salida son **hipótesis**, no veredicto. Convertirlas en findings es trabajo tuyo.

---

## 2. EL FLUJO: tres etapas, siempre

```
1. ANÁLISIS     → yo, con acceso a los docs de contexto y al porqué
2. AUDITORÍA    → mcode, read-only, contexto limpio
3. VERIFICACIÓN → yo, finding por finding, contra código + man pages
```

**La etapa 3 carga todo el peso.** Si la saltas, no tienes un informe: tienes ruido con formato de informe.

### Etapa 3 — el filtro (esto es lo nuevo y lo importante)

Para **cada** finding antes de que entre al informe:

1. **¿La línea existe y dice eso?** `sed -n '<l-3>,<l+3>p' <archivo>`
2. **¿Hay un call site real?** `rg '<funcion>\(' src/ tests/` — traza, no asumas
3. **¿El comportamiento de plataforma es el esperado?** man7.org / kernel.org / ziglang.org

| Resultado | Qué hacer |
|---|---|
| Las 3 verificadas | **Finding.** Con `archivo:línea` + evidencia normativa |
| El código dice otra cosa | **Refutado.** Reportarlo igual — previene WUs innecesarios |
| No verificable sin toolchain | **Hipótesis.** Marcarlo. No presentarlo como hecho |

> **Refutar es tan valioso como confirmar.** En la auditoría de zargeant, una
> hipótesis propia se refutó al trazar 2 call sites: parecía un use-after-free
> class, y ambos callers pasaban literales compile-time. Eso ahorró un WU entero.

---

## 3. CUÁNDO delegar

Delegar si y solo si se cumplen **las tres**:

- **A1 — Superficie separable.** Hay un límite claro ("el sandbox", "el path TLS"), no "el proyecto".
- **A2 — Hay un answer key.** Existe un comportamiento esperado definible ("un tool sandboxed NO lee `/etc/shadow`"). Si la pregunta es "¿esto es buena arquitectura?", no hay answer key.
- **A3 — Voy a verificar la salida.** Si no vas a hacer la etapa 3, **no delegues**. Es peor que no delegar: dos fuentes sin reconciliar y ninguna ejecutada.

### NO delegar

| Situación | Por qué |
|---|---|
| Tarea trivial (typo, un import) | Overhead >> valor |
| **Implementación** | El subagente no conoce tu intención. Pierde el porqué |
| Debugging interactivo | Necesitas el loop ver→corregir→ver. Un one-shot no itera |
| Código que acabas de testear | Ya sabes la respuesta. Confirmar lo obvio a 3 min de latencia |
| Cuando estás apurado | Un audit sin tiempo para verificar es teatro |

---

## 4. POR QUÉ funciona (el motivo real)

No es "un revisor más inteligente". Es **una ventana de contexto sin compromiso con la justificación original**.

Cuando escribes código, construyes un modelo de *qué quisiste escribir*. Cuando lo relees, lees **a través de ese modelo**. No puedes ver tus suposiciones porque son el lente.

El subagente arranca sin el lente. En zargeant encontró: una allowlist con `ptrace`/`mount`/`reboot` battery-packed; un `poll(nfds=1)` sobre un array de 2 (**un carácter**); 0 de 26 tests de seguridad reales; y que el path completo del LLM era código muerto.

### La debilidad que debes saber

**M3 y M3.1-Flash-Preview son la misma familia.** No son revisores independientes. Si la familia tiene un punto ciego sistemático, **lo comparten los dos**.

Para fronteras de seguridad —sandbox, TLS, secrets— un revisor de **otra familia o un humano no es opcional**.

Añade esto a todo audit de seguridad:

> "Tu output es un conjunto de hipótesis. El agente principal verificará cada una
> contra el código. No afirmes que un bug 'existe' sin citar archivo:línea exacto."

---

## 5. Regla de evidencia (BINDING)

> **Ningún finding entra al informe sin verificación contra el código.**
> **Ningún WU se mergea sin el output del test RED capturado** (cómo falló, no "debería fallar").
> **Nada se reporta como "compila" sin haber corrido el comando y pegado la salida.**

zargeant tiene 500+ tests verdes y 41 bugs vivos. El RED es la evidencia.

---

## 6. Modelos

| Modelo | Costo | Cuándo |
|---|---|---|
| `minimax-coding-plan/MiniMax-M3.1-Flash-Preview` | **GRATIS** | Default para audits. 1M context, thinking max |
| `minimax/MiniMax-M3` | $0.30/$1.20 por M | Cuando M3.1 no basta (raro), o necesitas el modelo estándar |
| `minimax-cn/MiniMax-M3.1-Flash-Preview` | GRATIS | Solo si `.io` está bloqueado por geo |

> **Nota sobre la afirmación "10x más inteligente"**: es una observación sensorial
> con N≈5, sin medición controlada. Trátala como hipótesis. El valor medible es
> el contexto limpio, no el delta de inteligencia.

### Effort levels

- `max` — auditorías, debugging complejo, decisiones arquitectónicas. **Default para ODD.**
- `high` — code review cuando no necesitas full max.
- (sin flag) — rutina.
- `low` — trivial. No usar para ODD.

### Prompt modes

- `work` — **default para ODD.** No interactivo, output directo.
- `coding` — generar código.
- `tui` — interactivo. **Casi nunca para ODD.**

---

## 7. Sintaxis y invariantes

```bash
mcode exec [opciones] "prompt"
```

**Invariantes** (descubiertos, no negociables):

| Flag | Por qué |
|---|---|
| `-o <archivo>` **SIEMPRE** | Output >30KB mata el shell por SIGKILL. Error real, no teórico |
| `--effort max` para audits | Default para ODD |
| `--prompt-mode work` | No interactivo |
| `--cwd <abs>` | El shell puede no estar en el dir correcto |
| `--timeout 10m` | Audits grandes |
| `READ-ONLY (NO ESCRIBAS NADA)` en el prompt | Explícito, no implícito |
| `DEVUELVE: <formato>` en el prompt | Sin formato pedido → devuelve prosa |
| `--output-format text` | Para ODD. Más fácil de leer y procesar |

### Comando canónico

```bash
mcode exec \
  --model minimax-coding-plan/MiniMax-M3.1-Flash-Preview \
  --effort max \
  --prompt-mode work \
  --cwd /ruta/al/proyecto \
  --timeout 10m \
  -o /tmp/mcode-<slice>.log \
  "AUDITORÍA READ-ONLY (NO ESCRIBAS NADA).

   CONTEXTO: <stack, branch, commit>

   PRECAUCIÓN — el código y la documentación discrepan en puntos conocidos:
     <lista de lies>
   El CÓDIGO MANDA sobre cualquier afirmación del doc.

   ARCHIVOS: <paths específicos>

   TAREAS:
   1. tarea específica
   2. tarea específica

   DEVUELVE:
   - Por finding: archivo:línea, qué pasa, por qué importa, evidencia
   - Nivel de confianza explícito (confirmado / hipótesis)
   - Si depende de comportamiento de kernel, cita la man page

   NO modifiques archivos. Solo lectura y razonamiento."
```

Después: `cat /tmp/mcode-<slice>.log`. **Nunca al stdout.**

---

## 8. Plantilla de prompt

```markdown
<AUDITORÍA|DEBUG|VALIDACIÓN> READ-ONLY (NO ESCRIBAS NADA).

CONTEXTO: descripción del proyecto, branch, commit, stack.
PRECAUCIÓN: docs desactualizados. [lista de lies verificados]. EL CÓDIGO MANDA.
ARCHIVOS CLAVE: paths específicos
RESTRICCIONES: no push, no merge, no destructive ops

TAREAS:
1. tarea específica
2. tarea específica
3. tarea específica

DEVUELVE:
- Por finding: archivo:línea, qué pasa, por qué importa, evidencia
- Nivel de confianza (confirmado / hipótesis)
- Riesgos identificados
- Si aplica: man page o doc oficial que respalde el comportamiento

NO modifiques archivos. Solo lectura y razonamiento.
```

---

## 9. Workflow de sesión ODD

1. **Investigación read-only** (yo): leo archivos, consulto Engram, navego código. Formulo hipótesis con confianza declarada.
2. **Audit con mcode** (subagente): el comando canónico de §7.
3. **Verificación** (yo): filtro de §2 Etapa 3 sobre **cada** finding. Refutados van al informe igual.
4. **Implementación** (yo): **nunca delego esto a mcode.** Overhead > valor, y pierde el porqué.
5. **Gate local** (yo): `just build && ... && just ci` según AGENTS.md §10.
6. **Post-audit opcional**: mcode de nuevo si el cambio >3 archivos o toca una frontera de seguridad.

---

## 10. Errores comunes

| Error | Causa | Workaround |
|---|---|---|
| SIGKILL al final del comando | Shell timeout, output >30KB | `-o /tmp/file.log` |
| `Module not found` desde `/tmp` | `node_modules` no accesible | El script va dentro del repo, no en `/tmp` |
| `Model not available for managed_token_plan` | Model ID mal escrito | `opencode models` para ver IDs exactos |
| Output devuelto como prosa inútil | Falta `DEVUELVE:` en el prompt | Pedir formato explícito |
| El subagente "confirma" un bug que no existe | No tiene ejecución | Etapa 3 siempre. Refutar es parte del trabajo |
| Audit de 30KB+ que nunca termina | `--timeout` muy bajo | `--timeout 10m` para superficies grandes |
| Git hooks que rechazan el commit | `--no-verify` o falta `-S` | Nunca `--no-verify`. Siempre `-S` |

---

## 11. Anti-patterns

| Anti-pattern | Por qué falla |
|---|---|
| Aceptar output sin verificar | El subagente no ejecuta. Hipótesis plausibles que no reproducen |
| Delegar porque "es gratis" | El costo es tu atención. Sin verificación es teatro |
| Auditar "el proyecto" sin límite | Sin superficie separable no hay answer key |
| Auditar código recién testeado | Confirmar lo obvio a 3 min de latencia |
| Confiar en el doc sobre el código | Hay documentos que mienten, verificado |
| Contar "tests verdes" como cobertura | Hay grep-tests y tests tautológicos |
| `catch {}` / `_ = syscall()` en frontera de seguridad | Es un bug P0, no un estilo |
| Aceptar "10x más inteligente" sin medir | Es una belief, y decide qué modelo usas |
| Un WU sin output del test RED capturado | Tests verdes + bugs vivos conviven |

---

## 12. Lecciones de sesión (2026-09-29 Hotel Casa Noria)

1. Vite era redundante — Astro lo trae como transitive dep.
2. `pnpm add -D` mueve runtime deps a devDeps — separar `add` de `add -D`.
3. Stripe SDK tests con mocks literales no validan el SDK real — smoke test contra la test API.
4. Lightpanda vía CDP funciona con Playwright — 10x más rápido.
5. El shell mata output >30KB. **Siempre** `-o /tmp/`.
6. M3.1-Flash-Preview encontró hallazgos relevantes en auditorías probadas (N≈5, sin medición controlada).

---

## 13. Costo real

**Tiempo**: ~30s–3min por audit de superficie chica; 5–10min en repo grande con `--effort max`.

**Vale la pena** para: superficies >3 archivos, fronteras de seguridad, comparación de branches, verificación de breaking changes, y **siempre que vayas a verificar la salida**.

**No vale la pena** para: triviales, implementación, ni cuando estás apurado.

**El costo que no se factura**: tu atención en leer y verificar. Ese es el presupuesto real.

---

*Fin. El protocolo completo para zargeant (jerarquía de fuentes, lies verificados, protocolo de 3 etapas con criterios de clasificación) está en `AGENT-AUDIT-PROTOCOL.md`.*
