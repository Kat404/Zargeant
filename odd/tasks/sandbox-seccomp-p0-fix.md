# Sandbox seccomp P0 — el filtro de syscalls nunca se aplicó

**Feature**: `sandbox-seccomp-p0-fix`
**Mode**: ODD + Strict TDD (RED→GREEN)
**Source-of-truth priority**: code > este doc. Si el código y el doc discrepan, el código gana y el doc se actualiza.
**Branch**: `feat/sandbox-seccomp-p0` (apilada sobre `feat/zig-0.17-migration @ 6959aa5`)
**Alcance**: el builder cBPF del filtro seccomp y la allowlist efectiva del sandbox. Fuera de alcance: el rediseño del modelo de permisos del sandbox.

## Goal

Que el sandbox **instale de verdad** el filtro seccomp que dice instalar, y que ese filtro imponga la política de la profile (allowlist efectiva menos la denylist explícita).

Hoy el sandbox **anuncia** una política de syscalls y no aplica ninguna: el programa cBPF que se envía al kernel está mal construido, el kernel lo rechaza con `EINVAL`, y el hijo del sandbox muere con `exit_group(123)` (`sandbox_setup_failed`) en vez de ejecutar el comando.

## Context (procedente de `odd/tasks/zig-0.17-migration.md`, L31/L32/L33)

- **L31**: el filtro seccomp nunca se aplicó. Instrumentación: `loadFilter err=LoadFilterFailed` ×7 y `seccomp rc=18446744073709551594 errno=-22` → **EINVAL**.
- **L32**: la sonda de capacidad (`sandbox_linux.sandboxEnforceable()`) instala programas **conocidos-buenos** a propósito y en este host devuelve `true` → la plataforma **sí** soporta seccomp. El defecto es **nuestro**.
- **L33**: causa raíz aislada. `buildToolBpf` (`src/sandbox.zig`) reserva `[6 + allow.len]` instrucciones pero solo inicializa los índices `0`, `4..5+allow.len`: **los índices 1, 2 y 3 quedan `undefined`**. El kernel recibe instrucciones basura y rechaza el programa.

Evidencia directa (sonda fuera del repo, sobre el kernel de este host):

| Programa | `seccomp()` | `write()` bajo el filtro |
|---|---|---|
| `buildToolBpf` (el del repo) | **EINVAL (22)** | — (el filtro nunca existió) |
| `Seccomp.buildAllowlist` (completo, con arch check) | **0 (OK)** | sobrevive |

El comentario que eliminaba el arch check (`"the Zen kernel here reports a different arch value"`) era un **diagnóstico erróneo**: `AUDIT_ARCH_X86_64 = 0xC000003E` es el valor correcto y funciona en este kernel.

Efecto observable en la suite (umbrella `src/root.zig`, 220 tests): **213 passed / 7 failed**. 6 de los 7 fallos son este defecto (`expected 0, found 123`); el séptimo (`modal.test.CAP-08`) es preexistente de la rama post-roadmap y no se toca aquí.

## Specs

### S1 — El filtro seccomp debe instalarse (comportamiento observable)

El hijo que instala el filtro de producción (`tool_bpf_prog`) debe **superar la instalación**. Observable desde la interfaz pública: si el filtro se instala, el hijo muere por `SIGSYS` al ejecutar una syscall fuera de la allowlist; si la instalación falla, el hijo muere con `exit_group(123)` y **ninguna** syscall se filtra.

Verbatim del fallo actual (umbrella):

```
173/220 sandbox.test.Sandbox.spawnToolSubprocess fork /bin/true waitpid returns 0...expected 0, found 123
174/220 sandbox.test.Sandbox.spawnToolSubprocess child /tmp writable...expected 0, found 123
175/220 sandbox.test.Sandbox.spawnToolSubprocess child /etc/shadow EACCES...expected 1, found 123
```

Requisito: con el filtro instalado, `spawnToolSubprocess("/bin/true")` devuelve exit code **0** (no 123), y una syscall denegada (por ejemplo `ptrace`, 101) mata al hijo con **SIGSYS**.

### S2 — La denylist explícita de la profile debe respetarse

La `Profile` declara `denied_syscalls` (`default_deny_syscalls`, 13 entradas: `ptrace`, `mount`, `bpf`, `perf_event_open`, `unshare`, …). La allowlist efectiva del sandbox **no puede contenerlos**: un filtro que permite `mount` mientras la profile lo declara denegado hace que la profile mienta.

Requisito: la allowlist efectiva = (`startup_allow_syscalls` ∪ `profile.allowed_syscalls`) − `profile.denied_syscalls`. Verificable por test sobre la lista efectiva.

### S3 — El filtro debe validar la arquitectura

El programa cBPF debe comprobar `AUDIT_ARCH_X86_64` y matar el proceso si la arquitectura no coincide. Sin ese check, una llamada `int 0x80` (ABI ia32) usa **numeración de syscall distinta** y puede eludir la allowlist: p.ej. ia32 `chown` es el nr 12, que en x86_64 es `brk` (permitido).

Requisito: la primera instrucción del programa carga `seccomp_data.arch` (offset 4), no `seccomp_data.nr` (offset 0).

### S4 — El sandbox debe seguir funcionando con el filtro aplicado

Activar el filtro es un cambio de comportamiento real: hasta ahora el hijo corría **sin** política de syscalls. Requisito: los tests de comportamiento existentes siguen verdes con el filtro activo (`/bin/true` → 0, `/tmp` escribible, `/etc/shadow` → EACCES, stdout capturado).

## Tasks

| # | Specs | Cambio | Ruta | Riesgo | Commit |
|---|---|---|---|---|---|
| T-1 | S1,S3 | Tests RED: el filtro se instala y mata por `SIGSYS` una syscall denegada; el programa carga `arch` | `src/sandbox.zig` | item 2 | pendiente |
| T-2 | S1,S2,S3 | Fix del builder: usar el programa completo con arch check y la allowlist efectiva (allow − deny) | `src/sandbox.zig` | item 2 | pendiente |
| T-3 | S1,S2,S4 | GREEN: suite completa del sandbox + umbrella | `src/` | item 2 | pendiente |
| T-4 | S1,S2 | Verificador independiente (item 2: seguridad) | — | item 2 | pendiente |
| T-5 | — | Cierre: doc + Log + commit final | `odd/tasks/` | none | pendiente |

## Log

**L1** (2026-10-29, verbatim) — "Prosigue en donde lo dejamos con el desarrollo de Zargeant, creo que ya teníamos una rama para migrar a Zig 0.17.0"

**L2** (2026-10-29) — Reanudación: la migración a 0.17.0 estaba en `feat/zig-0.17-migration` con el PR #59 abierto. Gate completo re-ejecutado: builds y `just check` verdes, `just test` verde (9/9), `test-embedded` y `verify` con **213/220**. Los 7 fallos son 6 de este P0 + 1 preexistente (`modal.test.CAP-08`). El P0 es el único bloqueante del umbrella verde, así que pasa a ser el siguiente work unit.

**L3** (2026-10-29) — **Causa raíz aislada por sonda directa** (fuera del repo, `mktemp`-style scratch): con el programa del repo → `seccomp()` devuelve **EINVAL (22)**; con `Seccomp.buildAllowlist` (completo, con arch check) → carga OK y `write()` sobrevive bajo el filtro. Conclusión: el defecto es el layout del programa (índices 1..3 sin inicializar), **no** la plataforma (contra lo que concluía L22 de la doc de migración).

**L4** (2026-10-29) — **Segunda causa raíz, ligada a S2**: la allowlist que el sandbox instala hoy es `diagnostic_allow` (19 syscalls, etiquetada "DIAGNOSTIC"), porque el filtro nunca se aplicó y una lista tan pequeña no tenía consecuencias. Con el filtro real, esa lista mataría a cualquier binario real (`rt_sigaction`, `access`, `newfstatat`… no están). La lista diseñada para el sandbox es `merged_allowlist` (`startup_allow_syscalls` ∪ `profile.allowed_syscalls`), hoy usada **solo** por un assert de comptime. El fix usa esa lista **menos** la denylist de la profile, que de otro modo mentiría (permitiría `mount`, `bpf`, `unshare`…).

**L5** (2026-10-29) — **La causa raíz era más profunda: el salto clásico BPF es de 8 bits.** El builder compartido (`sandbox_linux.Seccomp.buildAllowlist`) tenía un layout *completo* (sin huecos) y con arch check, y aun así el filtro denegaba todo. Medición directa: `struct sock_filter` es `{code u16, jt u8, jf u8, k u32}` — las distancias de salto son **8 bits**, mientras que el builder calculaba la distancia hasta un `RET ALLOW` compartido como `N - i` (cientos). El kernel trunca la distancia a 8 bits → el salto cae dentro de la tabla → el filtro acaba en la rama de denegación. Solo funcionaban las entradas con distancia < 256 (por eso una prueba con 4 syscalls pasaba y la allowlist real de 461 no). Evidencia: barrido de nrs con el filtro puesto (solo `write`, `exit_group` y el nr probado en la allowlist) → todos los nr probados se permitían; y con la allowlist real, `execve` (índice 0, distancia 461) se denegaba. Además, el byte 1 de la instrucción clásica es el byte alto del opcode, y en el `BPF.Insn` de Zig ese byte lleva `dst/src` → **`dst` debe quedar en `.r0`** o corrompe el opcode.

**L6** (2026-10-29) — **Layout corregido**: un `RET ALLOW` por entrada, con la distancia de salto siempre ≤ 1. `JEQ nr_i, jt=0 (match → su ALLOW) / jf=1 (no match → siguiente entrada)`, y el `RET KILL` final. Tamaño = 5 + 2N (927 instrucciones con la allowlist efectiva; el límite del kernel es 4096). El byte `off` de `BPF.Insn` mapea al par `(jt, jf)`: `jt = off & 0xFF`, `jf = (off >> 8) & 0xFF` — `BPF.Insn.jeq` solo puede fijar `jt`, así que el builder emite la instrucción a mano.

**L7** (2026-10-29) — **Allowlist efectiva** = (`startup_allow_syscalls` ∪ `profile.allowed_syscalls`) − `profile.denied_syscalls`. La lista que el sandbox instalaba era `diagnostic_allow` (19 syscalls, etiquetada "DIAGNOSTIC"), válida solo porque el filtro nunca se aplicaba; con el filtro real esa lista mataría a cualquier binario (`rt_sigaction`, `access`, `newfstatat`…). La lista diseñada para el sandbox (`merged_allowlist`) solo la usaba un assert de comptime. Se resta la denylist de la profile para que el filtro no la contradiga (`mount`, `bpf`, `unshare`… quedan denegados).

**L8** (2026-10-29) — **Landlock: `EXECUTE` faltaba en los perfiles.** Con el filtro ya vivo, el hijo llegaba al `execve` y moría con `EACCES`: el intérprete ELF (ld.so) lo abre el kernel con `FMODE_EXEC`, así que necesita `EXECUTE` en su directorio, y el perfil de test solo concedía `READ` en `/bin` y `/usr/bin`. Se añadió `EXECUTE` en el directorio del intérprete (`/usr/lib`) y en los directorios de binarios del perfil de test; `TOOLS_PROFILE` (producción) recibió la regla `/usr/lib` con `EXECUTE`. Sin esto el sandbox no puede arrancar ninguna herramienta — un defecto que el filtro roto ocultaba (el hijo moría antes, en 123).

**L9** (2026-10-29) — **Verificación**: `zig test src/sandbox.zig` → 36/36 verdes (antes 29/34 con 5 fallos). Umbrella `zig build test-embedded` → **224/224 verdes** (antes 213/220 con 7 fallos). Los 6 fallos del sandbox (exit 123) están cerrados. El séptimo (`modal.test.CAP-08`) era un **bug de test preexistente** de la rama post-roadmap: pasaba un draft vacío y assertaba `key_len > 0` → se le pasa una key real; es un arreglo de test fuera del alcance del P0, incluido porque bloqueaba el gate verde.
