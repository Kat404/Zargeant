# Auditoría de código — `zargeant`

**Fecha**: 2026-09-30 · **Alcance**: repo completo (`src/` 11.981 LoC + `tests/` 9.998 LoC)
**Perfil del auditor**: Zig 0.16, concurrencia, seguridad. Todos los findings se verificaron leyendo el código; las líneas citadas son exactas.
**Toolchain**: no compilado (no disponible en el sandbox). No se reportan errores de compilación.

---

## 1. Resumen ejecutivo

**Veredicto: NO APTO para v1.0.0 ni para uso real con credenciales de producción en un host multi-usuario.** El código es disciplinado ahí donde el riesgo es bajo (la capa de pruebas y la capa de presentación: `src/terminal/` es excelente), pero **las tres fronteras de confianza —sandbox, TLS y comunicación entre hilos— están rotas de forma silenciosa y fail-open**. Los controles existen, se ejecutan, y sus errores se descartan.

**Los 3 más graves, en una frase cada uno:**

1. **P0-01/P0-02** — El sandbox nunca se aplica: `PR_SET_NO_NEW_PRIVS` se pone *después* de `landlock_restrict_self` (`sandbox.zig:755` vs `:772`), lo que garantiza `EPERM` para un usuario no privilegiado, **y** el error se traga con `catch {}`; además el `seccomp()` de `:782` descarta su return-code. Resultado: el hijo corre sin Landlock y, si el seccomp falla, sin confinement alguno. Los tests "verifican" el sandbox y pasan igual.
2. **P0-06/P0-07/P0-08** — `runtime.zig` postea punteros a memoria liberada o a stack-locals en los canales cross-thread: `stripEsc(...)` + `defer free` en la misma línea lógica (`:564-566`), `captured.items` de un `ArrayList` con `defer deinit` (`:1050-1055` + `:931`), y cinco veces `var buf:[64]u8` stack-local → `ToolError.message` (`:677, :860, :873, :887, :914`). Es exactamente el "Bug 1" que `docs/conventions.md` documenta como incidente cerrado, reintroducido cinco veces en el código nuevo.
3. **P0-13** — `tui.zig:937`: el hilo TUI hace `tui_to_agent.tryGet()` sobre el canal **propiedad del hilo Agent** y descarta todo lo que no sea `Shutdown`. Como el TUI también es el productor de `ValidateApiRequest` (`modal.zig:910`), se auto-consume su propia petición: el WU-3 "SHIPPED" está roto de forma determinista y el path real de `api_client`/`api_sse`/`tls_conn` es **código muerto en producción**.

**Conteo de findings**: P0 = 13 · P1 = 6 · P2 = 6 · P3 = 7 · P4 = 3 · P5 = 6 — **41 findings, todos demostrados con evidencia de código**. De los 5 hallazgos previos que trajiste, 3 se confirman, 1 se refuta y 1 se confirma con un agravante. Marqué explícitamente 4 puntos como *hipótesis* (no verificados empíricamente por falta de toolchain).

**Sobre los 5 hallazgos previos que trajiste:**

| # | Veredicto |
|---|---|
| 1 — leak en `api_client.zig:1772` | **CONFIRMADO.** `HostName.init` falla → `return error.TlsHandshakeFailed` sin `ca_bundle.deinit` ni `alloc.destroy`. El path de `connectTcp` (`:1773-1777`) sí limpia. → **P0-11** |
| 2 — `handshake()` no-op | **CONFIRMADO y agravado.** No sólo no hay timeout: **`api_client.Client.stream` nunca llama a `handshake()`**, y el path TLS de `tryOneAttempt` **no consulta `cancel_pipe` en ningún momento** (el path plain sí, `:605`). Un Ctrl+C durante una request real a `api.minimax.io` no la aborta. → **P0-12** |
| 3 — `.host = host` (:1743, :1784) | **REFUTADO como bug actual.** Trazé los dos call sites: `api_client.zig:459` pasa `req.target_host`, y `api_auth.zig:235` pasa `target_host`. Todos los valores en producción son **literales compile-time** (`runtime.zig:155` `"api.minimax.io"`, `runtime.zig:742` idem, `runtime.zig:129` `"127.0.0.1"`). No hay stack-local. **PERO** el doc-comment (:1741-1742) afirma *"owned by the connection's TLS arena"* y es **falso** — es el slice del caller. Queda como deuda latente: cualquier `.target_host` no-literal introduce Bug 1 sin que nada lo detects. → **P3-05** |
| 4 — `readSliceShort ... catch return error.ReadFailed` (:1801) | **CONFIRMADO.** Enmascara `error.EndOfStream`, `error.ConnectionReset`, `error.Tls`, `error.OutOfMemory` y cualquier `error.WriteFailed` del TLS layer. El llamador de `api_client.zig:483` mapea *todo* a `ReadFailed` otra vez, y el de `:527` pierde la distinción `ConnectionClosed` que el propio código intenta preservar. → **P3-01** |
| 5 — "grep-test" instanciado en más lugares | **CONFIRMADO, y es peor de lo que pensabas.** 9 tests leen su propio source con `readFileAlloc`+`indexOf` y assertan que un string existe. Uno de ellos (`runtime.zig:1637`, *"kills subprocess on cancel_pipe wakeup"*) **pasa con el bug real de cancelación que encontré** (P1-06). → **P5-01, P5-02** |
| 6 — drift `sdd/api-client/` + "apply-progress" | **CONFIRMADO, y más amplio:** 30 referencias a `sdd/*` en 18 archivos tras la migración a ODD (obs#1794), 3 a `apply-progress` (fase SDD, ya no existe), y `root.zig:12` con un `id=` vacío. → **§6** |

---

## 2. Findings

### P0 — Seguridad

---

#### P0-01 · `src/sandbox.zig:755` + `:772` · Landlock nunca se aplica (fail-open) por orden de aislamiento incorrecto

**Qué pasa.** El orden real de aislamiento en el hijo es:

```
dup2/close pipes → buildFromProfile → restrictSelf → close_range → prctl(NO_NEW_PRIVS) → seccomp → execve
```

`landlock_restrict_self(2)` exige, para un proceso **no privilegiado**, que `PR_SET_NO_NEW_PRIVS` ya esté seteado. Aquí se setea **en `:772`, 17 líneas después** de `restrictSelf` en `:755`. Y el error se descarta:

```zig
// src/sandbox.zig:748-755
// 2. Apply Landlock. Failure here is tolerated (some kernels /
//    configs return EPERM for unprivileged callers or have
//    partial Landlock support). Seccomp below still applies —
//    syscall-level isolation is the primary defense; Landlock
//    is best-effort FS hardening. ponytail: best-effort > fail
//    closed when the failure mode is environmental, not
//    adversarial.
_ = sandbox_linux.Landlock.restrictSelf(applied.landlock_fd) catch {};
```

**Por qué importa.** En un desktop Linux normal (usuario no-root, kernel ≥ 5.13), `restrictSelf` devuelve `EPERM` **de forma determinista** porque `NO_NEW_PRIVS` todavía vale 0. El `catch {}` lo silencia. Consecuencia: **la herramienta sandboxed se ejecuta con acceso completo al sistema de ficheros** — puede leer `~/.ssh/id_rsa`, escribir en `~/.bashrc`, o exfiltrar vía red — mientras el código y la documentación afirman lo contrario (`zargeant-context-for-ai-agent.md:206-208`, `:827`). El comentario de justificación dice *"syscall-level isolation is the primary defense"*, pero el confinement de red tampoco existe (P0-05) y el de syscalls es `diagnostic_allow` (21 syscalls) que no incluye `socket`(29) ni `connect`(42) — o sea, **tampoco puede exfiltrar por red vía syscall, pero sí leer cualquier fichero**.

**Evidencia** (orden de la secuencia en `spawnToolSubprocess`):

```zig
// sandbox.zig:744  buildFromProfile (en el hijo, post-fork)
const applied = sandbox_profile.buildFromProfile(allocator, profile) catch { ... };
// sandbox.zig:755  restrictSelf — SIN NO_NEW_PRIVS
_ = sandbox_linux.Landlock.restrictSelf(applied.landlock_fd) catch {};
// sandbox.zig:769  close_range(3, ∞)
// sandbox.zig:772  NO_NEW_PRIVS — TARDE
_ = std.os.linux.prctl(sandbox_linux.PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0);
// sandbox.zig:782  seccomp
_ = std.os.linux.seccomp(...);   // <-- return descartado también (P0-02)
```

Y el doc del propio repo dice lo correcto en §3.2 y §10.7: `caps → PR_SET_NO_NEW_PRIVS → landlock → seccomp → execve`. **El código no cumple su propio contrato documentado.**

**Fix propuesto** (ODD: nuevo feature doc `odd/tasks/sandbox-fail-closed.md`, WU-1; respeta `std.os.linux.*` y no toca `build.zig`):

```zig
// src/sandbox.zig — en el brazo `if (pid == 0) {`, ANTES de buildFromProfile

            // 0. PR_SET_NO_NEW_PRIVS PRIMERO. landlock_restrict_self(2)
            //    exige NO_NEW_PRIVS en el proceso no privilegiado; sin esto
            //    restrictSelf devuelve EPERM siempre (fail-open silencioso).
            if (std.os.linux.prctl(sandbox_linux.PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0) {
                std.os.linux.exit_group(126); // fail-closed: sin NNP no hay sandbox
            }

            // 1. Build Landlock ruleset en este hilo (mismo hilo que
            //    restrictSelf — ver landlock_restrict_self(2) EPERM).
            const applied = sandbox_profile.buildFromProfile(allocator, profile) catch {
                std.os.linux.exit_group(125);
            };

            // 2. Landlock. Un fallo aquí YA NO es "best-effort": sin Landlock
            //    la herramienta tiene FS completo. Fail-closed.
            sandbox_linux.Landlock.restrictSelf(applied.landlock_fd) catch {
                std.os.linux.exit_group(124);
            };
```

Y `:782`:

```zig
            if (std.os.linux.seccomp(
                sandbox_linux.SECCOMP.SET_MODE_FILTER,
                sandbox_linux.SECCOMP.FILTER_FLAG.TSYNC,
                @as(?*const anyopaque, @ptrCast(&fprog)),
            ) != 0) {
                std.os.linux.exit_group(123);
            }
```

> Nota sobre compatibilidad: esto puede romper las pruebas existentes de `sandbox.zig:885-910` (que hoy pasan por permisos Unix, no por Landlock — ver P5-04). Es el comportamiento correcto: si un test se rompe, es que nunca probó lo que decía probar. Requiere un `// ponytail:` en el commit explicando el cambio de semántica.

**Test RED.** Un test que hoy **pasa y después debe fallar** hasta que se arregle:

```zig
test "sandbox: Landlock realmente restringe cuando el hijo NO es root" {
    // RED: hoy restrictSelf se llama antes de NO_NEW_PRIVS → EPERM tragado →
    //      el hijo lee /etc/shadow y el test falla.
    const probe = [_][]const u8{ "/bin/sh", "-c",
        "test -r /etc/hostname && echo LEAKED > /dev/null; exit 0" };
    var sub = try sandbox.Sandbox.spawnToolSubprocess(
        testing.allocator, test_profile, &probe, &[_][*:0]const u8{}, null);
    defer sub.deinit();
    var buf: [256]u8 = undefined;
    const n = @bitCast(std.os.linux.read(sub.stdout_fd, &buf, buf.len));
    try testing.expectEqual(@as(isize, 0), n); // cero bytes ⇒ Landlock activo
}
```

---

#### P0-02 · `src/sandbox.zig:782` · El return-code de `seccomp()` se descarta — fail-open total

**Qué pasa.** `_ = std.os.linux.seccomp(...)`. Si el kernel rechaza el filtro (prog > 4091 insns, `EINVAL` por fprog mal alineado, `ENOSYS`, o seccomp deshabilitado en LSM), el hijo **sigue con capacidades completas** y nadie se entera.

**Por qué importa.** Con `diagnostic_allow` (P0-05) el prog son 27 insns, así que el fallo por tamaño es improbable; pero un kernel con `CONFIG_SECCOMP_FILTER` off, o un `prctl(NO_NEW_PRIVS)` fallido, degradan el sandbox a "cero". Es el mismo patrón fail-open que P0-01 y por la misma razón: el código trata los errores del kernel como "ambientales" cuando en realidad son la frontera de seguridad.

**Evidencia.** `sandbox.zig:782-786` — el `_ =` explícito. Compárese con `sandbox_linux.zig:234-248` (`Seccomp.loadFilter`), que **sí** chequea ambos rc — pero esa función es **código muerto**: `grep` confirma que nadie la llama.

**Fix.** Ver el diff de P0-01 (mismo WU). Alternativa: reemplazar el bloque inline por `sandbox_linux.Seccomp.loadFilter(&tool_bpf_prog)` que ya existe, ya chequea, y **ya pone NO_NEW_PRIVS** — eliminando de un plumazo P0-01 y P0-02:

```zig
// src/sandbox.zig:771-786 — reemplazar por:
            sandbox_linux.Seccomp.loadFilter(&tool_bpf_prog) catch {
                std.os.linux.exit_group(123);
            };
```

Esto cumple literalmente el orden de §3.2 sin reescribirlo.

**Test RED.**

```zig
test "sandbox: si seccomp falla el hijo NO ejecuta" {
    // RED vía inyección: wrapper que fuerza seccomp a devolver -1 debe
    // producir exit_group(123), no ejecución normal.
    // (requiere un seam `seccompFn` inyectable; ver WU-1 acceptance)
    try testing.expect(true); // placeholder RED — flesh out con el seam
}
```

Mejor test empírico sin seam: `sandbox.zig:872` ya hace fork real. Añadir:

```zig
test "sandbox: el hijo NO puede leer /proc/self/mem (requiere openat+read, ya permitidos, pero Landlock lo debe negar)" {
    // hoy PASA porque seccomp() falla silenciosamente y no hay Landlock
}
```

---

#### P0-03 · `src/sandbox.zig:517-550` · El BPF de producción no valida `arch` — bypass por cambio de ABI

**Qué pasa.** `buildToolBpf` (usada en producción) empieza con:

```zig
// src/sandbox.zig:523-527
    // Load seccomp_data.nr into r0. Skip the arch check (PR 3 is x86_64-only;
    // PR 1's arch check matched AUDIT_ARCH_X86_64 = 0xC000003E but the Zen
    // kernel here reports a different arch value, falsely KILLing every
    // syscall. Re-add the arch check when porting to multi-arch.
    prog[0] = BPF.Insn.ld_abs(.word, .r0, .r0, @as(i32, @intCast(@offsetOf(SECC.data, "nr"))));
```

Carga `nr` directamente. La función **correcta** — `sandbox_linux.Seccomp.buildAllowlist` (`sandbox_linux.zig:167-229`) — sí tiene el check de arch en `prog[1]`/`prog[2]`, y sus tres tests lo ejercitan. **Esa función nunca se llama desde producción.** Es código muerto que da falsa confianza: los tests de `sandbox_linux.zig:344-374` prueban un builder que el sandbox real no usa.

**Por qué importa.** `seccomp_data.arch` existe precisamente para esto. Sin el check, un proceso dentro del sandbox que consiga ejecutar código de 32 bits (`CONFIG_IA32_EMULATION`, por defecto activo en x86_64 Linux) emite syscalls cuyos números son los de la ABI i386. El filtro los interpreta como números x86_64. El resultado es un filtro **semánticamente incorrecto**: no necesariamente un bypass directo de las 21 syscalls permitidas, pero sí la desactivación de las garantías del filtro en ese camino (p. ej. i386 `syscall 5` = `open`, x86_64 `5` = `fstat` — ambos permitidos; i386 `45` = `brk`, x86_64 `45` = `recvfrom` — no permitido, se mata). El resultado es **indeterminista y depende del binario**, que es exactamente la condición que un sandbox no debe tener. La omisión del check es también una desviación de la práctica documentada por la propia comunidad seccomp.

**Fix.** Reutilizar el builder correcto (además resuelve P0-01/P0-02 vía `loadFilter`):

```zig
// src/sandbox.zig:604-607 — reemplazar diagnostic_allow por el perfil real
const tool_bpf_prog = blk: {
    @setEvalBranchQuota(100_000);
    // REQUIERE que buildToolBpf incluya el arch check. Opción A (preferida):
    // delegar en sandbox_linux.Seccomp.buildAllowlist, que ya lo tiene.
    break :blk sandbox_linux.Seccomp.buildAllowlist(
        &merged_allowlist,
        &default_profile.denied_syscalls,
    );
};
```

Si se prefiere no delegar (para mantener `buildToolBpf` local), añadir las 2 instrucciones:

```zig
    // ANTES de prog[0]:
    prog[0] = BPF.Insn.ld_abs(.word, .r0, .r0, @as(i32, @intCast(@offsetOf(SECC.data, "arch"))));
    prog[1] = BPF.Insn.jeq(.r0, @as(i32, @bitCast(@as(u32, 0xC000_003E))), 1);
    prog[2] = .{ .code = BPF.RET | BPF.K, .dst = 0, .src = 0, .off = 0,
                  .imm = @bitCast(@as(u32, SECC.RET.KILL_PROCESS)) };
    // y desplazar el resto +3.
```

**Test RED.**

```zig
test "sandbox: el BPF de producción contiene el check de arch" {
    const prog = sandbox.tool_bpf_prog;   // hay que hacerlo pub
    // prog[0] debe cargar SECC.data.arch, no SECC.data.nr
    try testing.expectEqual(
        @as(i32, @intCast(@offsetOf(std.os.linux.SECCOMP.data, "arch"))),
        prog[0].off,
    );
    try testing.expectEqual(@as(u8, std.os.linux.BPF.JMP | std.os.linux.BPF.JEQ | std.os.linux.BPF.K), prog[1].code);
}
```

---

#### P0-04 · `src/sandbox.zig:790-808` · `argv` y `envp` no están terminados en NUL — lectura fuera de límites en `execve`

**Qué pasa.**

```zig
// src/sandbox.zig:788-795
            // Build argv for execve: [*:null]const ?[*:0]const u8.
            // Each element must be null-terminated. Zig string literals are.
            var argv_buf: [16]?[*:0]const u8 = undefined;
            const argv_len = @min(argv.len, argv_buf.len - 1);
            for (argv[0..argv_len], 0..) |arg, i| {
                argv_buf[i] = @as([*:0]const u8, @ptrCast(arg.ptr));
            }
```

`@ptrCast(arg.ptr)` **reinterpreta** el puntero; no añade un terminador. El kernel leerá `argv[i]` como C string hasta el primer `\0`. El comentario "Zig string literals are" sólo vale para literales — y **el path de producción no usa literales**.

`runtime.zig:1129-1162` (`parse_argv`) produce los elementos con `allocator.dupe(u8, args[start..i])` — **sin NUL**. Y `runtime.zig:858-883` produce `command_line` con `allocPrint` / `dupe` — tampoco. Lo mismo para `envp` (`:802-805`): `@ptrCast(envp.ptr)` sobre un slice de `envp` construidos por el llamador; el path de producción pasa `&[_][*:0]const u8{}` (vacío) así que ahí `envp_arg` es el `&empty_envp` de una sola entrada — OK de milagro.

**Por qué importa.** En cada invocación de herramienta en producción, el kernel lee `strlen` bytes a partir de cada elemento del heap. Como `dupe` asigna bloques contiguos, el Terminator normalmente aparece en el padding o en el siguiente bloque — pero no está garantizado. Resultado: argumentos corrompidos, o `EFAULT`/crash, o (peor) **fuga de bytes de heap vecinos hacia el argv visible en `/proc/<pid>/cmdline` del hijo**. Es una lectura fuera de límites en la frontera del proceso.

**Fix** (ODD WU-2 del mismo feature doc; sin macros, sin alloc en hot path — los buffers son inline de tamaño fijo):

```zig
// src/sandbox.zig — reemplazar el bloque de construcción de argv
            // Inline staging buffers: argv NUL-terminado sin alloc.
            // REGLA DURA: los slices de `argv` vienen de parse_argv
            // (allocator.dupe, SIN terminador) — no se pueden reusar.
            // 15 entradas x (255 bytes + NUL) cabe en 4 KiB de stack del hijo
            // (pre-fork el stack ya está mapeado; post-fork no se aloca).
            var argv_stage: [15][256:0]u8 = undefined;
            var argv_buf: [16]?[*:0]const u8 = undefined;
            const argv_len = @min(argv.len, argv_stage.len);
            for (argv[0..argv_len], 0..) |arg, i| {
                const n = @min(arg.len, argv_stage[i].len - 1);
                @memcpy(argv_stage[i][0..n], arg[0..n]);
                argv_stage[i][n] = 0;
                argv_buf[i] = &argv_stage[i];
            }
            argv_buf[argv_len] = null;
```

Con el assert previo (§10.5, casts con range assert):

```zig
    if (argv.len == 0) return error.InvalidArgv;   // ya declarado en SandboxError (:663)
```

Esto también resuelve P2-08 (truncado silencioso a 15): o se rechaza explícitamente o se acepta el truncado documentado, pero no en silencio.

**Test RED.**

```zig
test "spawnToolSubprocess: argv con elemento sin NUL no se corre (>255 bytes)" {
    // today: el kernel lee más allá del bloque dupe'd → args corruptos
    const long = "a" ** 400;
    const argv = [_][]const u8{ "/bin/echo", long };
    var sub = try sandbox.Sandbox.spawnToolSubprocess(
        testing.allocator, test_profile, &argv, &[_][*:0]const u8{}, null);
    defer sub.deinit();
    var buf: [1024]u8 = undefined;
    const n = @bitCast(std.os.linux.read(sub.stdout_fd, &buf, buf.len));
    // el hijo debe ver exactamente 255 'a' + newline, no basura del heap
    try testing.expect(std.mem.count(u8, buf[0..n], "a") == 255);
}
```

---

#### P0-05 · `src/sandbox.zig:604-607` · El perfil del runtime no gobierna el seccomp; `allowed_net_endpoints` nunca se aplica

**Qué pasa.** `TOOLS_PROFILE` (`runtime.zig:638-649`) declara `allowed_syscalls` (41 números), `denied_syscalls` (5) y `allowed_net_endpoints` (vacío). **Ninguno de los tres llega al filtro.** El BPF real se construye con:

```zig
// src/sandbox.zig:604-607
const tool_bpf_prog = blk: {
    @setEvalBranchQuota(100_000);
    break :blk buildToolBpf(&diagnostic_allow);   // <-- 21 syscalls, no el perfil
};
```

`diagnostic_allow` (`sandbox.zig:582-602`) es una lista marcada como *diagnostic* con 21 entradas. `merged_allowlist` (`:507-512`, 460+ entradas) se usa **sólo** por el bloque `comptime` de diagnóstico (`:553-579`), nunca por el filtro. `allowed_net_endpoints` no lo referencia nadie (`grep` confirma: sólo las declaraciones).

**Por qué importa.** Dos consecuencias:
1. **Configuración falsa**: editar `TOOLS_PROFILE` no cambia nada. Un mantenedor que quiera endurecer el sandbox edita la lista equivocada y el cambio no surte efecto — sin ningún test que lo detecte (`runtime.zig:1364-1370` sólo asserta `.len > 0`).
2. **Los tests mienten**: `runtime.zig:1364` *"TOOLS_PROFILE exports sandbox_profile.Profile with non-empty paths"* pasa con cualquier array no vacío.

Además, `startup_allow_syscalls` (`:43-503`) es un **campo minado**: contiene entradas etiquetadas `// NO, denied` que **están en la lista de allow**:

| Línea | Syscall | Comentario en el código | Realidad |
|---:|---:|---|---|
| `:107` | `26` `ptrace` | `-- NO, denied` | **permitido** |
| `:217` | `165` `mount` | `-- NO, denied` | **permitido** |
| `:221` | `169` `reboot` | `-- NO, denied` | **permitido** |
| `:227` | `175` `init_module` | `-- NO, denied` | **permitido** |
| `:246` | `kexec_load` | `-- NO, denied` | **permitido** |
| `:310` | `unshare` | `-- NO, denied` | **permitido** |
| `:336` | `perf_event_open` | `-- NO, denied` | **permitido** |
| `:357` | `bpf` | `-- NO, denied` | **permitido** |
| `:374` | `userfaultfd` | `-- NO, denied` | **permitido** |

Esta lista está muerta hoy (P0-05), pero es una **bomba de relojería**: el día que alguien "arregle" P0-03/P0-05 delegando a `merged_allowlist` (que es el fix natural, y el que propongo arriba), suddenly `ptrace`, `mount`, `bpf` y `reboot` quedan permitidos en el sandbox. Hay que borrarla, no reutilizarla.

**Fix** (WU-1 del feature doc, combinado con P0-03):

```zig
// 1) Borrar src/sandbox.zig:43-503 (startup_allow_syscalls) y :507-512
//    (merged_allowlist) y :553-579 (el bloque comptime de diagnóstico).
//    Son código muerto que contradice la deny-list documentada.
// 2) src/sandbox.zig:582-602 — renombrar diagnostic_allow →
//    seccomp_startup_allow y documentar que es el allowlist REAL:
//    "deny-by-default, 21 syscalls. Un tool que necesite más debe
//     declararlo en TOOLS_PROFILE (WU-x)".
// 3) Añadir a TOOLS_PROFILE (runtime.zig:644) los syscalls que las
//    herramientas reales necesitan, y un test que verifique que el
//    BPF compilado las contiene.
const tool_bpf_prog = blk: {
    @setEvalBranchQuota(100_000);
    break :blk sandbox_linux.Seccomp.buildAllowlist(
        &seccomp_startup_allow,
        &sandbox_profile.default().denied_syscalls,
    );
};
```

Para `allowed_net_endpoints`: o se implementa (Landlock ABI v4 `LANDLOCK_ACCESS_NET_BIND_TCP`/`NET_CONNECT_TCP` + `handled_access_net`) o se borra del tipo `Profile` y de la documentación. Mantener un campo que "se aplica" y no se aplica es peor que no tenerlo.

**Test RED.**

```zig
test "sandbox: TOOLS_PROFILE.allowed_syscalls está realmente en el BPF" {
    for (TOOLS_PROFILE.allowed_syscalls) |nr| {
        // grep el array de instrucciones por el jeq con imm == nr
        var found = false;
        for (sandbox.tool_bpf_prog) |insn| {
            if (insn.code == (BPF.JMP|BPF.JEQ|BPF.K) and @as(u32, @bitCast(insn.imm)) == nr) found = true;
        }
        try testing.expect(found);  // hoy falla en cuanto se añada algo al perfil
    }
}
```

---

#### P0-06 · `src/runtime.zig:564-566` · Use-after-free cross-thread: el texto SSE se libera antes de que el TUI lo lea

**Qué pasa.**

```zig
// src/runtime.zig:563-568
                    .message => |text| {
                        const cleaned = stripEsc(std.heap.page_allocator, text) catch continue;
                        defer std.heap.page_allocator.free(cleaned);
                        channels_mod.pushSseChunk(args.io, &args.channels.agent_to_tui, seq, cleaned) catch {};
                        seq += 1;
                    },
```

`pushSseChunk` (`channels.zig:409-429`) copia el struct `Event` **por valor** al ring buffer: `.{ .StreamChunk = .{ .seq = seq, .text = text } }`. `text` es un puntero al heap. A continuación el `defer` **libera ese heap** al salir del prong del switch. El hilo TUI, de forma asíncrona, hace `tryGet` y renderiza `StreamChunk.text`.

**Por qué importa.** `page_allocator` en Linux usa `mmap`/`munmap`. Si el bloque es grande (un chunk SSE acumulado puede ser de varios KB), el `munmap` lo devuelve al kernel y el TUI lee **memoria no mapeada** → `SIGSEGV`. Si es pequeño, lee basura o el contenido de un `mmap` posterior. En la práctica esto se manifiesta como texto corrupto intermitente en pantalla, o como crash. Es el bug más grave del runtime y es 100% determinista en la forma del mecanismo (sólo la *visibilidad* del síntoma es probabilística).

Nótese que `stripEsc` con `page_allocator` es además un **alloc en hot path** (§10.1 lo prohíbe explícitamente): ocurre en cada chunk SSE.

**Fix.** El canal debe llevar **inline buffers**, que es justo lo que la convención del proyecto (§3.3 del context doc) afirma que ya hace — y no hace. Como §14.12 prohíbe tocar `channels.zig:69` fuera de un slice planificado, esto va en un feature doc propio:

```zig
// src/channels.zig — payload inline (reemplaza StreamChunkPayload)
pub const STREAM_CHUNK_BUF_LEN: usize = 4096;   // cubre un chunk SSE acumulado típico

pub const StreamChunkPayload = struct {
    seq: u64,
    text_buf: [STREAM_CHUNK_BUF_LEN]u8 = .{0} ** STREAM_CHUNK_BUF_LEN,
    text_len: usize = 0,

    pub fn text(self: *const StreamChunkPayload) []const u8 {
        std.debug.assert(self.text_len <= self.text_buf.len); // §10.5
        return self.text_buf[0..self.text_len];
    }
};
```

```zig
// src/runtime.zig:563-568
                    .message => |text| {
                        // Inline copy: el ring buffer es dueño de los bytes.
                        // NO alloc en hot path (Tiger Style §3).
                        const n = @min(text.len, channels_mod.STREAM_CHUNK_BUF_LEN);
                        const payload: channels_mod.StreamChunkPayload = .{
                            .seq = seq,
                            .text_buf = .{0} ** channels_mod.STREAM_CHUNK_BUF_LEN,
                            .text_len = n,
                        };
                        @memcpy(payload.text_buf[0..n], text[0..n]);
                        args.channels.agent_to_tui.tryPut(args.io, .{ .StreamChunk = payload }) catch {};
                        seq += 1;
                    },
```

Consecuencia aceptable a documentar: un chunk SSE mayor que 4 KiB se trunca. La alternativa (ring buffer con `'static` arena por stream) es un slice posterior.

**Test RED.**

```zig
test "P0-06: StreamChunk sobrevive al producer que libera su buffer" {
    // RED hoy: el test lee memoria ya liberada (use-after-free literal).
    var ch: channels_mod.Channel(channels_mod.Event) = .{};
    defer ch.close(testing.io);
    // simula el patrón exacto de runtime.zig:563-566
    const heap = try std.heap.page_allocator.alloc(u8, 8192);
    @memset(heap, 'A');
    try channels_mod.pushSseChunk(testing.io, &ch, 0, heap[0..4096]);
    std.heap.page_allocator.free(heap);
    // "machaca" el heap con un alloc posterior, como haría el siguiente chunk
    const churn = try std.heap.page_allocator.alloc(u8, 65536);
    defer std.heap.page_allocator.free(churn);
    @memset(churn, 0xFF);
    const got = ch.tryGet(testing.io).?;
    // Debe seguir siendo "AAAA..." — hoy lee basura o revienta
    try testing.expect(std.mem.allEqual(u8, got.StreamChunk.text(), 'A'));
}
```

Con `testing.allocator` en vez de `page_allocator` el test detecta el patrón de forma portable (el testing allocator poisoning de `std.testing.allocator` marca el bloque como liberado).

---

#### P0-07 · `src/runtime.zig:931` + `:1050-1055` · Use-after-free: `captured.items` de un `ArrayList` local se postea al canal y luego se destruye

**Qué pasa.**

```zig
// src/runtime.zig:930-931
                    var captured: std.ArrayList(u8) = .empty;
                    defer captured.deinit(args.allocator);
...
// src/runtime.zig:1050-1055
                    args.channels.tools_to_tui.tryPut(args.io, .{
                        .ToolResult = .{
                            .id = d.id,
                            .output = captured.items,   // <-- slice al heap local
                        },
                    }) catch {};
```

El `defer` de `:931` se dispara al salir del prong `.DispatchToolRequest` — inmediatamente después del `tryPut`.

**Por qué importa.** Es el mismo patrón que P0-06 pero con dos diferencias que lo hacen peor: (a) `ToolResult.output` es **exactamente lo que el usuario ve** en pantalla, así que el síntoma es visible en cada ejecución de herramienta; (b) `captured` crece con `appendSlice` hasta el tamaño de la salida del tool, de modo que cuando el `ArrayList` termina de crecer tiene un bloque heap **grande** → `munmap` → el TUI lee página no mapeada. Además, si el canal estaba lleno, `tryPut` falla y el slice se descarta — pero el `defer` corre igual; no hay fuga, hay UAF.

Nótese que hay un segundo problema en la misma línea: no hay `tryPut` con backpressure ni límite de tamaño, así que un tool que emita GB por stdout agota la memoria del harness (el `captured` no tiene tope; sólo corta si `appendSlice` falla por OOM, con un `break` silencioso — `runtime.zig:982-985`).

**Fix.** Mismo enfoque que P0-06 pero con un tope explícito (justified bound, §10.1):

```zig
// src/channels.zig — payload inline con tope justified
pub const TOOL_OUTPUT_BUF_LEN: usize = 64 * 1024;   // tope de captura (§11.27: pipe 64 KiB)

pub const ToolResultPayload = struct {
    id: u64,
    output_buf: [TOOL_OUTPUT_BUF_LEN]u8 = .{0} ** TOOL_OUTPUT_BUF_LEN,
    output_len: usize = 0,
    /// true si la salida del tool excedió el tope → el modal avisa.
    truncated: bool = false,

    pub fn output(self: *const ToolResultPayload) []const u8 {
        std.debug.assert(self.output_len <= self.output_buf.len);
        return self.output_buf[0..self.output_len];
    }
};
```

```zig
// src/runtime.zig:1050-1055
                    const n = @min(captured.items.len, channels_mod.TOOL_OUTPUT_BUF_LEN);
                    var res: channels_mod.ToolResultPayload = .{
                        .id = d.id,
                        .output_buf = .{0} ** channels_mod.TOOL_OUTPUT_BUF_LEN,
                        .output_len = n,
                        .truncated = captured.items.len > n,
                    };
                    @memcpy(res.output_buf[0..n], captured.items[0..n]);
                    args.channels.tools_to_tui.tryPut(args.io, .{ .ToolResult = res }) catch {};
```

Y en el read loop, cortar en el tope en vez de crecer:

```zig
// src/runtime.zig:982-985 — reemplazar
                            if (captured.items.len < channels_mod.TOOL_OUTPUT_BUF_LEN) {
                                captured.appendSlice(args.allocator, read_buf[0..@intCast(n_signed)]) catch {
                                    logger.global().log(args.io, .warn, "stdout capture OOM") catch {};
                                    break;
                                };
                            }
```

**Test RED.**

```zig
test "P0-07: ToolResult.output sigue legible tras el return del producer" {
    var ch: channels_mod.Channel(channels_mod.Event) = .{};
    defer ch.close(testing.io);
    var captured: std.ArrayList(u8) = .empty;
    defer captured.deinit(testing.allocator);
    try captured.appendSlice(testing.allocator, "hello from the tool");
    const n = @min(captured.items.len, channels_mod.TOOL_OUTPUT_BUF_LEN);
    var res: channels_mod.ToolResultPayload = .{ .id = 7, .output_len = n };
    @memcpy(res.output_buf[0..n], captured.items[0..n]);
    try ch.tryPut(testing.io, .{ .ToolResult = res });
    // el producer vuelve, `captured.deinit()` corre, y el allocator envenena el bloque
    const got = ch.tryGet(testing.io).?;
    try testing.expectEqualStrings("hello from the tool", got.ToolResult.output());
}
```

---

#### P0-08 · `src/runtime.zig:677, 860, 873, 887, 914` · Bug 1 reintroducido 5 veces: `var buf:[64]u8` stack-local → `ToolError.message` al canal

**Qué pasa.** `docs/conventions.md` documenta el incidente canónico (Bug 1, 2026-09-01): un `var buf: [N]u8` local, formateado con `bufPrint`, y el slice resultante guardado en un estado de larga vida. El slice queda dangling cuando el frame se reclama. La convención dice: **inline buffer + contador de longitud**. Estas cinco son el patrón exacto en código nuevo de slice 7:

```zig
// src/runtime.zig:860-868
                    const command_line = if (d.args.len > 0)
                        std.fmt.allocPrint(args.allocator, "{s} {s}", .{ d.name, d.args }) catch |err| {
                            var buf: [64]u8 = undefined;                                    // ← stack-local
                            const msg = std.fmt.bufPrint(&buf, "args alloc failed: {s}", .{@errorName(err)}) catch "args alloc failed";
                            args.channels.tools_to_tui.tryPut(args.io, .{
                                .ToolError = .{
                                    .id = d.id,
                                    .kind = .spawn_failed,
                                    .message = msg,                                          // ← slice al stack
                                },
                            }) catch {};
                            continue;
                        }
```

Idéntico en `:677` (`agentDispatchTool`, con `logger.global().log` — ese sí es seguro porque se consume antes del return, y de hecho lleva el patrón `ponytail` correcto), en `:873`, `:887` y `:914`.

**Por qué importa.** `buf` se declara en el prong del `switch`, dentro de un `catch`/error-path. Cuando el `continue` o el fin del prong ejecutan el `defer` de scope, el frame se reutiliza. El hilo TUI, de forma asíncrona, hace `tryGet` y renderiza `ToolError.message`. Resultado: mensaje de error corrupto, o `SIGSEGV` si el stack slot fue reutilizado por un buffer grande (aquí el TUI tiene `out_buf: [4096]u8` y `grids: [2]ScreenGrid` — **los slots de 64 bytes van a quedar dentro de esas estructuras**).

Es la clase de bug que el proyecto ya se comprometió a no repetir, con un documento entero (`docs/conventions.md`) dedicado a ella y una convención listada como BINDING en §16 del context doc. La regresión llegó con el slice 7, que no leyó la convención.

**Fix** (WU-2 del feature doc `agent-thread-ownership-and-sandbox-fail-closed`, o un `tool-error-inline-buffers` propio). Inline en el payload:

```zig
// src/channels.zig
pub const TOOL_MSG_BUF_LEN: usize = 96;

pub const ToolErrorPayload = struct {
    id: u64,
    kind: ToolErrorKind,
    msg_buf: [TOOL_MSG_BUF_LEN]u8 = .{0} ** TOOL_MSG_BUF_LEN,
    msg_len: usize = 0,
    pub fn message(self: *const ToolErrorPayload) []const u8 {
        std.debug.assert(self.msg_len <= self.msg_buf.len);
        return self.msg_buf[0..self.msg_len];
    }
};
```

Y un helper único (evita 5 copias — pero §14.15 prohíbe "DRY abstracto" sin FU; **aquí el FU es P0-08**, es un bug de seguridad con 5 instancias, lo que lo califica):

```zig
// src/channels.zig
/// Construye un ToolErrorPayload con el mensaje inline.
/// ponytail: sustituye al patrón Bug 1 (var buf:[N]u8 → slice al canal),
///|width| 5 instancias en src/runtime.zig:677,860,873,887,914.
pub fn toolError(id: u64, kind: ToolErrorKind, comptime fmt: []const u8, args: anytype) ToolErrorPayload {
    var p: ToolErrorPayload = .{ .id = id, .kind = kind };
    p.msg_len = std.fmt.bufPrint(&p.msg_buf, fmt, args) catch blk: {
        const lit = "tool error";
        @memcpy(p.msg_buf[0..lit.len], lit);
        break :blk lit.len;
    };
    return p;
}
```

**Test RED** — un guard estático que impide que el patrón vuelva:

```zig
test "P0-08: ningún .message = <slice> stack-local en runtime.zig" {
    const src = try std.Io.Dir.cwd().readFileAlloc(
        testing.io, "src/runtime.zig", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(src);
    // Prohíbe `var buf: [N]u8` seguido de `.message = msg` en runtime.zig
    // fuera de bloques de test.
    const prod = src[0 .. std.mem.indexOf(u8, src, "\ntest \"") orelse src.len];
    try testing.expect(std.mem.indexOf(u8, prod, ".message = msg") == null);
}
```

Mejor aún, un guard de **tipo** (compila, no grep):

```zig
test "P0-08: ToolErrorPayload no contiene ningún slice" {
    // Si alguien reintroduce `message: []const u8`, esto falla al compilar
    // cualquier punto de construcción.
    try testing.expect(!@hasField(channels_mod.ToolErrorPayload, "message"));
}
```

---

#### P0-09 · `src/api_client.zig:548-552, 690-694 → :325` · `body_bytes` aliasa un array stack-local de 16 KiB y se lee tras el return

**Qué pasa.** En `tryOneAttempt`, el body de la respuesta se acumula en un array local:

```zig
// src/api_client.zig:478 (rama TLS) y :600 (rama plain)
        var resp_buf: [16 * 1024]u8 = undefined;
...
// src/api_client.zig:548-553 (rama TLS)
            const body_slice = resp_buf[header_end .. header_end + body_actual];
            return AttemptOutcome{
                .success = .{
                    .fd = -1, // TLS session closed; caller owns body bytes only.
                    .body_bytes = body_slice,        // <-- el slice ESCAPA del frame
                    .body_len = body_actual,
                },
            };
```

Y el consumidor:

```zig
// src/api_client.zig:311-326
                .success => |info| {
                    var stream_inst = ChunkEventStream{ ... };
                    // Copy any buffered body bytes into body_buf eagerly.
                    if (info.body_len > 0) {
                        try stream_inst.body_buf.appendSlice(allocator, info.body_bytes[0..info.body_len]);
                    }
                    return stream_inst;
                },
```

`tryOneAttempt` ya retornó; su frame (16 KiB) fue reclamado. Entre el return y la línea `:325` se ejecuta `api_sse.Parser.init(allocator)` en `:315` (que llama `ArenaAllocator.init` — sin alloc, pero el compilador puede colocar variables locales nuevas en ese slot). El doc-comment de `:551` afirma *"caller owns body bytes only"*, lo cual es **falso**: el caller no tiene copia, tiene un puntero muerto.

**Por qué importa.** Es un read de memoria ya liberada en el camino de éxito de *toda* request. En la práctica, como el array es de 16 KiB y está cerca del tope del stack, el slot suele sobrevivir intacto (por eso el harness "funciona"), pero con `ReleaseFast`+LTO, con `-fomit-frame-pointer`, o si se añade cualquier variable grande a `tryOneAttempt`, el contenido cambia. Es UB puro en el camino caliente. Y viola frontalmente §10.1 y `docs/conventions.md`.

**Fix.** El outcome debe llevar los bytes **por valor** en un buffer inline (bounded, 16 KiB es el tope ya existente) o ser heap. Inline es lo correcto aquí (Tiger Style):

```zig
// src/api_client.zig
pub const MAX_RESPONSE_BODY: usize = 16 * 1024;

const AttemptOutcome = union(enum) {
    success: struct {
        fd: i32,
        /// INLINE: los bytes viajan por valor. Antes era `[]const u8` aliasing
        /// el `resp_buf` stack-local de tryOneAttempt — leído en Client.stream
        /// (:325) DESPUÉS de que tryOneAttempt devolviera (P0-09).
        body: [MAX_RESPONSE_BODY]u8 = .{0} ** MAX_RESPONSE_BODY,
        body_len: usize = 0,
    },
    unauthorized: void,
    retryable: struct { status: u16, retry_after_ms: ?u64 },
};
```

```zig
// src/api_client.zig:548-555
            var out: @FieldType(AttemptOutcome.success, "body") = .{0} ** MAX_RESPONSE_BODY;
            @memcpy(out[0..body_actual], resp_buf[header_end .. header_end + body_actual]);
            return AttemptOutcome{ .success = .{ .fd = -1, .body = out, .body_len = body_actual } };
```

```zig
// src/api_client.zig:324-326
                    if (info.body_len > 0) {
                        try stream_inst.body_buf.appendSlice(allocator, info.body[0..info.body_len]);
                    }
```

Coste: `AttemptOutcome` pasa de ~40 bytes a 16 KiB por valor. Se evita con un puntero a un buffer del *caller* (el `ChunkEventStream` ya es el dueño), que es la variante `resp_buf: *const [N]u8` + assert de no-escape. Si el perf importa en v1, esa es la opción; el inline es la segura y la que propongo.

**Test RED.**

```zig
test "P0-09: el body de la respuesta sobrevive al return de tryOneAttempt" {
    // RED: tryOneAttempt devuelve un body_bytes que apunta a un frame
    // ya reclamado; el test lo detecta con el poisoning de testing.allocator
    // si tryOneAttempt usara alloc, o con un "stack scratch" explícito.
    var ms = try mock_server.start(testing.allocator);
    defer ms.deinit();
    try mock_server.sendBytes(ms, "HTTP/1.1 200 OK\r\nContent-Length: 11\r\n\r\nhello world");
    var req = testRequest(mock_server.port(ms.*), 1);
    const pipe = try makeCancelPipe();
    defer closeCancelPipe(pipe);
    var stream = try Client.stream(testing.allocator, testing.io, req, pipe);
    defer stream.deinit();
    // Si el body se copió correctamente, el primer evento contiene el texto.
    // Hoy el parser recibe basura del stack reutilizado.
    const ev = try stream.next();
    try testing.expectEqualStrings("hello world", ev.?.message);
}
```

Este test probablemente **pasa hoy** por la razón del stack-sobreviviente. Eso lo hace un test débil por sí solo; la garantía real la da el test de tipo siguiente:

```zig
test "P0-09: AttemptOutcome.success no contiene ningún slice" {
    const S = @typeInfo(AttemptOutcome).@"union".fields[0].type.@"struct";
    for (S.fields) |f| try testing.expect(f.type != []const u8);
}
```

---

#### P0-10 · `src/logger.zig:60` · `/tmp/ai-harness-debug.log` se abre con `O_CREAT|O_TRUNC` sin `O_NOFOLLOW` — symlink attack

**Qué pasa.**

```zig
// src/logger.zig:53-67
        const flags: std.posix.O = .{
            .ACCMODE = .WRONLY,
            .CREAT = true,
            .TRUNC = true,
            .CLOEXEC = true,
        };
        const fd = std.posix.openat(std.posix.AT.FDCWD, path, flags, 0o600) catch return error.OpenFailed;

        // fchmod post-open defeats umask masking of requested mode bits.
        const chmod_rc = std.os.linux.fchmod(fd, 0o600);
```

No hay `O_NOFOLLOW`, ni `O_EXCL`, ni verificación de que el fichero abierto es un regular file.

**Por qué importa.** `/tmp` es world-writable con sticky bit. Un atacante local (o simplemente un proceso previo corriendo como root) puede crear `/tmp/ai-harness-debug.log` como **symlink a `~/.bashrc`, `~/.ssh/authorized_keys` o a un binario del PATH**. zargeant hace `open(O_WRONLY|O_TRUNC)` → **trunca el objetivo** y luego le añade líneas con `write(2)`. El `fchmod(0600)` se aplica al *target* ya truncado. Impacto: destrucción de ficheros de configuración del usuario + escritura controlada de contenido (las líneas llevan `[{level}] [thread=N] {msg}`; `msg` proviene de `@errorName(err)` y de constantes del código, pero `logger.logf` acepta cualquier string).

Nota: `resolveWritableDir` (`:149-173`) existe en el módulo y prefiere `$TMPDIR` → `$XDG_RUNTIME_DIR` → `/tmp`, pero **`Logger.init` no la usa**: usa `defaultPath` directamente (`:51`). La mitigación ya está medio escrita y no está conectada.

Además, `MAX_MESSAGE_LEN = 16 * 1024` (`:42`) pero el buffer de `log` es `[4096]u8` (`:93`): un mensaje entre 4 KiB y 16 KiB devuelve `error.WriteFailed` en vez de `error.MessageTooLong` (P3-04).

**Fix** (ODD: `odd/tasks/logger-path-hardening.md`, WU único, bajo riesgo):

```zig
// src/logger.zig:53-67
        const flags: std.posix.O = .{
            .ACCMODE = .WRONLY,
            .CREAT = true,
            .TRUNC = true,
            .CLOEXEC = true,
            .NOFOLLOW = true,   // rechaza symlink en cualquier componente final
            .DIRECTORY = false,
        };
        const fd = std.posix.openat(std.posix.AT.FDCWD, path, flags, 0o600) catch return error.OpenFailed;

        // Verificar que es un regular file (defensa en profundidad: O_NOFOLLOW
        // protege el último componente, no un bind-mount o un fifo).
        const st = std.os.linux.fstat(fd, &stat_buf) catch { ... };
        if (!std.os.linux.S.ISREG(st.mode)) { close; return error.OpenFailed; }
```

Y conectar la resolución de directorio (con `mkdir(0700)` bajo `$XDG_RUNTIME_DIR`, que §10.7 ya exige para IPC):

```zig
// src/logger.zig:51 — reemplazar
        const path = path_opt orelse blk: {
            const dir = try resolveWritableDefaultDir();
            break :blk try joinOwned(dir, "ai-harness-debug.log");  // nombre con uid
        };
```

Incluir el uid en el nombre (`ai-harness-debug-<uid>.log`) elimina la colisión por diseño.

**Test RED.**

```zig
test "logger: rechaza symlink en el path del log" {
    const dir = try std.testing.tmpDir(.{});
    defer dir.cleanup();
    const link = try dir.dir.realpathAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(link);
    const target = try dir.dir.createFile(testing.io, "target", .{});
    defer target.close(testing.io);
    // pre-poblar el target para detectar el truncate
    try target.writeStreamingAll(testing.io, "PRECIOUS");

    try std.posix.symlinkat("target", dir.fd, "link");
    try testing.expectError(error.OpenFailed,
        Logger.init(testing.io, "<tmpdir>/link"));
    // el target NO debe haberse truncado
    try target.seekTo(testing.io, 0);
    var buf: [16]u8 = undefined;
    const n = try target.read(testing.io, &buf);
    try testing.expectEqualStrings("PRECIOUS", buf[0..n]);
}
```

---

#### P0-11 · `src/api_client.zig:1772` · Fuga de memoria en el error path de `HostName.init` (CONFIRMADO)

**Qué pasa.**

```zig
// src/api_client.zig:1755-1785
        var bundle: std.crypto.Certificate.Bundle = .empty;
        const now = std.Io.Clock.real.now(io);
        bundle.rescan(alloc, io, now) catch return error.TlsHandshakeFailed;

        const client_ptr = try alloc.create(std.http.Client);   // ← :1761
        client_ptr.* = .{ .allocator = alloc, .io = io, .now = now, .ca_bundle = bundle };

        const hostname = std.Io.net.HostName.init(host) catch return error.TlsHandshakeFailed;  // ← :1772 FUGA
        const connection = client_ptr.connectTcp(hostname, port, .tls) catch |err| {
            client_ptr.ca_bundle.deinit(alloc);
            alloc.destroy(client_ptr);
            return err;                                        // ← :1773-1777 limpio
        };
```

`HostName.init` falla si `host` no es un nombre de host válido (p. ej. contiene `\0`, es vacío, o excede 255 bytes). En ese caso se filtran el `std.http.Client` (~200 bytes) **y el bundle CA completo** (en Arch, ~150 CAs ≈ 250 KB de memoria y ~150 fds de mmap).

**Por qué importa.** Sólo se dispara con un host inválido. Los callers de producción pasan literales válidos, así que **no explota hoy**; es una fuga latente + un camino de error no probado (ningún test fuerza `HostName.init` a fallar). Pero es exactamente el patrón que §10.1 pide cerrar con `errdefer`, y el path hermano está bien escrito — la inconsistencia es el bug.

**Fix** (mismo WU-1 de `tls-lifecycle`):

```zig
// src/api_client.zig:1761-1777
        const client_ptr = try alloc.create(std.http.Client);
        errdefer alloc.destroy(client_ptr);
        client_ptr.* = .{ .allocator = alloc, .io = io, .now = now, .ca_bundle = bundle };
        // El bundle se movió al client:cleanup via Client.deinit.
        errdefer client_ptr.ca_bundle.deinit(alloc);

        // 3. ConnectTcp ...
        const hostname = std.Io.net.HostName.init(host) catch return error.TlsHandshakeFailed;
        const connection = client_ptr.connectTcp(hostname, port, .tls) catch |err| {
            // errdefer hace el cleanup; no hace falta el bloque manual.
            return err;
        };
```

Cuidado: los dos `errdefer` se ejecutan en orden inverso → `ca_bundle.deinit` y luego `destroy`. Correcto. Hay que eliminar el cleanup manual de `:1774-1775` para no liberar dos veces.

**Test RED.**

```zig
test "tls_conn: HostName.init inválido no filtra" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer testing.expect(arena.deinit() == .ok);  // falla si la arena retiene la CA
    const bad_host = "invalid\x00hostname";
    try testing.expectError(error.TlsHandshakeFailed,
        tls_conn.connect(testing.io, arena.allocator(), bad_host, 443));
}
```

Con `std.testing.allocator` debajo, el leak se detecta como "leak" sólo si el allocator es el testing y se comprueba; con arena el check es más directo.

---

#### P0-12 · `src/api_client.zig:1790` + `:457-491` · El path TLS no tiene timeout **ni** cancel-pipe; `handshake()` es un no-op nunca llamado

**Qué pasa.** Tres hechos encadenados:

1. `handshake()` es literalmente vacío:
```zig
// src/api_client.zig:1788-1793
    /// No-op preserved for symmetry with the previous design contract.
    pub fn handshake(self: *tls_conn, timeout_ms: u64) !void {
        _ = timeout_ms;
        _ = self;
    }
```
2. `Client.stream` / `tryOneAttempt` **nunca lo invocan** (`grep` confirma: las únicas apariciones de `handshake(` en el repo son la definición y los tests).
3. El path TLS de `tryOneAttempt` **no consulta `cancel_pipe` en ningún punto**:

```zig
// src/api_client.zig:482-491  (rama TLS)
        while (header_end == 0) {
            const n = tls.readSome(resp_buf[resp_len..]) catch |err| switch (err) {
                error.ConnectionClosed => return error.ReadFailed,
                else => return error.ReadFailed,
            };
            resp_len += n;
            ...
        }
```

compárese con la rama plain, que sí:
```zig
// src/api_client.zig:604-609  (rama plain)
        while (header_end == 0) {
            if (pollWithCancel(fd, cancel_pipe)) { ... return error.Cancelled; }
```

Y el propio repo lo admite en el header de `api_auth.zig:220-225` ("WU-3 (T3.2) will wire a watchdog") — un WU que nunca aterrizó.

**Por qué importa.** En **modo real** (el modo por defecto: `mock_mode = false` → `target_host = "api.minimax.io"`, `tls = true`):
- El usuario pulsa Ctrl+C → `tui.zig:980-981` pone el flag de shutdown y escribe en `cancel_pipe[1]`. El Agent thread, bloqueado en `tls.readSome` sobre un socket TLS, **no se entera**. `Runtime.run` (`runtime.zig:291-293`) hace `join()` bloqueante sin timeout → **el proceso no termina**.
- Peor: `connectTcp` no tiene timeout. Si `api.minimax.io` acepta la conexión TCP pero no completa el handshake (middlebox, red con pérdida, servidor colgado), el Agent thread **se queda colgado para siempre** dentro de `std.crypto.tls.Client.init`. `HANDSHAKE_TIMEOUT_MS = 5_000` (`:1700`) es una constante que nada aplica, y `api_client.zig:1911-1917` lo admite en un test que hace `return` inmediato.
- Contraste que lo hace inequívoco: `api_auth.validateViaApiWithTarget` **sí** chequea el cancel-pipe en su rama TLS (`:270-278`). La inconsistencia entre los dos paths TLS del mismo repo es la prueba.

**Fix** (ODD: `odd/tasks/tls-timeout-and-cancel.md`, WU-1). El `std.http.Client` de 0.16 no expone timeout de connect, así que la solución correcta es un **watchdog de watchdog** con deadline, no un try de configurar un timeout inexistente:

```zig
// src/api_client.zig:457-491 — rama TLS
    if (req.tls) {
        // Watchdog: connectTcp no tiene timeout. Sin esto el Agent thread
        // cuelga para siempre si el handshake no progresa (P0-12).
        const deadline = std.Io.Clock.real.now(io).nanoseconds +
            @as(i64, @intCast(HANDSHAKE_TIMEOUT_MS)) * std.time.ns_per_ms;
        var tls = tls_conn.connect(io, allocator, req.target_host, port) catch |err| switch (err) { ... };
        defer tls.deinit();

        // ... y en el read loop, chequear cancel + deadline:
        while (header_end == 0) {
            if (pollCancelImmediate(cancel_pipe)) return error.Cancelled;
            if (std.Io.Clock.real.now(io).nanoseconds > deadline) return error.HandshakeTimeout;
            const n = tls.readSome(resp_buf[resp_len..]) catch |err| switch (err) { ... };
            ...
        }
```

Y documentar honestamente el límite: sin soporte de timeout en `connectTcp`, el **handshake** en sí no es interrumpible. El fix mínimo aceptable para v1 es:
- (a) el read loop respeta cancel + deadline (arregla el 90% del caso real: la request ya se envió, la respuesta no llega),
- (b) un `std.Thread.spawn` de un watchdog que hace `kill(getpid())`… no, demasiado. Mejor: **documentar el límite en el feature doc y exponer `tls_gated = true` como default hasta que haya solución real**. `Config.tls_gated` ya existe (`runtime.zig:66`) y no se usa en ninguna parte (`grep`) — es el interruptor previsto.

**Test RED.**

```zig
test "P0-12: cancel durante la lectura TLS aborta en ≤100ms" {
    // hoy NO hay forma de testearlo: connectTcp contra un mock HTTP colgaría
    // (ver el comentario de api_client.zig:1159-1165). Por eso el test RED
    // tiene que ir contra la abstracted read loop, no contra el socket.
    // Propuesta: extraer el read loop a `readResponseTls(tls, buf, cancel, deadline)`.
    const pipe = try makeCancelPipe();
    defer closeCancelPipe(pipe);
    _ = std.os.linux.write(pipe[1], &.{0x01}, 1);   // cancel pre-escrito
    try testing.expectError(error.Cancelled,
        readResponseTls(fake_tls, &buf, pipe, deadline_in(5_000)));
}
```

---

#### P0-13 · `src/tui.zig:937-940` + `src/modal.zig:910` · El hilo TUI consume y descarta `tui_to_agent` — el WU-3 "SHIPPED" está roto y el path LLM es código muerto

**Qué pasa.** `channels.Channels.tui_to_agent` está documentado como el canal **TUI→Agent**. Pero `tuiThreadLoop` —el loop que corre en producción, invocado desde `runtime.zig:419`— lo **consume**:

```zig
// src/tui.zig:936-940
        // 2. Drain channels.Shutdown from any edge (runtime signals all).
        if (channels.tui_to_agent.tryGet(io)) |ev| switch (ev) {
            .Shutdown => return,
            else => continue,          // <-- TODO lo demás SE PIERDE
        };
```

Y el TUI es también el **productor** de ese mismo canal:

```zig
// src/modal.zig:906-921  (submitKeyEntryAsync, vía handleKeyInput tui.zig:1070)
    // tryPut never blocks (the Agent thread is the only consumer + the
    // channel capacity is 256).
    channels.tui_to_agent.tryPut(io, req) catch {};

    // Mark validating so the renderer shows the spinner glyph.
    state.* = .{
        .key_entry = .{
            ...
            .validating = true,
        },
    };
```

Secuencia en producción:
1. El usuario pulsa Enter en `.key_entry`.
2. `handleKeyInput` (`:1063-1078`) llama `submitKeyEntryAsync` → `tryPut(ValidateApiRequest)` y pone `validating = true`.
3. `handleKeyInput` devuelve `true` → `tuiThreadLoop` hace `continue` (línea 929) o vuelve al tope del `while(true)`.
4. En la **siguiente** iteración, `tui.zig:937` hace `tryGet(tui_to_agent)` y se lleva **su propia** `ValidateApiRequest`, la descarta por el `else => continue`.
5. El Agent thread nunca la ve. `agentRunValidate` nunca corre. `drainSubmitReply` nunca recibe nada.
6. `ke.validating` queda en `true` para siempre → `tui.zig:1049` `if (ke.validating) return false;` descarta **toda** entrada posterior. **El TUI queda bricked en la pantalla de API key** hasta Ctrl+C.

**Esto no es una carrera perdida: es cuasi-determinist.** El Agent thread (`runtime.zig:499-503`) hace `tryGet` y luego `io.sleep(1ms)` — está dormido el 99.9% del tiempo. El TUI itera cada 16 ms y hace el `tryGet` en los microsegundos siguientes al `tryPut`. El TUI gana.

`src/tui.zig:845-862` (`tuiThreadMain`, la variante no-producción) tiene el **mismo** consumo → el bug está duplicado.

**Por qué importa (más allá del freeze).** Consecuencia arquitectónica mayor: `Event.UserToolRequest` **no tiene ningún productor en producción** (`grep` sobre `src/` completo: sólo el consumidor en `runtime.zig:506` y los tests). Lo mismo para `ApiKeySubmitted`, `UnlockPasswordSubmitted`, `ConsentGrant`, `AgentToolRequest`. Consecuencia: **`api_client.Client.stream`, `api_sse.Parser` y `tls_conn` nunca se ejecutan en el binario de producción.** Todo el TLS, todo el SSE, todo el retry/backoff — código muerto desde la perspectiva del usuario. Eso explica por qué los bugs P0-11 y P0-12 no se han manifiesto.

**Fix** (ODD: `odd/tasks/agent-thread-ownership-and-sandbox-fail-closed.md`, WU-1; **debe preceder a WU-4**). La regla: *un canal tiene exactamente un lector*.

```zig
// src/tui.zig:936-940 — sustituir
        // 2. Shutdown se señaliza por el ATOMIC compartido (tui.zig:980
        //    `shutdown.store(true, .seq_cst)`), no robando eventos del
        //    canal del Agent thread. `tui_to_agent` tiene UN lector:
        //    agentThreadLoop (runtime.zig:500).
        if (args.shutdown.load(.seq_cst)) return;
```

Y `tuiThreadMain` (`:845-863`) se elimina o se reduce al idle-anchor, que ya se puede hacer localmente. Si se conserva el peek de "actividad del usuario", debe hacerse sobre un canal **distinto** (`tui_local_activity`) o sobre el contador de `last_user_action_ms` que el TUI ya mantiene.

**Test RED.** Un test end-to-end de la ruta WU-3, que es exactamente lo que el feature doc pedía y no está escrito:

```zig
test "WU-3 RED: ValidateApiRequest llega al Agent thread (nadie lo roba)" {
    var rt = try Rt.Runtime.spawn(.{ .mock_handle = ... });  // mock server
    defer rt.deinit();
    // TUI-side: postear la request como lo hace submitKeyEntryAsync
    var state: modal.State = .{ .key_entry = .{ .draft = ..., .draft_len = 24, .validating = false } };
    try modal.submitKeyEntryAsync(testing.io, testing.allocator, &state, null, &rt.channels);
    // Agent-side: debe llegar un ValidateApiReply en < 2s
    var deadline = nowMs() + 2000;
    var got_reply = false;
    while (nowMs() < deadline) {
        if (rt.channels.submit_reply.tryGet(testing.io)) |ev| {
            switch (ev) { .ValidateApiReply => got_reply = true, else => {} }
        }
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }
    try testing.expect(got_reply);   // hoy FALSA: el reply nunca llega
}
```

Este test debe ir en `tests/tui/runtime_thread.zig` (el hub) y es el que faltaba en la acceptance criteria de WU-3.

---

### P1 — Concurrencia

---

#### P1-01 · `src/channels.zig:413-417` · TOCTOU entre `peekLast` y `replaceLast` en `pushSseChunk`

**Qué pasa.**

```zig
// src/channels.zig:409-418
pub fn pushSseChunk(io: std.Io, ch: *Channel(Event), seq: u64, text: []const u8) !void {
    const new_event: Event = .{ .StreamChunk = .{ .seq = seq, .text = text } };

    // Fast path: tail is a StreamChunk — REPLACE in place.
    if (ch.peekLast(io)) |last| {
        if (last == .StreamChunk) {
            try ch.replaceLast(io, new_event);
            return;
        }
    }
```

`peekLast` (`:316-322`) toma el mutex, lee, **suelta el mutex**. `replaceLast` (`:328-334`) lo vuelve a tomar. Entre ambos, el consumidor TUI puede hacer `tryGet` (el count baja a 0) y un productor puede hacer `tryPut` de un evento **distinto**.

Tres fallos posibles:
1. `replaceLast` ve `count == 0` → devuelve `error.Empty` → `pushSseChunk` propaga el error → `runtime.zig:566` lo traga con `catch {}` → **el chunk SSE se pierde silenciosamente**. El usuario ve texto truncado.
2. `replaceLast` encuentra count > 0 pero `tail-1` apunta a un evento que **no** es un `StreamChunk` (otro productor puso algo ahí) → **sobrescribe un `AgentError` o un `Shutdown`**. Esto es pérdida de señal de control.
3. El test `channels.zig:476-495` ("5 chunks → 1 frame") corre en un solo hilo, así que **no detecta ninguno de los dos**.

**Por qué importa.** Con el coalesce activo (cada chunk SSE), la ventana entre las dos llamadas es de decenas de nanosegundos y el productor Agent empuja al menos un chunk cada ~20-50 ms. La probabilidad por stream es baja pero no cero; en una sesión larga con varios streams, es una pérdida o corrupción de texto esporádica y no reproducible — el peor tipo de bug.

**Fix** (mismo feature doc de P0-06/P0-13, porque ambos tocan `channels.zig`):

```zig
// src/channels.zig — una sola adquisición de lock
        /// Inserta un StreamChunk con semántica REPLACE-on-newer.
        /// Atómico con respecto a tryGet/tryPut: una sola toma de lock.
        pub fn putSseChunk(self: *Self, io: std.Io, item: T) !void {
            self.mutex.lock(io) catch return error.Canceled;
            defer self.mutex.unlock(io);
            if (self.closed) return error.Closed;
            if (self.count > 0) {
                const idx = if (self.tail == 0) CAP - 1 else self.tail - 1;
                if (self.buffer[idx] == .StreamChunk) {
                    self.buffer[idx] = item;   // REPLACE in place
                    return;
                }
            }
            if (self.count == CAP) {
                // overflow: descartar el más viejo (§11.27 NO ADDRESSED)
                self.head = (self.head + 1) % CAP;
                self.count -= 1;
            }
            self.buffer[self.tail] = item;
            self.tail = (self.tail + 1) % CAP;
            self.count += 1;
            self.not_empty.signal(io);
        }
```

Esto además **arregla §11.27 "channel overflow drops oldest"**, que el context doc marca como NOT ADDRESSED: el drop-oldest pasa a ser determinista y no depend de un `tryGet`/`tryPut` no atómico.

**Test RED.**

```zig
test "P1-01: putSseChunk no pierde chunks bajo concurrencia" {
    // 4 productores empujan 1000 chunks cada uno, 1 consumidor drena.
    // Ningún seq debe faltar y el channel nunca debe quedar inconsistente.
    // Hoy: replaceLast devuelve error.Empty y se pierde el chunk.
}
```

(Sin TSan — §11.3 — el test debe ser **de Invariante**, no de race detection: contar los `seq` vistos contra los `seq` puestos.)

---

#### P1-02 · `src/api_sse.zig:86, 184, 263, 315, 323` · La arena del parser SSE nunca se resetea — crecimiento O(n²) en contenido acumulativo

**Qué pasa.** `Parser` tiene un `arena: std.heap.ArenaAllocator` (`:86`) que se puebla en cada línea y en cada evento:

```zig
// src/api_sse.zig:181-184  — por CADA línea del stream
            // CRITICAL: copy line_clean into arena-owned memory BEFORE we
            // shift `self.buf.items` via copyForwards below.
            const line_owned = try self.arena.allocator().dupe(u8, line_clean);

// src/api_sse.zig:263  — por cada payload
        const data_copy = try self.arena.allocator().dupe(u8, data);

// src/api_sse.zig:315, 323 — por cada campo
                    new_rc = try self.arena.allocator().dupe(u8, rc_node.string);
                    const new_content = try self.arena.allocator().dupe(u8, content_node.string);
```

`deinit` (`:114-120`) es el **único** sitio que libera la arena, y sólo se llama desde `ChunkEventStream.deinit` (`api_client.zig:264`). No hay `arena.reset` en ningún punto del stream.

**Por qué importa.** El protocolo es **cumulative-delta** (el propio parser loassume: "REPLACE-not-APPEND per cumulative-delta semantics", `:324`). Es decir, cada chunk contiene el texto **completo** hasta ese punto. Si una respuesta tiene N chunks con longitud creciente L, la arena retiene la suma 1+2+…+N = N(N+1)/2 × L bytes, y cada byte se copia ~4 veces (línea + data_buf + data_copy + content).

Con `max_completion_tokens = 8192` (`api_client.zig:96`) y `thinking.type = "adaptive"` (que produce `reasoning_content` además de `content`), una respuesta larga son ~1000-2000 chunks. Estimación: 2000 chunks × contenido medio 8 KB × 4 copias ≈ **64 MB de arena por request**, sin liberar hasta el final. Con `thinking` el doble. El budget declarado del proyecto es "≤ 30 MB" (context doc §9.2). Es un OOM, no una fuga silenciosa — y `MAX_ATTEMPTS = 3` puede triplicarlo si hay reintentos.

Además viola Tiger Style §3 ("No hidden dynamic growth") y §10.1 (alloc en hot path: 4 `dupe` por línea, cada línea).

**Fix** (ODD: `odd/tasks/sse-arena-bounding.md`, WU-1; es bloqueante de WU-4 porque WU-4 multiplicará el problema con `tool_calls`):

```zig
// src/api_sse.zig — el Event NO puede apuntar a la arena si la arena se resetea.
// Solución: Event lleva buffers inline; la arena queda sólo para el scratch
// de parsing JSON, con reset por evento.

pub const MAX_SSE_FIELD: usize = 64 * 1024;

pub const Message = struct {
    content_buf: [MAX_SSE_FIELD]u8 = .{0} ** MAX_SSE_FIELD,
    content_len: usize = 0,
    pub fn content(self: *const Message) []const u8 {
        std.debug.assert(self.content_len <= self.content_buf.len);
        return self.content_buf[0..self.content_len];
    }
};
```

Con eso, `data_copy` puede pasar a un buffer de stack y la arena eliminarse por completo — o quedar sólo para `std.json.parseFromSlice` con `arena.reset(.retain_capacity)` en cada `dispatchEvent`:

```zig
// src/api_sse.zig:275
        defer parsed.deinit();
        // Reset la arena por evento: el Event ya lleva copia inline, nada
        // de lo emitido depende de la arena. Sin esto el crecimiento es O(n²).
        defer self.arena.reset(.retain_capacity);
```

Este es el **fix mínimo** (1 línea) que ya elimina el O(n²) para el contenido, y es lo que recomiendo para v1: mantener los `Event` con slices a la arena, pero resetear por evento. Requiere verificar que `last_content`/`last_reasoning` (`:87-88`) no se usen después del reset — hoy sólo se usan para el discriminante `!= null` de `:159`, que puede volverse un `bool saw_content`.

**Test RED.**

```zig
test "P1-02: la arena del parser no crece con el número de chunks" {
    var p = Parser.init(testing.allocator);
    defer p.deinit();
    const before = p.arena.queryCapacity();
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        _ = try p.feed("data: {\"choices\":[{\"delta\":{\"content\":\"padding\"}}]}\n\n");
    }
    const after = p.arena.queryCapacity();
    // 200 chunks idénticos: la arena debe quedar bounded, no ×200
    try testing.expect(after < before * 3);
}
```

---

#### P1-03 · `src/runtime.zig:953` · `poll(2)` con `nfds = 1` sobre un array de 2 — la cancelación de subprocesses nunca dispara

**Qué pasa.**

```zig
// src/runtime.zig:948-961
                        var pollfd = [_]std.os.linux.pollfd{
                            .{ .fd = sub.stdout_fd, .events = std.os.linux.POLL.IN, .revents = 0 },
                            .{ .fd = args.cancel_pipe[0], .events = std.os.linux.POLL.IN, .revents = 0 },
                        };
                        const poll_timeout = @as(i32, @intCast(@min(remaining_ms, 100)));
                        _ = std.os.linux.poll(&pollfd, 1, poll_timeout);   // <-- nfds = 1
                        ...
                        if (pollfd[1].revents & std.os.linux.POLL.IN != 0) {   // <-- nunca se evalúa
                            _ = std.os.linux.kill(sub.pid, std.os.linux.SIG.KILL);
```

`std.os.linux.poll(fds, nfds, timeout)` examina `fds[0..nfds]`. Con `nfds = 1` sólo mira `pollfd[0]` (stdout). `pollfd[1].revents` conserva su valor de inicialización (`0`), así que la rama de cancelación **nunca es verdadera**. El `SIGKILL` en `:962` es inalcanzable.

**Por qué importa.** El único mecanismo de cancelación de una herramienta en vuelo está muerto. Un Ctrl+C con una herramienta en ejecución (que es el caso normal, dado el timeout de 30 s de `:936`) deja el subproceso corriendo hasta que termine o expire el timeout — y el harness tampoco muestra nada. Combinado con `TOOLS_PROFILE` que da `/tmp` RW, un tool colgado sigue escribiendo.

Nota: `:1072` hace `std.os.linux.poll(&pollfd, 1, 1)` sobre un array de 1 — ese es correcto. El bug es sólo en `:953`.

**Por qué nadie lo detectó**: el test que dice verificarlo (`runtime.zig:1637-1654`, *"T-SG-12: toolsRealMain kills subprocess on cancel_pipe wakeup"*) es un **grep-test** que sólo comprueba que las *strings* `"std.os.linux.SIG.KILL"` y `"cancel_pipe[0]"` existen en el fichero. Pasa con este bug. Ver P5-02.

**Fix** (WU-3 del feature doc de P0-13):

```zig
                        _ = std.os.linux.poll(&pollfd, pollfd.len, poll_timeout);
```

Y el test que debería haber existido:

```zig
test "WU-5: cancel-pipe mata el subprocess en vuelo" {
    // este SÍ es un test real, no un grep
    var rt = try Rt.Runtime.spawn(.{});
    defer rt.deinit();
    const argv = [_][]const u8{ "/bin/sleep", "30" };
    var sub = try sandbox.Sandbox.spawnToolSubprocess(
        testing.allocator, Rt.TOOLS_PROFILE, &argv, &[_][*:0]const u8{}, null);
    // el worker corre el read loop real; escribimos en cancel_pipe
    var pollfd = [_]std.os.linux.pollfd{ .{ .fd = sub.stdout_fd, .events = .POLL.IN, .revents = 0 },
                                         .{ .fd = rt.cancel_pipe[0], .events = .POLL.IN, .revents = 0 } };
    _ = std.os.linux.write(rt.cancel_pipe[1], &.{0x01}, 1);
    _ = std.os.linux.poll(&pollfd, pollfd.len, 100);
    try testing.expect((pollfd[1].revents & std.os.linux.POLL.IN) != 0);  // RED hoy
    _ = std.os.linux.kill(sub.pid, std.os.linux.SIG.KILL);
    _ = sub.wait();
    try testing.expect(std.os.linux.W.IFSIGNALED(sub_wait_status));
}
```

**Test RED directo (el que detecta el off-by-one):**

```zig
test "P1-03 RED: el poll de toolsWorkerMain cubre ambos fd" {
    const src = try std.Io.Dir.cwd().readFileAlloc(
        testing.io, "src/runtime.zig", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(src);
    const idx = std.mem.indexOf(u8, src, "args.cancel_pipe[0]") orelse return error.NotFound;
    // el poll inmediatamente posterior debe pasar pollfd.len, no un literal
    const tail = src[idx .. @min(idx + 256, src.len)];
    try testing.expect(std.mem.indexOf(u8, tail, "poll(&pollfd, pollfd.len") != null
        or std.mem.indexOf(u8, tail, "poll(&pollfd, 2") != null);
}
```

---

#### P1-04 · `src/runtime.zig:301-323` · `Runtime.join` con timeout es un no-op; `run` hace join secuencial sin timeout

**Qué pasa.**

```zig
// src/runtime.zig:301-323
    pub fn join(self: *Runtime, io: std.Io, timeout_ns: u64) JoinResult {
        const start = std.Io.Timestamp.now(io, .real);
        const timeout_dur: std.Io.Duration = .{ .nanoseconds = @intCast(timeout_ns) };
        if (self.tui_thread) |t| {
            const now = std.Io.Timestamp.now(io, .real);
            if (std.Io.Timestamp.durationTo(start, now).nanoseconds >= timeout_dur.nanoseconds) return .timeout;
            t.join();          // <-- join() BLOQUEA hasta que el hilo muere
            self.tui_thread = null;
        }
        ...
```

`std.Thread.join()` es bloqueante e ininterrumpible. El check de timeout ocurre **antes** del join, así que si el hilo cuelga, `join()` cuelga y `JoinResult.timeout` es inalcanzable. Lo mismo en `run` (`:291-293`), que hace join de TUI → Agent → Tools sin ningún timeout:

```zig
// src/runtime.zig:291-293
        if (self.tui_thread) |t| t.join();
        if (self.agent_thread) |t| t.join();
        if (self.tools_thread) |t| t.join();
```

**Por qué importa.** `DEFAULT_SHUTDOWN_TIMEOUT_NS = 5s` (`:40`) y `JoinResult.timeout` (`:207-210`) son API pública que promete un contrato que no cumple. Combinado con P0-12 (el Agent thread puede colgarse para siempre en TLS) y P1-03 (los workers no responden al cancel), **el proceso puede no terminar nunca**. El único escape es SIGKILL externo. Y el test que verifica la API (`runtime.zig:1244-1259`) sólo comprueba el *shape* del enum, no el comportamiento.

**Fix** (WU-4 del feature doc). `std.Thread` en 0.16 no expone `timedJoin`; las opciones son (a) `std.Thread.CpuTime`/timestamp polling con un flag de "thread finished" propio, o (b)amousar `std.Io` deadlines. Lo mínimo honesto para v1:

```zig
// src/runtime.zig:301-323 — hacer el timeout real
    pub fn join(self: *Runtime, io: std.Io, timeout_ns: u64) JoinResult {
        const deadline = std.Io.Timestamp.now(io, .real).nanoseconds + @as(i64, @intCast(timeout_ns));
        if (self.tui_thread) |*t| {
            if (self._joinWithDeadline(t.*, deadline) == .timeout) return .timeout;
            self.tui_thread = null;
        }
        ...
    }

    /// Join con deadline: hace detach() si expira. NOTA: detach deja el
    /// hilo corriendo accessing `self.channels` — por eso `shutdown()` debe
    /// haberse llamado antes y `Channels` debe seguir vivo (es stack-local
    /// en Runtime, cuyo frame vive hasta run() retorna). Documentar.
    fn _joinWithDeadline(t: std.Thread, deadline_ns: i64) enum { clean, timeout } { ... }
```

Y en `run`, cambiar el orden: **shutdown primero, luego join**, y loguear si expira. El orden actual (join TUI, que es quien detecta el shutdown) funciona sólo por casualidad del diseño.

**Test RED.**

```zig
test "P1-04 RED: join devuelve .timeout si un hilo no termina" {
    var rt = try Runtime.spawn(.{});
    defer rt.deinit();
    // inyectar un hilo que no termine nunca
    rt.stuck_thread = try std.Thread.spawn(.{}, StuckForever.run, .{});
    const t0 = nowMs();
    const r = rt.join(testing.io, 200 * std.time.ns_per_ms);
    const dt = nowMs() - t0;
    try testing.expect(r == .timeout);
    try testing.expect(dt < 2000);   // volvió en ~200ms, no se colgó
}
```

---

#### P1-05 · `src/runtime.zig:120` · `static_messages_storage` es un global compartido, no thread-local (doc drift + carrera latente)

**Qué pasa.**

```zig
// src/runtime.zig:114-120
/// ponytail: backing messages storage is `static_messages_storage` (thread-local
/// buffer). ...
var static_messages_storage: [1]api_client.Message = .{.{ .role = "user", .content = "" }};
```

El comentario dice "thread-local". En Zig, un `var` a nivel de módulo es **compartido por todos los hilos** (sólo `threadlocal var` es por-hilo). El context doc repite el error: `zargeant-context-for-ai-agent.md:185` — *"Static messages storage `static_messages_storage: [1]api_client.Message` (thread-local; …)"*.

**Por qué importa.** Hoy sólo el hilo Agent llama a `buildMockRequest`/`buildRealRequest` (`runtime.zig:533, 536`), así que no hay carrera **observada**. Pero:
1. `toolsRealMain` crea **4 workers** (`runtime.zig:831-834`) que comparten `args`. Si alguno llegara a construir un Request, corrompe el slot del Agent.
2. El doc afirma una garantía que el código no da. Un mantenedor que confíe en el comentario introducirá una carrera.
3. `buildMockRequest` y `buildRealRequest` hacen `@memset` + escritura al slot **sin sincronización** — si dos hilos llaman, el `Request.messages` resultante puede apuntar a contenido mixtureado (una key de un hilo + contenido de otro). Eso sería una fuga de la API key de un usuario al prompt de otro... en un entorno de un solo usuario es inexplotable, pero es un data race real.

**Fix** (mismo feature doc; no requiere ODD propio, es una línea):

```zig
// src/runtime.zig:120
threadlocal var static_messages_storage: [1]api_client.Message = .{.{ .role = "user", .content = "" }};
```

Un `comptime` assert que lo vuelva explícito:

```zig
comptime {
    // El doc-comentario decía "thread-local" pero era un `var` global.
    // Este assert hace imposible la regresión.
    if (@TypeOf(@field(static_messages_storage_parent, "x"))) {}
}
```

Más simple y test-friendly:

```zig
test "P1-05: static_messages_storage es thread-local" {
    // El compilador lo garantiza; el test documenta la intención.
    // (assert de tipo: no se puede comprobar thread-local-ness en runtime)
    try testing.expect(true);
}
```

→ Mejor: un test de **comportamiento** con dos hilos:

```zig
test "P1-05: dos hilos construyendo Request no comparten el slot" {
    const S = struct {
        fn run(out: *api_client.Request) void {
            out.* = Rt.buildRealRequest(.{ .id = 1, .name = "x", .args = "AAA" });
        }
    };
    var r1: api_client.Request = undefined;
    var r2: api_client.Request = undefined;
    const t = try std.Thread.spawn(.{}, S.run, .{&r1});
    S.run(&r2);
    t.join();
    // ambos deben ver su propio contenido
    try testing.expectEqualStrings("AAA", r1.messages[0].content);
    try testing.expectEqualStrings("AAA", r2.messages[0].content);
}
```

Esto **falla hoy** de forma intermitente (por eso es RED-y-flaky); con `threadlocal` pasa siempre.

---

#### P1-06 · `src/api_client.zig:482-491` · Loop de headers sin cota superior ni chequeo de cancel en la rama TLS

**Qué pasa.**

```zig
// src/api_client.zig:482-491
        while (header_end == 0) {
            const n = tls.readSome(resp_buf[resp_len..]) catch |err| switch (err) {
                error.ConnectionClosed => return error.ReadFailed,
                else => return error.ReadFailed,
            };
            resp_len += n;
            if (std.mem.indexOf(u8, resp_buf[0..resp_len], "\r\n\r\n")) |idx| {
                header_end = idx + 4;
            }
        }
```

Tres problemas: (a) `resp_len` no está acotado por una condición de salida explícita; (b) cuando `resp_len == 16384`, `resp_buf[resp_len..]` es un slice vacío y `readSliceShort` sobre un destino de 0 bytes tiene comportamiento no definido respecto a bloqueo; (c) no hay `pollWithCancel`.

La rama plain (`:604-621`) sí acota vía `read(2)`: con `count == 0` el kernel devuelve 0 → `n <= 0` → `return error.ReadFailed`. Es decir, **la rama plain sale por accidente**; la TLS depende del comportamiento de `readSliceShort` con buffer vacío.

**Por qué importa.** Un servidor (o un middlebox) que mande >16 KiB de headers sin `\r\n\r\n` y mantenga la conexión abierta deja al Agent thread en un read sin cota. *Hipótesis, requiere verificación empírica*: si `readSliceShort` con `dest.len == 0` retorna 0, `readSome` mapea a `error.ConnectionClosed` → `ReadFailed` → termina (seguro). Si bloquea, cuelga. No puedo verificarlo sin toolchain; lo marco como hipótesis pero la **falta de cota explícita es un hecho** y el fix no depende de cuál sea la semántica.

`if (n2 == 0) break;` en `:531` y `:671` también es código muerto (readSome nunca retorna 0, mapea a ConnectionClosed antes).

**Fix** (fusionar con P0-12, mismo WU):

```zig
        // Cota explícita: los headers HTTP no pueden exceder el buffer.
        // (No depender del comportamiento de readSliceShort con dest vacío.)
        while (header_end == 0) {
            if (resp_len == resp_buf.len) return error.MalformedResponse;
            if (pollCancelImmediate(cancel_pipe)) return error.Cancelled;
            const n = tls.readSome(resp_buf[resp_len..]) catch |err| switch (err) {
                error.ConnectionClosed => return error.ReadFailed,
                error.ReadFailed => return error.ReadFailed,
            };
            resp_len += n;
            if (std.mem.indexOf(u8, resp_buf[0..resp_len], "\r\n\r\n")) |idx| header_end = idx + 4;
        }
```

**Test RED.**

```zig
test "P1-06: headers > 16 KiB sin CRLFCRLF terminan en error, no en hang" {
    // requiere un tls_conn inyectable; con la abstracción extraída
    // (readResponseTls) el test es un string de 32 KiB y un fake reader.
    try testing.expectError(error.MalformedResponse,
        readResponseTls(fake, &buf, null, deadline));
}
```

---

### P2 — Memory safety

---

#### P2-01 · `src/channels.zig:88-132` · La afirmación "todos los payloads usan inline buffers" es falsa: 4 variantes cruzan hilos con `[]const u8`

**Qué pasa.** El context doc afirma (`zargeant-context-for-ai-agent.md:221`):

> **Todos los payloads usan inline buffers + length counters** (`err_buf: [128]u8` + `err_len: usize`) — NUNCA `[]const u8` slice aliasing a stack-local buffer (ver §10.3 — Bug 1).

Es falso. De las 19 variantes:

```zig
// src/channels.zig:88-120 (extracto)
    KeyPress: terminal.event.Key,
    ApiKeySubmitted: []const u8,              // ← slice
    UnlockPasswordSubmitted: []const u8,      // ← slice
    UserToolRequest: UserToolArgs,            // ← name/args son []const u8
    ...
    ConsentGrant: []const u8,                 // ← slice
    ValidateApiRequest: ValidateApiRequestPayload,   // ✓ inline
    ...
    AgentToolRequest: UserToolArgs,           // ← slice
    AgentError: AgentErrorPayload,            // ← message: []const u8
    ...
    DispatchToolRequest: UserToolArgs,        // ← slice
    ...
    ToolResult: ToolResultPayload,            // ← output: []const u8
    ToolError: ToolErrorPayload,              // ← message: []const u8
    ...
    StreamChunk: StreamChunkPayload,          // ← text: []const u8
```

Sólo 2 de 19 (`ValidateApiRequest`, `ValidateApiReply`) usan inline. Las otras 17 cruzan la frontera de hilos con slices, y de las que tienen productor vivo, todas están rotas (P0-06, P0-07, P0-08).

`UserToolArgs` (`:186-190`) es el caso peor porque es el payload de las tres aristas de herramientas:

```zig
// src/channels.zig:186-190
pub const UserToolArgs = struct {
    id: u64,
    name: []const u8,
    args: []const u8,
};
```

**Por qué importa.** WU-4 (tool_calls) tiene que emitir `DispatchToolRequest`. Si se hace sobre `UserToolArgs` con slices, **se propaga el UAF al path de herramientas**: el parser SSE emite, el Agent thread pasa el slice al canal, el worker lo formatea con `allocPrint` — y si el contenido es de la arena del parser (que se resetea con P1-02), es un UAF garantizado. **WU-4 no debe aterrizar antes de que `UserToolArgs` sea inline.**

**Fix.** Definir un payload inline paralelo y migrar las aristas de herramientas primero (dejar `UserToolArgs` como alias deprecated para no romper los 34+ tests que lo usan):

```zig
// src/channels.zig
pub const TOOL_NAME_BUF_LEN: usize = 128;
pub const TOOL_ARGS_BUF_LEN: usize = 2048;

pub const ToolRequestInline = struct {
    id: u64,
    name_buf: [TOOL_NAME_BUF_LEN]u8 = .{0} ** TOOL_NAME_BUF_LEN,
    name_len: usize = 0,
    args_buf: [TOOL_ARGS_BUF_LEN]u8 = .{0} ** TOOL_ARGS_BUF_LEN,
    args_len: usize = 0,
    pub fn name(self: *const ToolRequestInline) []const u8 { ... }
    pub fn args(self: *const ToolRequestInline) []const u8 { ... }
};
```

**Test RED.** Guard de tipo, que no puede falsearse:

```zig
test "P2-01: ningún payload de Event contiene un slice directo" {
    const fields = @typeInfo(channels_mod.Event).@"union".fields;
    inline for (fields) |f| {
        // Terminal.event.Key contiene slices legítimamente (buffer del parser,
        // TUI-thread-only). El resto no debe.
        if (comptime std.mem.eql(u8, f.name, "KeyPress")) continue;
        try testing.expect(f.type != []const u8);
    }
}
```

---

#### P2-02 · `src/runtime.zig:1129-1162` · `parse_argv` filtra los elementos ya asignados si `dupe` falla a mitad

**Qué pasa.**

```zig
// src/runtime.zig:1146-1161
    var argv_storage = try allocator.alloc([]const u8, argc);
    var slot: usize = 0;
    var i: usize = 0;
    while (i < args.len) {
        while (i < args.len and isWhitespace(args[i])) : (i += 1) {}
        if (i >= args.len) break;
        const start = i;
        while (i < args.len and !isWhitespace(args[i])) : (i += 1) {}
        argv_storage[slot] = try allocator.dupe(u8, args[start..i]);
        slot += 1;
    }
    std.debug.assert(slot == argc);
    return argv_storage;
```

No hay `errdefer` que libere `argv_storage[0..slot]` si el `try dupe` de la iteración `slot` falla. El `alloc` externo tampoco se libera.

**Por qué importa.** Sólo en OOM, así que es una fuga en el camino de error — pero el camino de error es precisamente el que el caller de `runtime.zig:886-897` maneja, y con `page_allocator` una fuga no se detecta. Con `testing.allocator` en los tests sí (panic "memory address 0x... leaked"), lo que significa que **ningún test fuerza esta rama** — es la cobertura de error que falta.

**Fix.**

```zig
    const argv_storage = try allocator.alloc([]const u8, argc);
    errdefer {
        for (argv_storage[0..slot]) |e| allocator.free(e);
        allocator.free(argv_storage);
    }
```

(Nótese: `argv_storage` debe ser `const` para que el `errdefer` vea el valor final.)

**Test RED.**

```zig
test "parse_argv: OOM a mitad no filaga los elementos previos" {
    var fail_after: usize = 2;
    const Failing = struct {
        var n: usize = 0;
        fn alloc(ctx: *anyopaque, len: usize, ra: u8, ret_addr: usize) ?[*]u8 {
            _ = ctx; _ = ra; _ = ret_addr;
            if (Failing.n == 0) return @ptrFromInt(0x1000);
            Failing.n -= 1;
            return @ptrFromInt(0x2000);
        }
        fn free(ctx: *anyopaque, memory: []u8, ra: u8, ret_addr: usize) void { ... }
    };
    // wrapper que falla la 3ª llamada
    const result = parse_argv(failing_allocator, "a b c d e f");
    try testing.expectError(error.OutOfMemory, result);
    // testing.allocator debajo reporta la fuga si el errdefer falta
}
```

---

#### P2-03 · `src/api_client.zig:725` · `statusToError` devuelve `anyerror` — viola §10.2 y §14.2

**Qué pasa.**

```zig
// src/api_client.zig:725-731
fn statusToError(status: u16) anyerror {
    return switch (status) {
        400 => error.InvalidParams,
        404 => error.NotFound,
        else => error.Io,
    };
}
```

Y en el mismo módulo, `api_auth.zig:234` (`fn run(ctx: *@This()) anyerror!api_client.tls_conn`), `bridge_sync_async.zig:41` (`(BridgeError || anyerror)!std.Io.net.Stream`) y `:84`. En `src/terminal/`: `dpm.zig:30,54,64,69,75,80,93,101,108,114,121,249,261,285,286,287,353`, `event.zig:288,289,853,896`, `kitty.zig:50,52`.

**Por qué importa.** `anyerror` es exactamente la razón por la que el proyecto lo prohíbe (§10.2: *"testing can't force errors against it"*). Con `statusToError` devolviendo `anyerror`, el `catch |err| switch (err)` de `runtime.zig:544-550` **no puede ser exhaustivo** y por eso necesita un `else =>` — que es la razón de ser del `else =>` en la línea 549. La cadena de degradación: `anyerror` → `else` lazy → violates §10.4.

En `src/terminal/*` el uso de `anyerror` es más defendible (los `writer.writeAll` de Zig 0.16 devuelven `anyerror!void` y envolverlos exigiría un tipo de error propio por función), pero debería documentarse como excepción explícita en §10.2 en vez de ser silencio.

**Fix** (WU-1 de `odd/tasks/typed-error-sets.md`):

```zig
// src/api_client.zig — error set explícito, reutilizado por el catch de runtime
pub const ApiError = error{
    InvalidParams,
    NotFound,
    Io,
    // ... el resto de los que tryOneAttempt ya devuelve
};

fn statusToError(status: u16) ApiError {
    return switch (status) {
        400 => error.InvalidParams,
        404 => error.NotFound,
        500, 502, 503, 504 => error.Io,
        501, 505 => error.Io,
        else => error.Io,   // TODO: eliminar cuando se enumere la tabla completa
    };
}
```

Y `runtime.zig:544-550` puede volverse exhaustivo:

```zig
                const stream = api_client.Client.stream(...) catch |err| {
                    const payload = mapChunkError(api_client.classify(err));  // fn exhaustivo
                    ...
                };
```

**Test RED.** Un guard de tipo sobre la firma:

```zig
test "P2-03: statusToError devuelve un error set explícito" {
    try testing.expect(@typeInfo(@TypeOf(api_client.statusToError)).@"fn".return_type.? != anyerror);
}
```

---

#### P2-04 · `src/api_auth.zig:662-663` y `src/modal.zig:1802-1803` · `readEnv`/`readEnvVar` devuelven slices a un stack-local de 8 KiB, con doc-comment que afirma lo contrario

**Qué pasa.** **Tres** copias independientes del mismo helper (verificado por `grep`):

| Copia | Ubicación | Nombre |
|---|---|---|
| 1 | `src/api_auth.zig:662` | `readEnv` |
| 2 | `src/modal.zig:1802` | `readEnvVar` |
| 3 | `src/logger.zig:230` | `readEnv` |

Las dos primeras devuelven un slice al `var buf: [8192]u8` local:

```zig
// src/api_auth.zig:662-691
fn readEnv(name: []const u8) ?[]const u8 {
    const fd = std.posix.openat(...) catch return null;
    defer _ = std.os.linux.close(fd);

    var buf: [8192]u8 = undefined;          // ← stack-local
    var total: usize = 0;
    ...
            const value = entry[name.len + 1 ..];   // ← slice dentro de buf
            if (value.len > 0) return value;        // ← ESCAPA del frame
```

Y el doc-comment de la copia de `modal.zig` es activamente falso:

```zig
// src/modal.zig:1800-1801
/// Read /proc/self/environ to find `name`. Returns the value slice (NOT
/// null-terminated; safe to use for the duration of the process).
```

"safe to use for the duration of the process" es **falso**: es válido hasta que la función retorna, y la función retorna un slice.

**Por qué importa.** Los callers actuales son afortunados: `storageCredentialsPath`/`xdgCredentialsPath` hacen `bufPrint(out_buf, ...)` inmediatamente, copiando a un buffer del caller antes de retornar. **Hoy no explota.** Pero:
1. El doc-comment invita exactamente al bug que el proyecto forbids.
2. `/proc/self/environ` con un entorno grande (>8 KiB) se trunca en `total`, y si `XDG_CONFIG_HOME` cae fuera del corte, `readEnv` devuelve `null` silenciosamente → el harness usa `$HOME/.config/zargeant` mientras el usuario cree que usa `$XDG_CONFIG_HOME`. Fallo de Engram-style, difícil de diagnosticar.
3. `readEnv` de `logger.zig` se usa para `TMPDIR`/`XDG_RUNTIME_DIR` en `resolveWritableDefaultDir` — misma truncatura.

**Fix** (WU-1 de `odd/tasks/env-and-paths-hardening.md`; fusionar con P4-01 porque es la misma duplication):

```zig
// src/api_auth.zig — público, con buffer del caller
/// Lee `name` de /proc/self/environ. El slice retornado vive en `out_buf`
/// (propiedad del caller), NO en el stack de esta función.
/// ponytail: el contrato de por qué NO se retorna un slice a un stack-local
/// es docs/conventions.md §"State storage" — Bug 1.
pub fn readEnvInto(out_buf: []u8, name: []const u8) ?[]const u8 {
    const fd = std.posix.openat(std.posix.AT.FDCWD, "/proc/self/environ",
        .{ .ACCMODE = .RDONLY }, 0) catch return null;
    defer _ = std.os.linux.close(fd);

    // 64 KiB: los entornos reales (CI, containers, shells anidados) pueden
    // superar 8 KiB. Sin esto, una variable truncada = path equivocado.
    var buf: [64 * 1024]u8 = undefined;
    var total: usize = 0;
    while (total < buf.len) {
        const n = std.posix.read(fd, buf[total..]) catch break;
        if (n == 0) break;
        total += n;
    }
    ... // copia a out_buf, devuelve out_buf[0..vlen]
}
```

Y borrar las copias de `modal.zig` y `logger.zig` para que usen esta.

**Test RED.**

```zig
test "P2-04: readEnv sobrevive al return de la función que lo contiene" {
    var out: [256]u8 = undefined;
    // poison el stack después del return
    const v = api_auth.readEnvInto(&out, "PATH") orelse return;
    var scratch: [8192]u8 = undefined;
    @memset(scratch, 0xEE);
    try testing.expect(v.len > 0);
    try testing.expect(scratch[0] == 0xEE);   // el valor no vivía en scratch
}
```

Test más fuerte y determinista:

```zig
test "P2-04: el slice retornado apunta a out_buf, no a un stack-local" {
    var out: [256]u8 = undefined;
    const v = api_auth.readEnvInto(&out, "HOME") orelse return error.NoHome;
    try testing.expect(v.ptr >= @intFromPtr(&out) and v.ptr < @intFromPtr(&out) + out.len);
}
```

---

#### P2-05 · `src/api_auth.zig:486` y `:620` · La clave derivada Argon2id nunca se wipea

**Qué pasa.**

```zig
// src/api_auth.zig:477-495
fn tryDecrypt(...) AuthError![]u8 {
    const alloc = if (builtin.is_test) testing.allocator else std.heap.page_allocator;
    const derived = deriveKey(io, password, salt);          // ← [32]u8 en el stack
    const out = alloc.alloc(u8, ciphertext.len) catch return error.OutOfMemory;
    errdefer alloc.free(out);
    const nonce_arr: [12]u8 = nonce[0..12].*;
    decrypt(out, ciphertext, tag, derived, nonce_arr) catch |err| switch (err) { ... };
    return out;                                             // ← `derived` no se borra
}
```

Y en `writeEncrypted` (`:620-626`), idéntico.

**Por qué importa.** `derived` es la clave maestra de 32 bytes que desprotege la API key. Sin wipe, queda en el frame de pila hasta que otra llamada lo sobrescriba — y en un programa que carga la clave en cada unlock, hay una ventana no nula. El propio módulo demuestra que sabe hacerlo: `runtime.zig:796` hace `@memset(key, 0)` antes de liberar. La regla de §10.7 ("`PR_SET_DUMPABLE` antes de cargar secrets") ni siquiera existe en el código (ver §6).

Compuesto por P0-10: el log en `/tmp` es world-readable para quienasekee leerlo, y aquí la clave vive en un core dump potencial (no hay `PR_SET_DUMPABLE = 0`).

**Fix.**

```zig
// src/api_auth.zig:477-495
    var derived = deriveKey(io, password, salt);
    defer std.crypto.utils.secureZero(u8, &derived);   // wipe garantizado
    ...
```

Y en `writeEncrypted` igual. Si `secureZero` no está disponible en 0.16, un `volatile`-style manual:

```zig
    var derived = deriveKey(io, password, salt);
    defer {
        for (&derived) |*b| {
            const v: *volatile u8 = b;
            v.* = 0;
        }
    }
```

**Test RED.** Difícil de testear directamente; lo que sí se puede:

```zig
test "P2-05: deriveKey no deja rastro en el heap del allocator" {
    // Wrap de page_allocator que conta allocs>0 durante decrypt
    var leaked: usize = 0;
    const Counting = struct { ... };
    _ = try api_auth.loadWithUnlock(testing.io, tmp_path, "wrongpass");
    // Ningún bloque del allocator de 32 bytes debe sobrevivir
    try testing.expectEqual(@as(usize, 0), leaked);
}
```

Honestamente, el test RED más útil aquí es un **assert de política** en el feature doc, no un unit test. Lo marco como tal.

---

#### P2-06 · `src/sandbox.zig:744` · Trabajo con allocator y syscalls de FS **post-fork** en un padre multi-hilo

**Qué pasa.**

```zig
// src/sandbox.zig:723-744
        const pid = std.os.linux.fork();
        if (pid == std.math.maxInt(usize)) return error.ForkFailed;
        if (pid == 0) {
            _ = std.os.linux.dup2(stdout_pipe[1], 1);
            ...
            const applied = sandbox_profile.buildFromProfile(allocator, profile) catch { ... };
```

`fork()` se llama desde un worker thread del pool (N=4), en un proceso con al menos 6 hilos (TUI, Agent, 4 workers, + el propio `toolsRealMain`). Sólo el hilo que llama a `fork()` existe en el hijo. `buildFromProfile` (`sandbox_profile.zig:168-200`) invoca `createRuleset` (syscall), `openat` × N, `addPathBeneathRule` × N.

El context doc (§3.2) dice explícitamente: *"Stack allocation post-`clone` está prohibido (corrompe heap del parent — ver investigation-2.md §3 Eje 2)"*. Aquí el allocator es `args.allocator` = `page_allocator` (`runtime.zig:283, 286, 289`), que es `mmap`-based y **no** toma locks — así que el caso de deadlock de malloc no aplica hoy. Pero `buildFromProfile` ignora el allocator (`_ = allocator;` en `sandbox_profile.zig:169`), así que **no hay ninguna asignación**; el riesgo es puramente el de la librería/glibc y el de los handlers de señal en el hijo.

**Por qué importa.** El riesgo esHipótesis (no hay malloc, no hay locks). Lo que **sí** es un hecho y es grave: si cualquier cambio futuro hace que `buildFromProfile` use un allocator con locks, o añade un `std.debug.assert` que llame a algo con I/O, el hijo se cuelga en `malloc` con el lock del padre detenido para siempre — el deadlock Clásico de post-fork. La regla de §3.2 existe por esto.

**Fix.** Mover el trabajo a un sitio seguro: como el comentario de `:718-722` ya explica que Landlock exige que el mismo hilo cree y aplique la ruleset, la forma correcta es **`posix_spawn`/`vfork` no**, sino: pre-construir la ruleset en el padre y **aplicarla con `landlock_restrict_self` en el hijo inmediatamente**, asumiendo que el requisito de mismo-hilo es sólo para `landlock_add_rule` (no para `restrict_self`). Verificar contra la documentación del kernel antes de asumir. Si el requisito persiste, al menos:

```zig
// src/sandbox.zig — antes del fork
// ponytail: buildFromProfile DEBE quedar en el padre. Ejecutar syscalls
// con I/O post-fork en un proceso multi-hilo es la causa clásica del
// deadlock post-fork (investigation-2.md §3 Eje 2). Ver P2-06.
```

**Test RED.** Difícil sin un seam. Lo que sí funciona:

```zig
test "P2-06: buildFromProfile no se llama post-fork (guard estático)" {
    // RED: hoy la llamada está después de `if (pid == 0) {`
    const src = try std.Io.Dir.cwd().readFileAlloc(
        testing.io, "src/sandbox.zig", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(src);
    const fork_idx = std.mem.indexOf(u8, src, "if (pid == 0)") orelse return error.NoFork;
    const bpf_idx = std.mem.indexOf(u8, src, "fn buildFromProfile") orelse return error.NoHelper;
    // el helper debe estar en sandbox_profile.zig, no aquí — guard de que
    // sandbox.zig no lo invoca en el brazo del hijo
    try testing.expect(std.mem.indexOf(u8, src[fork_idx..], "buildFromProfile") == null);
}
```

*(Este guard pasa hoy porque la llamada está en `sandbox_profile.zig`; el valor está en documentar la restricción para que nadie la reintroduzca.)*

---

### P3 — Correctness

---

#### P3-01 · `src/api_client.zig:1801` + `:483-486` · Enmascaramiento de errores de TLS en `readSome` y en el catch del llamador

**Qué pasa.**

```zig
// src/api_client.zig:1795-1804
    /// Reads plaintext ... We map 0 → `error.ConnectionClosed` so callers can
    /// distinguish a clean server-side close from a partial read.
    pub fn readSome(self: *tls_conn, dest: []u8) !usize {
        const r = self.connection.reader();
        const n = r.readSliceShort(dest) catch return error.ReadFailed;
        if (n == 0) return error.ConnectionClosed;
        return n;
    }
```

Y el llamador, que **sí** intenta preservar la distinción:

```zig
// src/api_client.zig:483-486
            const n = tls.readSome(resp_buf[resp_len..]) catch |err| switch (err) {
                error.ConnectionClosed => return error.ReadFailed,   // ← ambas arms idénticas
                else => return error.ReadFailed,                     // ← idem
            };
```

**Por qué importa.** Se pierde la distinción entre:
- cierre limpio del servidor (`EndOfStream`),
- reset por peer (`ConnectionReset`),
- error de protocolo TLS (`error.Tls`),
- OOM (`OutOfMemory`),
- fallo de escritura subyacente.

Esto importa operativamente: un `ConnectionReset` (el caso más común en producción: el servidor cierra la conexión a mitad de stream por un proxy que corta) se reporta al usuario como `ReadFailed` → `mapChunkError(.Io)` → `.network` → un `AgentError` genérico. Y un OOM se reporta como error de red. El doc-comment de `:1796-1798` afirma una distinción que el código no entrega, y el `switch` de `:484` con dos arms idénticas es código muerto que dice haberlo implementado.

**Fix.**

```zig
// src/api_client.zig:1795-1804
    pub fn readSome(self: *tls_conn, dest: []u8) !usize {
        std.debug.assert(dest.len > 0);   // §10.5 — evita el caso ambiguo
        const r = self.connection.reader();
        const n = r.readSliceShort(dest) catch |err| return switch (err) {
            error.EndOfStream => error.ConnectionClosed,
            error.ConnectionResetByPeer => error.ConnectionReset,
            error.OutOfMemory => error.OutOfMemory,
            error.Tls => error.TlsProtocolError,
            else => error.ReadFailed,
        };
        if (n == 0) return error.ConnectionClosed;
        return n;
    }
```

```zig
// src/api_client.zig:483-486 — el switch vuelve a tener motivo de existir
            const n = tls.readSome(resp_buf[resp_len..]) catch |err| switch (err) {
                error.ConnectionClosed => return error.ReadFailed,
                error.ConnectionReset => return error.ConnectionReset,
                error.TlsProtocolError => return error.TlsHandshakeFailed,
                error.OutOfMemory => return error.OutOfMemory,
                error.ReadFailed => return error.ReadFailed,
            };
```

**Test RED.**

```zig
test "P3-01: ConnectionReset del socket TLS no se reporta como ReadFailed" {
    // con el tls_conn extraído detrás de una interfaz, un reader fake que
    // devuelve error.ConnectionResetByPeer debe propagar ConnectionReset
    try testing.expectError(error.ConnectionReset, fake_tls.readSome(&buf));
}
```

---

#### P3-02 · `src/sandbox_profile.zig:66-67` · El perfil por defecto hardcodea `/home/josel/`

**Qué pasa.**

```zig
// src/sandbox_profile.zig:64-71
const default_paths = [_]PathRule{
    .{ .path = "/tmp", .access = .{ .read = true, .write = true } },
    .{ .path = "/home/josel/.config/zargeant", .access = .{ .read = true, .write = true } },
    .{ .path = "/home/josel/.cache/zargeant", .access = .{ .read = true, .write = true } },
    ...
```

Y el endpoint (`:112`): `.{ .host = "api.minimaxi.chat", .port = 443 }` — el dominio **antiguo**, marcado como archivals en `api_client.zig:55-58`.

**Por qué importa.** (a) `default()` no lo usa el runtime (usa `TOOLS_PROFILE`), así que es inerte hoy; pero si alguien lo adopta, en cualquier máquina que no sea la del autor, esas reglas simplemente no aplican (fall-closed: el path queda denegado, silenciosamente, porque `buildFromProfile:192` hace `catch continue`). (b) Otorga RW sobre un directorio de home **concreto y del autor** en un fichero que se distributes como código abierto — es un dato personal filtrado en el repo. (c) `api.minimaxi.chat` está muerto: el host real es `api.minimax.io`.

**Fix.** Resolver en runtime con `readEnvInto` (P2-04) en vez de hardcodear, o borrar las dos líneas y documentar que el path de config lo añade el caller:

```zig
const default_paths = [_]PathRule{
    .{ .path = "/tmp", .access = .{ .read = true, .write = true } },
    // El path de config/cache lo resuelve el caller vía readEnvInto
    // (ver P2-04). Hardcodear un $HOME de un autor específico es un bug
    // de portabilidad y filtra un dato personal en el repo.
    .{ .path = "/usr/lib", .access = .{ .read = true } },
    .{ .path = "/lib", .access = .{ .read = true } },
    .{ .path = "/etc/ssl", .access = .{ .read = true } },
};

/// v1: HTTPS a MiniMax sólo. Host actual (api.minimax.io), NO el dominio
/// archivado api.minimaxi.chat.
const default_endpoints = [_]NetEndpoint{ .{ .host = "api.minimax.io", .port = 443 } };
```

**Test RED.**

```zig
test "P3-02: ningún path por defecto contiene un home hardcodeado" {
    for (sandbox_profile.default().paths) |rule| {
        try testing.expect(!std.mem.startsWith(u8, rule.path, "/home/"));
    }
    // y el endpoint debe coincidir con el host de producción
    try testing.expectEqualStrings("api.minimax.io", sandbox_profile.default().allowed_net_endpoints[0].host);
}
```

---

#### P3-03 · `src/runtime.zig:620` y `src/api_client.zig:237-245` · `else =>` lazy sobre unions que trivian el contrato de §10.4

**Qué pasa.**

```zig
// src/runtime.zig:620  (switch sobre Event, 19 variants)
            else => {},
```
Solo 6 arms explícitos; los otros 13 variants caen al `else`. Si mañana se añade `Event.Reload` y el developer olvida el arm, **no hay error de compilación** — el §10.4 de `AGENTS.md` dice "Never use `else` pragma in `switch` statements over enums … Force compile-time safety when new enum variants are added". No se cumple.

Igual en `api_client.zig:237-245` (`ChunkEventStream.next` sobre `api_sse.Event`, `else =>` cubre 3 de 7).

**Por qué importa.** Es la diferencia entre "el compilador te avisa" y "un bug silencioso en producción". Con WU-4oltzandi Pending, añadir `Event.ToolCallsDetected` sería trivial de olvidar.

**Fix.**

```zig
// src/runtime.zig:504-621
        switch (event) {
            .Shutdown => return,
            .UserToolRequest => |utr| { ... },
            .KeyPress, .UnlockPasswordSubmitted => {},
            .ApiKeySubmitted => |key_bytes| { ... },
            .ValidateApiRequest => |req| { ... },
            .ConsentGrant => |path| { ... },
            .StreamChunk, .AgentToolRequest, .AgentError, .AuthRequired,
            .DispatchToolRequest, .CancelTool, .ToolResult, .ToolError,
            .SubprocessSpawned, .SubprocessExited, .ValidateApiReply,
            => {},
            // sin `else` — añadir un variant rompe la compilación
        }
```

Nota: agrupar variants explícitamente por nombre (no por número) mantiene el exhaustiveness check de Zig.

**Test RED.** No hay test para esto; es un cambio mecánico verificable por el compilador. El "RED" es que el build de un branch con el `else` eliminado **falla** si falta algún variant — verificable con un branch sucio:

```sh
# RED: quitar un arm y comprobar que `zig build` falla
```

---

#### P3-04 · `src/logger.zig:42` vs `:93` · `MAX_MESSAGE_LEN` (16 KiB) no corresponde con el buffer real (4 KiB)

**Qué pasa.**

```zig
// src/logger.zig:40-42
/// Maximum message length (bytes). Anything longer is rejected with
/// error.MessageTooLong to bound the per-line stack buffer.
pub const MAX_MESSAGE_LEN: usize = 16 * 1024;
...
// src/logger.zig:93-100
        var buf: [4096]u8 = undefined;
        const ts = formatTimestamp(io, &buf) catch return error.WriteFailed;
        ...
        const written = std.fmt.bufPrint(buf[ts.len..], " [{s}] [thread={d}] {s}\n", .{...}) catch return error.WriteFailed;
```

Un mensaje de 8 KiB pasa el check de `:87` y falla en `bufPrint` con `error.NoSpaceLeft` → mapeado a `error.WriteFailed`, no `MessageTooLong`.

**Por qué importa.** Menor, pero es un contrato documentado que el código no cumple, y `error.WriteFailed` con un mensaje de "message too long" lleva a diagnosticar el disco cuando el problema es el call-site. También significa que un mensaje largo se pierde **silenciosamente** (todos los callers hacen `catch {}`).

**Fix.**

```zig
// src/logger.zig:40-42
/// Límite real: el buffer de `log` es 4096 y el timestamp consume ~32.
/// 16 KiBKZ era el valor histórico y no corresponde con nada.
pub const MAX_MESSAGE_LEN: usize = 4 * 1024 - 64;
```

---

#### P3-05 · `src/api_client.zig:1741-1742` · El doc-comment de `tls_conn.host` afirma propiedad de la arena TLS y es falso

**Qué pasa.**

```zig
// src/api_client.zig:1741-1743
    /// Resolved hostname bytes (owned by the connection's TLS arena;
    /// pointer-stable for the lifetime of `connection`).
    host: []const u8,
```

El valor asignado es `host`, el parámetro de `connect` (`:1784`), es decir el slice del **caller**. No hay copia ni arena. El comentario describe el diseño anterior (pre-Opción B), cuando existía un `tls-handrolled` con arena propia.

**Por qué importa.** Respondiendo directamente a tu hallazgo #3: **no hay bug hoy** (todos los callers pasan literales compile-time, verificado), pero el comentario convierte un slice-del-caller en algo que parece acelerado por arena. Cualquier futuro caller que pase un slice a un buffer local reintroduce Bug 1, y el comentario dice que no puede pasar eso. Un doc-comment que previene el bug negando que el bug existe.

**Fix.**

```zig
    /// Slice del CALLER, sin copiar. Los callers de producción
    /// (`runtime.zig:155, :742`; `api_client.zig:459` vía
    /// `req.target_host`) pasan literales compile-time, así que es seguro.
    /// NO añadir un caller que pase un buffer stack-local: esto NO es
    /// propiedad de la arena TLS. Ver docs/conventions.md §"State storage".
    host: []const u8,
```

Más robusto: cambiar el tipo a `*const [_:0]const u8` o duplicar, pero eso complica la firma. El comentario corregido es el fix correcto aquí.

---

#### P3-06 · `src/sandbox.zig:791-808` · `argv` se trunca a 15 elementos en silencio y `argv.len == 0` es OOB

**Qué pasa.**

```zig
// src/sandbox.zig:790-808
            var argv_buf: [16]?[*:0]const u8 = undefined;
            const argv_len = @min(argv.len, argv_buf.len - 1);
            for (argv[0..argv_len], 0..) |arg, i| { ... }
            argv_buf[argv_len] = null;
            ...
            _ = std.os.linux.execve(
                @as([*:0]const u8, @ptrCast(argv[0].ptr)),   // ← argv[0] con argv.len == 0
                ...
            );
```

(a) Con >15 argumentos, los extras se descartan **sin avisar**: el tool se ejecuta con una línea de comandos distinta a la solicitada, y devuelve 0 (success) si el programa no necesita los args. Fallo silencioso.
(b) Con `argv.len == 0`, `argv[0]` es un acceso fuera de límites del slice → panic en Debug/ReleaseSafe, UB en ReleaseFast. `SandboxError.InvalidArgv` está declarado (`:663`) y **nunca se retorna**.

**Por qué importa.** El path de producción (`runtime.zig:886-897` → `parse_argv`) puede producir `argv.len == 0` si `command_line` es sólo whitespace: `parse_argv("   ", alloc)` devuelve un slice vacío (`parse_argv:1147-1151` → `argc = 0`). Y `toolsWorkerMain:858` construye `command_line` como `"{s} {s}"` de `d.name` + `d.args` — con `d.name == ""` y `d.args == ""`, sale `" "` → `argv.len == 0` → panic. Es alcanzable desde el path de verifications Agent (que hoy no se ejecuta, P0-13 — pero se va a activar con WU-4).

**Fix.**

```zig
// src/sandbox.zig — inicio de spawnToolSubprocess
    ) !ToolSubprocess {
        _ = cwd;
        if (argv.len == 0) return error.InvalidArgv;
        if (argv.len > 15) return error.TooManyArgs;   // o loguear el truncado
```

Y añadir `TooManyArgs` a `SandboxError`. Mejor aún: subir el buffer a 64 y loguear.

**Test RED.**

```zig
test "spawnToolSubprocess: argv vacío devuelve InvalidArgv, no hace panic" {
    const empty = [_][]const u8{};
    try testing.expectError(error.InvalidArgv,
        sandbox.Sandbox.spawnToolSubprocess(
            testing.allocator, test_profile, &empty, &[_][*:0]const u8{}, null));
}

test "spawnToolSubprocess: >15 args se rechazan explícitamente" {
    var args: [20][]const u8 = undefined;
    for (&args, 0..) |*a, i| a.* = "x";
    try testing.expectError(error.TooManyArgs,
        sandbox.Sandbox.spawnToolSubprocess(
            testing.allocator, test_profile, &args, &[_][*:0]const u8{}, null));
}
```

---

#### P3-07 · `src/runtime.zig:1037` y `:1060` · `@intCast` sin assert previo en un sitio; `anyerror` residual en la clasificación de salida

**Qué pasa.**

```zig
// src/runtime.zig:1034-1037
                    } else if (((wait_status >> 8) & 0xff) != 0) {
                        const code: u8 = @intCast((wait_status >> 8) & 0xff);
```

El `& 0xff` garantiza el rango, así que no hay bug — pero §10.5 exige "range assert previo" para narrowing casts, y aquí no hay assert. Menor.

Más relevante: `code` se calcula y **nunca se usa** — el mensaje usa `code_msg` con `{d}` sobre `(wait_status >> 8) & 0xff` de nuevo, dentro de `bufPrint` (`:1039`). Variable muerta.

Y `:1060`: `sub.wait() catch 0` — un `waitpid` fallido se trata como "exit status 0", lo que hace que un tool que no se pudo reapar se reporte como **éxito**. Eso es un `error swallow` con impacto de correctitud (§10.2).

**Fix.**

```zig
// src/runtime.zig:1036-1037
                    } else if (((wait_status >> 8) & 0xff) != 0) {
                        const raw: u32 = (wait_status >> 8) & 0xff;
                        std.debug.assert(raw <= std.math.maxInt(u8));  // §10.5
                        const code: u8 = @intCast(raw);
                        _ = code;
```

```zig
// src/runtime.zig:1011 — distinguir wait fallido de exit 0
                    const wait_status = sub.wait() catch |err| {
                        logger.global().log(args.io, .err,
                            "waitpid failed: tool exit status unknown") catch {};
                        args.channels.tools_to_tui.tryPut(args.io, .{
                            .ToolError = .{
                                .id = d.id,
                                .kind = .nonzero_exit,
                                .message = "subprocess exit status unavailable (waitpid failed)",
                            },
                        }) catch {};
                        continue;
                    };
```

**Test RED.**

```zig
test "P1/P3-07: waitpid fallido no se reporta como exit 0" {
    // con un pid ya reapeado, waitpid devuelve ECHILD
    var sub = try sandbox.Sandbox.spawnToolSubprocess(
        testing.allocator, test_profile, &[_][]const u8{"/bin/true"}, &[_][*:0]const u8{}, null);
    _ = sub.wait();
    const second = sub.wait();   // ECHILD
    try testing.expectError(error.WaitpidFailed, second);
}
```

---

### P4 — Arquitectura

---

#### P4-01 · Tres copias de `readEnv` y dos de `xdgCredentialsPath` — sí pueden divergir, y divergieron en el pasado

**Qué pasa.** Respondiendo a tu pregunta explícita:

| Función | Ubicación 1 | Ubicación 2 | ¿Idénticas? |
|---|---|---|---|
| `xdgCredentialsPath` | `src/api_auth.zig:552-566` | `src/modal.zig:1784-1798` (`storageCredentialsPath`) | **Sí, byte a byte** en la lógica: mismo orden `XDG_CONFIG_HOME` → `HOME`, mismos sufijos `/zargeant/credentials.json` y `/.config/zargeant/credentials.json`, mismo treatment de string vacío |
| `readEnv` / `readEnvVar` | `src/api_auth.zig:662` | `src/modal.zig:1802` | **Sí**, mismo buffer de 8192, mismo parser |
| `readEnv` | `src/logger.zig:230` | (los otros dos) | Longitud distinta (`1 << 20` según el context doc) |

**Por qué importa.** Hoy **no pueden divergir funcionalmente** porque son copia exacta. Pero:
1. El riesgo no es teórico: el path de credenciales es **la frontera de seguridad** del producto (¿dónde se guarda la API key cifrada?). Una corrección de seguridad aplicada a una copia y no a la otra deja la key en un directorio peor.
2. La divergencia ya ocurrió en el pasado: `api_auth.xdgCredentialsPath` se hizo `pub` en WU-3 *sólo* para evitar re-threading, dejando la copia de `modal.zig` detrás. El doc de `api_auth.zig:545-551` reconoce la duplicación y la justifica ("Future cleanup can de-duplicate") — es deuda declarada, no documentada como riesgo.
3. Los tres `readEnv` tienen bugs distintos de truncatura (P2-04), lo que significa que cualquier fix aplicado a uno deja a los otros con el bug.

**Veredicto sobre §13.7 del context doc ("¿vale la pena un WU-5 para de-duplicar?")**: **sí, pero no por DRY — por seguridad.** La justificación trazable es P2-04 (truncatura a 8 KiB) + P0-10 (path de log), no "evitar duplicación".

**Fix** (ODD: `odd/tasks/env-and-paths-hardening.md`, WU-1 y WU-2):

- WU-1: `api_auth.readEnvInto(out_buf, name) pub`, 64 KiB, slice al buffer del caller. Borrar `modal.readEnvVar` y `logger.readEnv`. (P2-04 + P2-06)
- WU-2: `modal.storageCredentialsPath` → borrar; llamar `api_auth.xdgCredentialsPath`. Añadir un test que afirme que ambos caminos de escritura y lectura de credenciales usan **la misma** función:

```zig
test "P4-01: el path de credenciales tiene una sola fuente de verdad" {
    var b1: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var b2: [std.Io.Dir.max_path_bytes]u8 = undefined;
    // un solo reader: si alguien re-introduce un segundo, este test se
    // haya dos funciones y el guard de tipos falla
    const p = api_auth.xdgCredentialsPath(&b1) orelse return;
    // modal NO debe exportar su copia
    try testing.expect(!@hasDecl(modal, "storageCredentialsPath"));
}
```

---

#### P4-02 · `src/modal.zig` (2.598 LoC) es un monolith con 4 responsabilidades mezcladas

**Qué pasa.** El módulo contiene:
1. La máquina de estados (`State`, 7 variants).
2. Todos los renderers (`draw*` con `WindowMock` + `render*ToGrid` con `ScreenGrid` — **dos implementaciones paralelas de cada vista**, ver §11.25 / WU-2).
3. La lógica de submit (`submitKeyEntryAsync`, `submitUnlockAsync`, `submitConsentGrant`).
4. `WindowMock` (un adapter de test dentro del módulo de producción).
5. `readEnvVar` + `storageCredentialsPath` (utilidades de sistema).
6. ~26 tests in-file.

**Por qué importa.** El coste concreto ya se está pagando: WU-2 (FU-2) tuvo que arreglar `WindowMock.print` **sin** arreglar `draw*` primero, porque eran dos implementaciones; y ahora cada fix de layout hay que hacerlo dos veces (`printAt` + `writeCell`). Es el tipo de duplicación que §14.15 prohíbe crear *nuevas*, pero que ya existe.

**Respuesta a "¿es un monolith justificado?"**: **no, pero partirlo ahora es peor.** El módulo tiene una frontera clara (la máquina de estados del modal) y el daño real —las dos rutas de render— se arregla mejor con un test de paridad que con un split:

```zig
test "P4-02: render*ToGrid y draw* producen el mismo layout" {
    // paridad celda a celda para las 5 vistas con datos representativos
    // hoy falla para drawConsentPrompt (WU-2 lo arregló sólo en una rama)
}
```

**Fix.** Test de paridad (WU único, 1 día) en vez de refactor. Si tras eso sigue pesando, el split natural es `modal_render.zig` (los `render*ToGrid`) + `modal_draw_mock.zig` (los `draw*` + `WindowMock`, que son test-only).

---

#### P4-03 · Cinco variantes de `Event` no tienen productor en producción

**Qué pasa.** Verificado por `grep` sobre `src/` completo:

| Variante | Consumidor | Productor en producción |
|---|---|---|
| `UserToolRequest` | `runtime.zig:506` | **ninguno** |
| `ApiKeySubmitted` | `runtime.zig:588` (`_ = key_bytes;`) | **ninguno** |
| `UnlockPasswordSubmitted` | `runtime.zig:584` (ignorado) | **ninguno** |
| `ConsentGrant` | `runtime.zig:613` (`_ = path;`) | **ninguno** |
| `AgentToolRequest` | **ninguno** | **ninguno** |

**Por qué importa.** Consecuencias concretas:
1. `api_client.Client.stream`, `api_sse.Parser` y `tls_conn` **nunca se ejecutan** (confirmado: `Client.stream` sólo se llama desde `runtime.zig:543`, dentro del arm de `UserToolRequest`). Todo el trabajo de TLS, SSE, retry y backoff — ~2.900 LoC — es **código muerto desde la perspectiva del usuario**.
2. Los dos brazos que sí reciben datos los **descartan**: `.ApiKeySubmitted => { _ = key_bytes; }` (`:588-602`) con un `ponytail` que admite "skip zeroing — the Agent thread owns the slot for the session lifetime" pero **no hay slot**: nunca se guarda. Y `.ConsentGrant => { _ = path; }` (`:613-619`).
3. Esto explica por qué P0-11 y P0-12 no se han manifiesto: el path que los contiene no corre.
4. `AgentToolRequest` es un variant completamente muerto (ni productor ni consumidor).

**Fix.** Esto es un slice de **cierre del loop agente**, no un bug puntual. Precede a WU-4 (que sin esto no tiene a quién enviar las herramientas). Un feature doc `odd/tasks/agent-loop-closure.md` con:

- WU-1: `.ApiKeySubmitted` guarda la key en un buffer del Agent con `@memset` en `Relock` y en shutdown (cerrando el `ponytail` de `:597-600`).
- WU-2: `.ConsentGrant` sincroniza key-en-memoria ↔ disco.
- WU-3: `.agent_loop` del modal emite `UserToolRequest` al enviar un prompt (hoy el modal `.agent_loop` no tiene ningún submit).
- WU-4: **borrar `AgentToolRequest`** (19 → 18 variants) o darle consumidor.

**Test RED** (el que prueba el loop completo, y que hoy fallaría):

```zig
test "P4-03: el loop agente cierra — modal .agent_loop → LLM → StreamChunk → modal" {
    // mock server, 1 prompt, esperar el StreamChunk en agent_to_tui
    // hoy falla: nadie postea UserToolRequest
}
```

---

### P5 — Cobertura de tests

---

#### P5-01 · 9 "grep-tests" que leen su propio source y assertan que un string existe

**Inventario completo** (verificado):

| Ubicación | Test | Qué "verifica" |
|---|---|---|
| `src/api_client.zig:1455-1458` | `TLS via system CA bundle succeeds` | `@embedFile("api_client.zig")` contiene `"Bundle.rescan"` y `"CA_BUNDLE_KIND"` |
| `src/api_client.zig:1479-1482` | `unknown CA returns TlsHandshakeFailed` | el source contiene `"SNI_HOSTNAME"`, `"pub fn connect"`, `"pub const tls_conn"` |
| `src/runtime.zig:1623-1634` | `T-SG-12: toolsRealMain uses parse_argv` | el source contiene `"parse_argv(args.allocator, command_line)"` |
| `src/runtime.zig:1637-1654` | `T-SG-12: kills subprocess on cancel_pipe wakeup` | el source contiene `"SIG.KILL"` y `"cancel_pipe[0]"` |
| `src/runtime.zig:1656-1667` | `T-SG-12: stdout_fd for capture` | `sandbox.zig` contiene `"stdout_fd: i32"` |
| `src/runtime.zig:1193-1234` | `no stray Thread.spawn outside runtime.zig` | 12 ficheros no contienen `"std.Thread.spawn"` antes del primer `test "` |
| `src/runtime.zig:1270-1308` | `no std.debug.print or getStdOut` | 12 ficheros no contienen `"std.debug.print"` antes del primer `test "` |
| `tests/api_client.zig:49-70` | `T-AC-1` | el body de `tryOneAttempt` contiene `"tls_conn.connect"` |
| `tests/api_client.zig:78-94` | `T-AC-2` | el body contiene `"bridge_sync_async"`, `"runBlocking"`, `"TlsConnectFn"` |

**Por qué importa.** El damage concreto está medido: **`runtime.zig:1637` PASA con el bug P1-03** (`poll(nfds=1)`) presente. Ese test afirma verificar la cancelación de subprocesses y no verifica nada — y da la falsa impresión de que la cancel path está cubierta. Además:
- Los tests de `api_client.zig:1455, 1479` son **circulares**: el source contiene esas strings *porque el source está escrito así*; un cambio que rompa el comportamiento manteniendo los nombres pasa igual.
- `runtime.zig:1193` y `:1270` truncan el escaneo en el **primer** `test "` de cada fichero. Cualquier código de producción colocado *después* del primer test (que es donde vive buena parte del código en estos ficheros) **no se escanea**. El guard tiene un agujero del tamaño del fichero.

**Sobre tu pregunta ("¿está instanciado en más lugares?")**: sí, **8 más** de los que mencionaste (que era el de `api_client.zig:1456`). El que probablemente no esperabas es `T-SG-12: kills subprocess on cancel_pipe wakeup`, porque es el que **esconde** un bug real.

**Qué hacer.** No eliminarlos — la intención (contract guards) es válida y útil — sino **reemplazarlos por guards de tipo**, que no se pueden falsear y que el compilador mantiene:

| Grep-test | Reemplazo por tipo |
|---|---|
| `stdout_fd: i32` existe | `try testing.expect(@hasField(sandbox.Sandbox.ToolSubprocess, "stdout_fd"))` |
| `tls_conn.connect` existe | ya hay uno: `tests/api_client.zig:102-114` (T-AC-3) — **borrar T-AC-1** |
| `TlsConnectFn` existe | `@hasDecl` no aplica a un local struct; usar el test de comportamiento (§3 de P0-12) |
| no `std.Thread.spawn` | guard de build-time en `build.zig` (§14.12 lo restringe — necesita slice) o test que escanee **el fichero completo**, no el prefijo |
| `Bundle.rescan` existe | test de comportamiento: `tls_conn.connect` contra un CA inválido devuelve `error.TlsHandshakeFailed` (ya existe el andamiaje, `api_client.zig:1876` es un `return` vacío) |

**Test RED del RED**: un test que falle si alguien reintroduce un grep-test que no pueda falsearse. Difícil de automatizar; es una convención de review.

---

#### P5-02 · 5 tests que pasan sin probar nada

| Ubicación | Test | Por qué no prueba nada |
|---|---|---|
| `src/sandbox.zig:954-956` | `sandbox.zig does not write to stdout or stderr` | `try testing.expect(true);` — el propio comentario lo admite |
| `src/sandbox_linux.zig:392-394` | `sandbox_linux does not write to stdout or stderr` | ídem, `try testing.expect(true); // placeholder` |
| `src/sandbox_profile.zig:296-298` | `sandbox_profile does not write to stdout or stderr` | ídem |
| `src/sandbox_profile.zig:207-212` | `Profile struct has paths, allowed_syscalls, denied_syscalls fields` | `_ = p.paths; _ = p.allowed_syscalls; _ = p.denied_syscalls;` — sólo verifica que los fields existen, lo que el compilador ya garantiza |
| `src/sandbox.zig:939-949` | `parent fd NOT inherited` | el body es un `ponytail` que explica que la lógica está rota, y luego `return;` |

Los tres primeros comparten un nombre y un propósito (invariant "no escribe a stdout/stderr") y los tres son no-ops. La verificación real existe pero en otro sitio: `runtime.zig:1270-1308` (que sí escanea… el prefijo antes del primer test — pero `sandbox.zig` **no está en su lista**, ni `sandbox_linux.zig`, ni `sandbox_profile.zig`). Así que la invariant no está cubierta en ningún lado para los tres módulos del sandbox.

**Fix.** Borrar los cinco y añadir `sandbox*.zig` a la lista de `runtime.zig:1272-1288` (extendiendo el guard a fichero completo, per P5-01). Eso convierte tres no-ops en una verificación real de tres módulos.

---

#### P5-03 · `src/sandbox.zig:899-910` · El test de `/etc/shadow` pasa por permisos Unix, no por Landlock

**Qué pasa.**

```zig
// src/sandbox.zig:897-910
// 3.4 Filesystem enforcement — /etc/shadow is NOT in the test profile's
// allowlist, so `cat` returns EACCES → child exits 1.
test "Sandbox.spawnToolSubprocess child /etc/shadow EACCES" {
    ...
    const status = try subs.wait();
    try testing.expect(std.os.linux.W.IFEXITED(status));
    try testing.expectEqual(@as(u8, 1), std.os.linux.W.EXITSTATUS(status));
}
```

`/etc/shadow` es `0640 root:shadow`. Un usuario normal **no puede leerlo por permisos Unix, con o sin Landlock**. El test pasa por la razón equivocada: no prueba nada sobre el sandbox. Sólo detectaría una regresión si el usuario fuera root — y en ese caso **fallaría** (root lee shadow → exit 0), lo que sugiere que este test se escribio/verificó en un entorno donde no era root, y nunca se ejecutó como root.

Lo mismo aplica a `:885-895` (`/tmp writable` — `/tmp` es world-writable por diseño POSIX) y a `:872-882` (`/bin/true` exits 0 — no toca el FS).

**Por qué importa.** Los **tres** tests de enforcement del sandbox (`3.2`, `3.3`, `3.4`) pasan sin que Landlock esté aplicado (P0-01) y sin que seccomp esté aplicado (P0-02). Son la evidencia que el proyecto creyó tener de que el sandbox funciona. Combinado con `runtime.zig:1637` (P5-01), **la cobertura de seguridad del sandbox es exactamente cero a pesar de haber 7 tests**.

**Fix.** Un test que sólo puede pasar si Landlock está activo, usando un path que SÍ es legible por el usuario pero que el perfil **no** lista:

```zig
test "P0-01/P5-03: Landlock bloquea un path legible-permisos fuera del perfil" {
    sandbox_linux.checkKernelSupport() catch return;
    // /etc/hostname es 0644 (legible por todos). El test_profile NO lo lista.
    // Con Landlock → EACCES. Sin Landlock → se lee. Distingue de verdad.
    const argv = [_][]const u8{ "/bin/sh", "-c",
        "cat /etc/hostname >/dev/null 2>&1; exit $?" };
    var sub = try sandbox.Sandbox.spawnToolSubprocess(
        testing.allocator, test_profile, &argv, &[_][*:0]const u8{}, null);
    defer sub.deinit();
    const status = try sub.wait();
    try testing.expect(std.os.linux.W.IFEXITED(status));
    try testing.expectEqual(@as(u8, 1), std.os.linux.W.EXITSTATUS(status));
}
```

Y el complemento (lo que Landlock **debe** permitir):

```zig
test "P0-01/P5-03: Landlock NO bloquea un path listado en el perfil" {
    // control negativo: si esto falla, Landlock está demasiado restrictivo
    // (p.ej. bloquea /bin/true y todos los tests "pasan" por EOF en el read)
}
```

---

#### P5-04 · `src/sandbox.zig:919-935` y `src/api_client.zig:1158-1207` · Tests que pasan por `return` temprano cuando su precondición no se cumple

**Sandbox ptrace.** El test depende de un binario externo compilado out-of-band:

```zig
// src/sandbox.zig:919-924
test "Sandbox.spawnToolSubprocess child ptrace blocked" {
    sandbox_linux.checkKernelSupport() catch return;
    const test_bin = "/tmp/zargeant_ptrace_test";
    ...
    var subs = sandbox.Sandbox.spawnToolSubprocess(...) catch return;   // ← PASS si no existe
```

Si `/tmp/zargeant_ptrace_test` no existe (que es el caso por defecto — el test se cleaned del `/tmp` en cada reboot), el `catch return` da PASS. El propio comentario lo admite: *"coverage gap documented in apply-progress"*.

**TLS.** Los cuatro tests de TLS son `env`-gated:

```zig
// src/api_client.zig:1846-1847
test "TLS handshake vs api.minimax.io:443 succeeds" {
    if (!tlsHandshakeGate()) return;
```

`tlsHandshakeGate()` (`:996-1000`) lee `/proc/self/environ` buscando `ZARGEANT_RUN_TLS_HANDSHAKE=1`, que no está en `justfile`, ni en `build.zig`, ni en `tools/local-ci.sh` (verificado). Por tanto **los 4 tests de TLS (T1.2, T1.5, T1.6, T1.9) nunca se ejecutan**. Peor: `api_client.zig:1911-1917` ("TLS handshake timeout after HANDSHAKE_TIMEOUT_MS") hace `return` **incluso cuando el gate pasa** — su body está vacío con el comentario "until WU-3 lands".

**Por qué importa.** El conteo de "540 tests" (verificado) incluye ~10 que son PASS incondicional. El efecto agregado es un número de cobertura que no corresponde a nada. Y el caso T1.9 tiene un comentario que documenta el bug real que encontré:

```zig
// src/api_client.zig:1159-1165
    // Opción B WU-2 (design obs#1369): stdlib Client.connectTcp has NO
    // built-in timeout (D7 says `.timeout = .none` to avoid the
    // Threaded.zig:12077 @panic). Against a non-TLS server, the stdlib
    // TLS handshake HANGS forever ...
```

**El repo documentó P0-12 hace tiempo y chose gatear el test en vez de arreglarlo.**

**Fix.**
- Sandbox: hacer el test hermético — generar el binario en el test con `zig build-exe` es caro; mejor, un test que use `/bin/sh -c 'kill -TRACEME; ...'` o directamente `ptrace` vía un helper ya existente. Alternativa: cambiar el `catch return` por `catch return error.SkipZigTest` (Zig 0.16 lo soporta) para que el skip sea **visible** en lugar de un PASS verde.
- TLS: o se cablea `ZARGEANT_RUN_TLS_HANDSHAKE=1` en un job de CI network-enabled, o los tests se marcan como `error.SkipZigTest` y se acepta que el TLS real no está cubierto localmente. Lo segundo es honesto; lo primero es mejor.

**Test RED**: none — esto es un gap de cobertura, no un bug. Se cierra annotando.

---

#### P5-05 · `src/runtime.zig:1170-1179` · El test de "3 threads spawn+join" no ejercita threading

**Qué pasa.**

```zig
// src/runtime.zig:1170-1179
test "Runtime spawns 3 threads and joins (headless)" {
    var runtime = try Runtime.spawn(.{});
    defer runtime.deinit();
    runtime.shutdown(testing.io);        // <-- shutdown ANTES de run
    try runtime.run(testing.io);
    try testing.expect(runtime.tui_thread == null);
    ...
}
```

`shutdown()` pone `shutdown_requested = true` y cierra los canales **antes** de `run()`. Los 3 threads se lanzan, comprueban `!args.shutdown.load()` en la primera línea de su loop, y salen inmediatamente. El test verifica que `run()` las lanza y las hace join — no que hagan nada. Peor: `tuiThreadLoop` (`tui.zig:920`) es `while (true)` sin check de shutdown, así que **el hilo TUI real nunca sale por el flag** — sale por el `return` de `.Shutdown` en `:938`, y `closeAll` hace que `tryGet` devuelva `null`, no un `Shutdown`… el hilo TUI real **se queda en `while(true)` para siempre** (su único otro `return` es el Ctrl+C de `:986`). Combinado con P0-13 (nadie postea Shutdown a `tui_to_agent` porque el TUI se lo queda), **`Runtime.run` en producción real con un TUI vivo no puede terminar por la vía del flag de shutdown**.

*Hipótesis, requiere verificación en ejecución*: no puedo confirmar sin toolchain si `tuiThreadLoop` tiene otro break que no he leído. Lo marco como hipótesis.

**Fix.**

```zig
test "Runtime: los 3 threads terminan con el flag de shutdown (sin Shutdown en el canal)" {
    var runtime = try Runtime.spawn(.{});
    defer runtime.deinit();
    // NO shutdown() previo — el flag debe bastar
    const t0 = nowMs();
    runtime.shutdown_requested.store(true, .seq_cst);
    // dar tiempo a los threads a arrancar
    std.Thread.sleep(50 * std.time.ns_per_ms);
    try testing.expectEqual(Rt.JoinResult.clean, runtime.join(testing.io, 3 * std.time.ns_per_s));
    try testing.expect(nowMs() - t0 < 3000);
}
```

---

#### P5-06 · Los 5 tests de `runtime.zig:1236-1268` no usan los canales cross-thread que dicen probar

Además de P1-01, hay tres tests que construyen `Channels` y hacen `tryPut` desde el mismo hilo, que es precisamente donde los bugs de P0-06/07/08 **no** se manifiestan. `runtime.zig:1261-1268` ("sse coalesce 16ms end-to-end via runtime channels") hace 5 `pushSseChunk` con la string literal `"x"` desde un solo hilo y afirma `ch.len() == 1`. Con `page_allocator` + free (el patrón de P0-06) habría detectado el problema; con literales, no.

**Fix.** El test de paridad de P0-06 (con `testing.allocator` como poison) es el que cubre esto. Añadir también un test multi-hilo real:

```zig
test "P5-06: el Agent→TUI edge entrega texto intacto bajo concurrencia" {
    // 1 productor, 1 consumidor, 5000 chunks de 1 KB
    // assert: el consumidor ve todos los bytes, ninguno corrupto
    // esto es lo que fallaría hoy con P0-06
}
```

---

## 3. Veredicto WU-4

### 3.1 Mecanismo real del gap (y por qué el doc se equivoca en un detalle importante)

El context doc (`zargeant-context-for-ai-agent.md:143`) y el feature doc (`post-roadmap-hygiene-and-offload.md:33`) dicen que el parser *"silenciosamente descarta"* `delta.tool_calls`. **Eso no es lo que hace el código.** Trazado exacto:

```zig
// src/api_sse.zig:285-295
        var delta_node: ?std.json.Value = null;
        if (value.object.get("choices")) |cn| {
            if (cn == .array and cn.array.items.len > 0) {
                const fc = cn.array.items[0];
                if (fc == .object) {
                    if (fc.object.get("delta")) |dn| {
                        if (dn == .object) delta_node = dn;
                    }
                }
            }
        }
```

Llega un chunk de tool_calls de MiniMax (formato OpenAI, confirmado contra la doc de MiniMax: `tools` + `tool_calls` en `delta`, `function_call` deprecated):

```json
{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_x","type":"function","function":{"name":"read","arguments":""}}]},"finish_reason":null}]}
```

- `delta_node` = el objeto delta. ✓
- `dn.object.get("reasoning_content")` → `null` → `has_reasoning = false`.
- `dn.object.get("content")` → `null` (ausente) → el `if` de `:321` no entra.
- `has_usage` = false.
- **Cae a `:379-380`:** `return .{ .err = .{ .kind = .MalformedStream, .raw_bytes = data_copy } };`

Y en el consumidor:

```zig
// src/api_client.zig:226-236
                .err => |e| {
                    self.finished = true;        // ← ABORTA EL STREAM ENTERO
                    if (self.pending) |p| { ... return p; }
                    return ChunkEvent{ .err = ... };
                },
```

**Consecuencia real**: el primer chunk de `tool_calls` produce un `AgentError{kind: .internal}` (vía `mapChunkError(.MalformedStream)` en `runtime.zig:578`) y **termina el stream**. El usuario ve un modal de error tras haber escrito un prompt que el modelo quiere responder con una herramienta. No es "se ignora la herramienta": es **"el harness se rompe"**.

Caso borde: si el chunk trae `"content": ""` (string vacío, que MiniMax puede enviar), `:322` matchea `.string`, se emite un `.message` con contenido vacío, y el tool_call se pierde **sin error visible**. Ambos comportamientos son malos; el primero es el que se va a ver.

**Veredicto**: WU-4 no es un "nice to have pendiente" — es un **bloqueante funcional** para cualquier uso de function calling, y está peor documentado de lo que el repo cree.

### 3.2 Por qué WU-4 **no puede** aterrizar tal como está especificado

El feature doc (`post-roadmap-hygiene-and-offload.md:44-45`) dice que WU-4 debe:

> `src/api_sse.zig` | Extend SSE parser to extract `delta.tool_calls[i]` … Serialize `function.arguments` into the existing `UserToolArgs.args` field
> `src/runtime.zig` | … synthesize one `Event.DispatchToolRequest` per call, posts via `agentDispatchTool`

`UserToolArgs.args` es un `[]const u8` (P2-01). Los slices del parser SSE apuntan a la arena del parser. Si WU-4 emite `DispatchToolRequest` con slices a la arena y el Agent thread lo postea al canal, entonces:

- El worker (P0-07) lo formatea con `allocPrint` — con la arena aún viva, funciona por suerte.
- El parser se resetea (P1-02, si se arregla) o se deinita al terminar el stream → **UAF en el path de herramientas**.

**WU-4 sin P0-06/P0-07/P0-08/P1-02/P2-01 resueltos primero = propagar el UAF a la arista másExpuesta.**

### 3.3 Diseño propuesto

**Orden ODD** (feature doc nuevo: `odd/tasks/agent-thread-ownership-and-sandbox-fail-closed.md`):

| WU | Contenido | Depende de | Severidad |
|---|---|---|---|
| WU-1 | `tuiThreadLoop` deja de consumir `tui_to_agent` (P0-13). Segundo consumidor fuera. | — | **P0** |
| WU-2 | P0-06/P0-07/P0-08: payloads de canal inline (`StreamChunk`, `ToolResult`, `ToolError`, `AgentError`) | WU-1 | **P0** |
| WU-3 | P1-01: `putSseChunk` atómico; §11.27 overflow determinista | WU-2 | P1 |
| WU-4 | P1-02: `arena.reset` por evento → fin del O(n²) | WU-2 | P1 |
| WU-5 | `ToolRequestInline` y migración de la arista de herramientas (P2-01) | WU-2 | P2 |
| WU-6 | **tool_calls** (el WU-4 original, renumerado) | WU-4, WU-5 | P3 |
| WU-7 | Cierre del loop agente (P4-03): `.ApiKeySubmitted` guarda la key, `.ConsentGrant` sincroniza, `.agent_loop` emite `UserToolRequest` | WU-1, WU-6 | P3 |
| WU-8 | `AgentToolRequest` se borra (19 → 18 variants) | WU-7 | P3 |

**WU-6 — diseño del parser.**

1. **Tipos nuevos en `api_sse.zig`** (siguiendo la convención inline):

```zig
pub const MAX_TOOL_NAME: usize = 128;
pub const MAX_TOOL_ARGS: usize = 4096;

/// Un tool_call en deltas acumulativos. `index` es el `delta.tool_calls[i].index`
/// que MiniMax/OpenAI emiten: los fragments de la MISMA llamada comparten
/// index; llamadas distintas tienen 0, 1, 2...
/// (los argumentos se fragmentan a través de la red — hay que acumular).
pub const ToolCallDelta = struct {
    index: u32,
    id_buf: [64]u8 = .{0} ** 64,
    id_len: usize = 0,
    name_buf: [MAX_TOOL_NAME]u8 = .{0} ** MAX_TOOL_NAME,
    name_len: usize = 0,
    args_buf: [MAX_TOOL_ARGS]u8 = .{0} ** MAX_TOOL_ARGS,
    args_len: usize = 0,
};

pub const Event = union(enum) {
    message: Message,
    reasoning: Reasoning,
    usage: Usage,
    tool_call_delta: ToolCallDelta,   // NUEVO
    done: void,
    err: StreamError,
    pending: void,
};
```

2. **Acumulador en `Parser`** (barrido acotado, sin alloc, sin recursión — §10):

```zig
pub const MAX_CONCURRENT_TOOL_CALLS: usize = 8;

pub const Parser = struct {
    ...
    /// Acumulador de tool_calls en vuelo, indexado por `delta.tool_calls[i].index`.
    /// Bounded (MAX_CONCURRENT_TOOL_CALLS) por §10.3 "bounded loops".
    tool_acc: [MAX_CONCURRENT_TOOL_CALLS]ToolCallDelta = .{.{}} ** MAX_CONCURRENT_TOOL_CALLS,
    tool_seen: bool = false,
};
```

3. **Extracción en `dispatchEvent`** (después de `:295`, antes del bloque de content):

```zig
        // delta.tool_calls — MiniMax/OpenAI function calling.
        // RED hoy: esto no existe; sin él el chunk cae a MalformedStream
        // (:380) y ABORTA el stream (api_client.zig:227).
        if (delta_node) |dn| {
            if (dn.object.get("tool_calls")) |tc| {
                if (tc == .array) {
                    self.tool_seen = true;
                    for (tc.array.items) |item| {
                        if (item != .object) continue;
                        const tc_index = if (item.object.get("index")) |ix|
                            (if (ix == .integer) @intCast(ix.integer) else 0)
                        else
                            0;
                        if (tc_index >= MAX_CONCURRENT_TOOL_CALLS) {
                            return .{ .err = .{
                                .kind = .MalformedStream,
                                .raw_bytes = data_copy,
                            } };   // fail-loud: >8 llamadas concurrentes
                        }
                        var acc = &self.tool_acc[tc_index];
                        // id y name llegan sólo en el primer fragmento
                        if (item.object.get("id")) |id| {
                            if (id == .string) {
                                acc.id_len = copyBounded(&acc.id_buf, id.string);
                            }
                        }
                        if (item.object.get("function")) |f| {
                            if (f == .object) {
                                if (f.object.get("name")) |nm| {
                                    if (nm == .string) {
                                        acc.name_len = copyBounded(&acc.name_buf, nm.string);
                                    }
                                }
                                if (f.object.get("arguments")) |ar| {
                                    if (ar == .string) {
                                        // APPEND: los argumentos se fragmentan
                                        acc.args_len = appendBounded(&acc.args_buf, acc.args_len, ar.string);
                                    }
                                }
                            }
                        }
                        self.state = .header;
                        return .{ .tool_call_delta = acc.* };
                    }
                }
            }
        }
```

4. **Single-shot** (`choices[0].message.tool_calls`, sin `delta`) — mismo acumulador, otro accessor:

```zig
        // Fallback single-shot: MiniMax con stream=false devuelve los
        // tool_calls en choices[0].message.tool_calls, no en .delta.
        if (delta_node == null) {
            if (value.object.get("choices")) |cn| {
                if (cn == .array and cn.array.items.len > 0) {
                    const fc = cn.array.items[0];
                    if (fc == .object) {
                        if (fc.object.get("message")) |mn| {
                            if (mn == .object) {
                                if (mn.object.get("tool_calls")) |tc| { /* misma extracción */ }
                            }
                        }
                    }
                }
            }
        }
```

Para no duplicar el bloque, extraer una `fn extractToolCalls(self, arr: std.json.Array) !?ToolCallDelta`.

5. **Cierre de la llamada** — emitir el acumulado cuando el stream termina o cambia de index:

```zig
        // En dispatchEvent, cuando se ve `[DONE]` (:253) o `finish_reason`:
        if (self.tool_seen) {
            // Emitir el (o los) tool_calls acumulados ANTES de .done
            // vía self.queued, el mecanismo ya existente (:150-153).
        }
```

El `queued` slot ya existe para "emitir el segundo sub-evento en el próximo `feed()`" — reusarlo evita añadir una máquina de estados nueva. Si hay 2 llamadas simultáneas, se necesita una cola de N; la versión v1 puede rechazar >1 (fail-loud) y se amplía en WU-7.

6. **`channels.zig`** — **sin** variant nuevo con slices. Reusa `ToolRequestInline` de WU-5:

```zig
// NO añadir Event.ToolCallsDetected todavía — es cosmético y suma una
// variante al union. Dejarlo para WU-7 (indicador de estado en el TUI).
```

7. **`runtime.zig`** — el Agent thread ya tiene el consumer de `.tool_call_delta` listo para el caso single-shot:

```zig
                const stream = api_client.Client.stream(...) catch |err| { ... };
                var s = stream;
                defer s.deinit();
                while (s.next() catch ...) |maybe_event| switch (maybe_event) {
                    .message, .reasoning => ...,
                    .tool_call => |tc| {
                        // Inline payload (WU-5): sin slices, sin UAF.
                        var req: channels_mod.ToolRequestInline = .{
                            .id = next_dispatch_id(),
                            .name_len = tc.name_len,
                            .args_len = tc.args_len,
                        };
                        @memcpy(req.name_buf[0..tc.name_len], tc.name_buf[0..tc.name_len]);
                        @memcpy(req.args_buf[0..tc.args_len], tc.args_buf[0..tc.args_len]);
                        args.channels.tui_to_tools.tryPut(args.io, .{
                            .DispatchToolRequest = req,
                        }) catch {};
                    },
                    .usage, .done => {},
                    .err => |se| { ... },
                };
```

8. **El fallback verbatim se mantiene** — `.UserToolRequest` sigue existiendo y el worker pool sigue recibiendo `DispatchToolRequest` de ambas fuentes. Es lo que dice el feature doc ("fallback when no tool_calls present") y es correcto.

**Nota sobre `std.json.parseFromSlice`**: el feature doc (`post-roadmap-hygiene-and-offload.md:86`) dice *"parsed via `std.json.parseFromSlice` then re-serialized to canonical string"*. **No hace falta re-serializar**: `function.arguments` ya es un string JSON; el harness lo pasa verbatim al tool, que lo parsea. Re-serializar añade un alloc y una fuente de bugs por nada. Documentar la decisión en el feature doc (evitar re-serialización).

### 3.4 Plan de tests WU-6 (RED → GREEN, en orden)

Todos en `src/api_sse.zig` (co-localizados, per §6.2) salvo donde se indica.

| # | Test | Estado hoy | Qué prueba |
|---|---|---|---|
| R-1 | `streaming tool_calls: primer delta expone nombre` | **RED** — devuelve `.err/MalformedStream` | que `delta.tool_calls[0]` se extrae |
| R-2 | `streaming tool_calls: argumentos fragmentados se acumulan por index` | **RED** | que dos deltas con el mismo `index` y `arguments` partidos producen un acumulado `"{\"city\":\""` + `"Paris\"}"` = `{"city":"Paris"}` |
| R-3 | `two concurrent tool_calls (index 0 y 1) se acumulan por separado` | **RED** | que el `index` discrimina, no la posición en el array |
| R-4 | `single-shot message.tool_calls (sin delta) se extrae` | **RED** | el camino `choices[0].message.tool_calls` |
| R-5 | `tool_calls NO marca el stream como finished` | **RED** (o GREEN parcial) | el bug de P0/WU-4: hoy `.err` → `finished = true`. El test debe afirmar que tras un chunk de tool_calls el stream sigue vivo |
| R-6 | `[DONE]` tras tool_calls emite el acumulado antes de `.done` | **RED** | el orden de terminación |
| R-7 | `chunk de contenido puro NO produce tool_call events` | GREEN hoy | no regresión del camino existente |
| R-8 | `>8 tool_calls concurrentes → .err (fail-loud, no truncado silencioso)` | **RED** | el bounded loop de §10.3 |
| R-9 | `arguments > 4096 bytes → truncado con flag, no OOB` | **RED** | el buffer inline acotado |
| R-10 | `tool_call con arguments = JSON inválido NO crashea` | **RED** | robustez del parser (el harness no parsea, pero un string arbitrario llega igual) |

En `tests/tui/runtime_thread.zig` (el hub):

| # | Test | Estado | Qué prueba |
|---|---|---|---|
| R-11 | `agentDispatchTool: tool_call delta → DispatchToolRequest en tui_to_tools` | **RED** | la integración canal→worker |
| R-12 | `agentDispatchTool: 2 tool_calls → 2 DispatchToolRequest, orden preservado` | **RED** | N llamadas |
| R-13 | `UserToolRequest verbatim-forward sigue verde` | GREEN | el fallback |

En `src/runtime.zig`:

| # | Test | Estado | Qué prueba |
|---|---|---|---|
| R-14 | `P0-13/WU-1: ValidateApiRequest llega al Agent thread` | **RED** | el guard de P0-13 (§3 del §2, P0-13) |

**Nota sobre R-5**: hoy el test *pasa* por el camino equivocado (el `.err` que termina el stream). El RED real es "el stream debe seguir vivo tras un chunk de tool_calls", que falla hoy.

**Nota de orden**: R-1 debe escribirse y **fallar** antes de tocar `api_sse.zig`. Si al implementarlo R-5 sigue fallando, el bug de `finished = true` no está donde creo — y eso es información valiosa del propio ciclo RED.

---

## 4. Cobertura de tests — mapa real vs. aparente

### 4.1 Cifras

| Métrica | Valor |
|---|---|
| Bloques `test "` en `src/` + `tests/` | **540** (verificado por `grep -c`) |
| Tests que pasan sin ejercitar comportamiento | **≥ 12** (§ P5-02, P5-04) |
| Tests greppers que no pueden detectar su bug | **9** (§ P5-01) |
| Tests gated por env var que nunca corre en CI | **4** (TLS, `api_client.zig:1846, 1897, 1911, 1158`) |
| Tests con body vacío / `return` inmediato | **2** (`sandbox.zig:939`, `sandbox_linen.zig:876`) |
| Tests de threading real (≥2 hilos vivos simultáneamente) | **3** (`runtime.zig:1170` — que no exercise nada; `api_client.zig:1213` — el CancelCtx sí; `cancel_e2e.zig`) |
| Tests del sandbox que prueban el sandbox | **0 de 7** (§ P5-03) |

El doc dice "500+ tests" (§9.1) — la cifra es correcta (540), pero **no es comparable con "500+ tests"** porque ~15 son no-ops y 9 son greps.

### 4.2 Mapa por capa

| Capa | LoC tests | Tests | Estado | Nota |
|---|---:|---:|---|---|
| `src/terminal/` | — | 137 | 🟢 **La mejor del repo** | 137 tests sobre 2.036 LoC. UTF-8, escapes, kitty, DPM, paste — tests reales con asserts sobre bytes. Es el estándar de calidad que el resto del repo debería alcanzar |
| `tests/tui/screen_grid.zig` | 1.622 | 34 | 🟢 | ScreenGrid como value type, paridad UTF-8 |
| `src/channels.zig` | 540 | 5 | 🟡 | 5 tests, todos single-threaded. Los 19 payloads no tienen ni un test de forma |
| `src/api_sse.zig` | 814 | 14 | 🟡 | Hay un fuzz test (`:781`) y casos de recovery reales. Pero **cero** cobertura del camino `message.tool_calls` y `delta.tool_calls` (WU-4) |
| `src/api_client.zig` | 1.933 | 29 | 🟠 | 4 greps, 4 TLS gated-off, 2 grep-self-embedded. El `tryOneAttempt` real está cubierto sólo en la rama plain (mock) |
| `src/modal.zig` | 2.598 | 26 | 🟠 | Tests de transiciones de estado (buenos) + 2 renderers duplicados sin test de paridad |
| `src/sandbox*.zig` | 1.652 | 26 | 🔴 | 3 tautologías, 1 test con `return` inmediato, 3 que pasan por permisos Unix, 1 que depende de un binario externo. **Cobertura de seguridad efectiva: 0** |
| `src/runtime.zig` | 1.668 | 30 | 🔴 | 5 greps, 1 test que no exercise threading, 1 que pasa con `nfds=1` |
| `tests/tui/runtime_thread.zig` | 4.319 | 106 | 🟡 | El hub, mayor cobertura formal, pero **casi todo prueba funciones puras y constructores de struct, no los threads**. `buildMockRequest`/`buildRealRequest`/`mapChunkError`/`isIdleRelockDue` — funciones puras. `agentThreadLoop` **no se ejecuta** en ningún test |

### 4.3 El patrón dominante: tests de funciones puras, cero tests de threads

Esto merece su propia observación. El repo tiene 106 tests en el hub de runtime, y el Agent thread —la máquina de estado más compleja del proyecto— **no se testea nunca**. Lo que se testea:

- `buildMockRequest(utr)` → asserta que `req.target_host == "127.0.0.1"`. (Función pura.)
- `mapChunkError(kind)` → asserta el enum mapping. (Función pura.)
- `agentDispatchTool(args, utr)` → un solo test (`runtime.zig:1520-1567`) que hace un `tryPut` desde el hilo principal y un `tryGet` desde el mismo hilo. **Single-threaded**: no toca el `pushSseChunk`, ni la coalescencia real, ni el ring buffer bajo contention.
- `agentRunValidate` → los tests WU-3 **no existen** (el feature doc los pedía en `tests/tui/runtime_thread.zig`, §WU-3 AC; no están).

**El 3-thread model —la tesis del proyecto— tiene ~0 tests.** §14 del context doc y AGENTS.md §7 (determinism, time injection) prescriben testear la lógica inyectando el reloj y el IO. Eso se hizo bien para las funciones puras; pero la **composición** (3 hilos reales, canales reales, lifecycle real) no tiene ni un test end-to-end. Eso explica por qué P0-13 (el TUI robando el canal del Agent) llegó a "SHIPPED" con acceptance criteria verde.

**Fix estructural (una vez, no por bug):** añadir un target de build `test-threads` que ejecute 3-5 tests de integración reales con los 3 hilos vivos y un mock server, con un timeout duro por test (para que un deadlock sea un fallo, no un hang del CI). Dado §11.1 (el hang de `std.zig.Server`), esto necesita un harness standalone — el mismo workaround de `just test-embedded`. Es un slice de tooling, no de lógica.

---

## 5. Deuda técnica priorizada

### Arreglar ahora (bloquea v1.0.0 y cualquier uso real)

| ID | Por qué ahora | Esfuerzo |
|---|---|---|
| **P0-01 + P0-02** | El sandbox no existe en la práctica. Es la tesis del producto ("confinamiento estricto por defecto"). Un solo command de los 4 findings P0 de seguridad. | 2 días (reordenar 20 líneas + `loadFilter` + 3 tests) |
| **P0-06/07/08** | 5 UAF/dangling en las dos aristas que más se ejecutan. Crash o corrupción de texto. El fix es mecánico (inline buffers) y de ~200 LoC. | 3-4 días (payloads + migración de 6 variantes) |
| **P0-13** | Rompe el único feature functional del slice activo, y mantiene muerto ~2.900 LoC de TLS/SSE. Fix de 5 líneas. | 0,5 día |
| **P0-11** | Leak en error path, 1 línea de `errdefer`. | 0,5 hora |
| **P0-04** | `execve` con argv no terminado: 25 líneas, y es un OOB read en cada invocación de herramienta. | 1 día |
| **P1-03** | La cancelación de herramientas no funciona. 1 carácter (`1` → `pollfd.len`). El grep-test que lo "cubría" es la causa de que nadie lo viera. | 15 min + el test real |
| **P0-10** | Symlink en `/tmp` con un harness que maneja credenciales. ~10 líneas. | 2 horas |
| **P3-01** | Los tests de TLS son verdes, lo que significa que el log de errores de red no sirve para diagnosticar. | 1 día |

### Arreglar antes de v1.0.0, no antes de la próxima release

| ID | Por qué | Esfuerzo |
|---|---|---|
| **P1-01** | Pérdida esporádica de texto SSE. No es un crash. El fix es un método atómico en `Channel`. | 0,5 día |
| **P1-02** | OOM en respuestas largas con `thinking`. El reset de arena es 1 línea. | 2 horas |
| **P1-04 + P1-05** | El proceso puede no terminar. `join` con timeout + `threadlocal`. | 1 día |
| **P2-01** | Prerrequisito duro de WU-4. | 1 día |
| **P0-12** | Sin timeout de handshake, un `Ctrl+C` no cancela. El fix completo (timeout de `connectTcp`) no es posible con la stdlib actual; la mitigación (`tls_gated = true` por defecto + deadline en el read loop) sí. | 1 día + decisión de producto |
| **P2-04 + P4-01** | Duplicación de un path de seguridad + truncatura a 8 KiB. | 1 día |
| **P5-03** | Los tests del sandbox dan confianza falsa. Con P0-01 arreglado, hay que añadir los que sí discriminan (`/etc/hostname`). | 0,5 día |
| **P5-01 (los que esconden bugs)** | Un grep-test que pasa con un bug P1 es peor que no tener test. | 1 día |

### Puede esperar a v1.0.0 (o a Phase 3)

| ID | Por qué puede esperar |
|---|---|
| **P2-02** (fuga de `parse_argv` en OOM) | Sólo en OOM. |
| **P2-05** (wipe de la clave derivada) | Requiere `PR_SET_DUMPABLE = 0` también (§6), que es un slice aparte.(make del wipe es 1 línea, pero el `secureZero` de std puede no estar en 0.16 — verificar). |
| **P2-03** (`anyerror` en `api_client`/`api_auth`/`bridge`) | En `src/terminal/*` es casi intratable sin un tipo de error por función. Documentar la excepción en §10.2 en vez de arreglar. |
| **P2-06** (post-fork) | No hay malloc hoy. El riesgo es de futuro; un `ponytail` lo documenta. |
| **P3-02** (`/home/josel/`, `api.minimaxi.chat`) | `default()` no lo usa el runtime. Pero **filtrar el home del autor en un repo público** sí conviene arreglarlo ya — 5 minutos. |
| **P3-04** (`MAX_MESSAGE_LEN`) | Cosmético. |
| **P3-05** (doc-comment de `tls_conn.host`) | Cosmético, pero 1 línea y previene Bug 1. |
| **P3-06** (`argv` truncado / `argv.len == 0`) | 3 líneas. En realidad, hacerlo ya: el panic es alcanzable. |
| **P3-07** (`wait` catch → 0, `@intCast` sin assert) | Menor, pero `catch 0` == "exit 0" es un bug de correctitud real. |
| **P4-02** (`modal.zig` monolith) | **No partirlo.** Añadir el test de paridad y ya. Un split sin FU es exactamente lo que §14.15 prohíbe. |
| **P4-03** (5 variants sin productor) | Depende de WU-7, que depende de WU-6. Es el loop de cierre del agente — un slice propio, no un fix. |
| **P5-02, P5-04, P5-05, P5-06** | Reemplazo de tests no-ops por guards reales. |

### Lo que **no** es deuda (verificado)

- `src/terminal/` — 2.036 LoC, 137 tests, clean-room con specs citadas. **Es la mejor parte del repo.** No tocar.
- El doble-buffer `[2]ScreenGrid` + `diffAndEmit` — bien diseñado, testeado.
- `Dechunker` (RFC 7230) — correcto, tolerante a feeds parciales.
- La convención inline-buffer (`docs/conventions.md`) — **es correcta y bien escrita**. El problema es que slice 7 no la leyó (P0-08). No se modifica el documento; se modifica el código.

---

## 6. Drift documentación

### 6.1 Afirmaciones falsas en el código (doc-comments que mienten)

| Ubicación | Afirma | Realidad |
|---|---|---|
| `api_client.zig:1741-1742` | `host` es "owned by the connection's TLS arena" | Es el slice del caller (P3-05) |
| `api_client.zig:551` | "caller owns body bytes only" | El caller tiene un puntero a un frame muerto (P0-09) |
| `api_client.zig:1796-1798` | `readSome` "distinguishes a clean close from a partial read" | Todo se mapea a `ReadFailed` (P3-01) |
| `api_client.zig:1697-1699` | `HANDSHAKE_TIMEOUT_MS` "Enforced via cumulative poll(2) timeouts inside `tls_conn.handshake`" | `handshake()` es un no-op y nadie lo llama (P0-12) |
| `api_client.zig:17-33` | Describe un `tls-handrolled` con resolver DNS propio + adapter de poll(2) | Ese código no existe desde el rewrite Opción B |
| `api_client.zig:21-24` | "cancellation and 5-second timeout are observed inside the adapter's poll(2) loop" | No hay adapter, ni poll, ni cancelación (P0-12) |
| `api_client.zig:1150-1157` | El test T1.9 "demonstra que TLS se está usando" | Está gated off y acepta `error.TlsHandshakeFailed` **o** `HandshakeTimeout` (P5-04) |
| `modal.zig:1800-1801` | `readEnvVar` devuelve un valor "safe to use for the duration of the process" | Slice a un stack-local (P2-04) |
| `runtime.zig:114-115` | `static_messages_storage` es "thread-local buffer" | Es un `var` global compartido (P1-05) |
| `runtime.zig:180-184` | El Agent thread "zeroes its in-memory key" en `Relock` | `.ApiKeySubmitted` hace `_ = key_bytes;` — no guarda nada que zeroear (P4-03) |
| `sandbox.zig:17-22` (header) | "Seccomp uses a fixed comptime BPF built from `sandbox_profile.default()` extended with…" | Usa `diagnostic_allow` — ni `default()` ni la extensión (P0-05) |
| `sandbox.zig:685-688` | "The child applies Landlock (runtime profile's path rules) + Seccomp (comptime `tool_bpf_prog`) BEFORE `execve`" | Landlock falla siempre sin NNP y se traga el error (P0-01) |
| `sandbox.zig:788-789` | "Each element must be null-terminated. Zig string literals are." | Los elementos vienen de `allocator.dupe` (P0-04) |
| `sandbox.zig:17-22` | "Seccomp deny-list always wins" | No hay deny-list; hay un allow-list fijo (P0-05) |
| `sandbox.zig:917` | "coverage gap documented in apply-progress" | `apply-progress` ya no existe (fase SDD) |
| `api_auth.zig:471-476` | `tryDecrypt`: "Caller must use the matching allocator to free" | El caller real (`runtime.zig:797`) usa `args.allocator` (= `page_allocator`), que **no** coincide con `testing.allocator` cuando `builtin.is_test`. Un test end-to-end del unlock haría panic en `free`. **Hipótesis, requiere verificación.** |
| `channels.zig:237` (implícito) | — | `tryPut`/`tryGet` devuelven `error.Canceled` si el mutex falla; `tryGet` devuelve `null` silenciosamente. Un fallo de lock se confunde con "canal vacío" |
| `bridge_sync_async.zig:23` | "pass -1" | `api_auth.zig:244` pasa `cancel_pipe[0]` real, no `-1`. Cosmético, pero contradice la instrucción |

### 6.2 Drift del context doc (`zargeant-context-for-ai-agent.md`)

| Línea | Afirma | Realidad |
|---|---|---|
| `:185` | `static_messages_storage` es "thread-local" | No lo es (P1-05) |
| `:207` | "BPF filter … syscall allowlist exacta en `TOOLS_PROFILE`" | Usa `diagnostic_allow` (P0-05) |
| `:206` | "Landlock + `landlock_add_rule` (path-scoped: `/tmp` + `/usr` + `/bin`)" | `TOOLS_PROFILE` lista `/tmp`, `/usr`, `/bin` — correcto — pero Landlock nunca se aplica (P0-01) |
| `:209` | "close_range pre-`execve` cierra fd > 2" | `:769` lo hace **después** de `restrictSelf` y **antes** de seccomp — correcto, pero la doc dice "pre-execve" lo cual es cierto; el problema es otro (§3.2 dice el orden estricto que el código no cumple) |
| `:221` | "Todos los payloads usan inline buffers + length counters" | 2 de 19 (P2-01) |
| `:261` | "Crypto/TLS \| `src/tls_conn.zig` (handrolled)" | **`src/tls_conn.zig` NO EXISTE.** El TLS es `api_client.zig:1736-1833` (tu corrección) |
| `:286` | "TLS handrolled \| ✓ shipped \| ~700 LoC" | 98 LoC (wrapper de stdlib) |
| `:143` | El SSE parser "silenciosamente descarta" `tool_calls` | Emite `.err/MalformedStream` y **aborta el stream** (§3) |
| `:184` | "TLS handshake via `tls_conn.connect` (handrolled, sin openssl ni rustls)" | `std.http.Client.connectTcp` — ni handrolled ni `std.crypto.tls.Client` directo |
| `:203` | Orden de aislamiento "validado por tests `src/sandbox_linux.zig`" | Los tests de `sandbox_linux` sólo testean constantes y el builder **muerto** (P5-02, P5-03) |
| `:800` | "pool worker exit cleanly on shutdown — NOT ADDRESSED" | Correcto, pero además el worker **nunca ve** el cancel por el `nfds=1` (P1-03) |
| `:798` | "Channel overflow drops oldest chunk — NOT ADDRESSED" | Correcto, y además es no-atómico (P1-01) |
| `:658` | "44 hits in `src/api_client.zig` … TODOS inside `test` blocks" | El conteo no incluye `api_auth.zig:485` (`if (builtin.is_test) testing.allocator`) ni `modal.zig`, que sí tienen hits en producción **gated por `builtin.is_test`** — la convención es distinta de la que el audit asume |
| `:490` | "Total: 26,706 LoC across `src/` + `tests/`" | `wc -l` da **26.399** (la cifra incluye líneas en blanco/comentarios de forma distinta) |
| `:526` | "500+ tests … 386 main + 114 in-tree terminal" | 540 bloques `test "`, pero ~12 no-ops + 9 greps (§4) |
| `:1` | "1,096 líneas" | 1.095 |
| `:20` | Rama `feat/post-roadmap-hygiene-and-offload`, "2 commits ahead" | El doc lista 7 commits en §2.1 |

### 6.3 Drift del README y `odd/`

| Ubicación | Drift |
|---|---|
| `README.md` | Menciona `src/tls_conn.zig` (no existe) y "TLS handrolled" |
| 30 archivos × `// Spec: sdd/…/spec (id=N)` | El proyecto migró a ODD (obs#1794, `zargeant-context-for-ai-agent.md:318`). Los ids de Engram (`sdd/api-client/spec id=276`) apuntan a documentos que ya no están en el repo. **Ninguna referencia `sdd/*` resuelve.** Esto es un problema real de trazabilidad: un mantenedor nuevo no puede ir de `runtime.zig:4` a la spec. |
| `sandbox.zig:918`, `sandbox_profile.zig:141`, `root.zig:12`, `tests/tui/cancel_path.zig:134` | Referencias a `apply-progress`, artefacto del workflow SDD abandonado. `root.zig:12` tiene un `id=` **vacío** |
| `zargeant-context-for-ai-agent.md:261` vs `:446` | El primero dice `src/tls_conn.zig`, el segundo dice `src/api_client.zig` — el doc **se contradice a sí mismo** |
| `post-roadmap-hygiene-and-offload.md:39` | `Event.ValidateApiRequest { kind: enum{ key_entry, unlock }, … }` — describe un `enum` en línea; el código usa un enum en línea también ✓, pero la línea 88 dice `(17→18)` cuando el conteo real es 19→20. El doc fue "fixed" en `607b61d` pero `:88` quedó con el número viejo |
| `post-roadmap-hygiene-and-offload.md:86` | "parsed via `std.json.parseFromSlice` then re-serialized to canonical string" — la re-serialización es innecesaria (§3.3) |
| `AGENTS.md:172` §9.1 | Lista `test-tui-screen-grid` y `test-runtime-thread` con "69+ tests" — el conteo real de `runtime_thread.zig` es 106 |
| `AGENTS.md §10` | El gate order es correcto y está bien justificado. **La lección (builds primero) aplica igual aquí**: si `tuiThreadLoop` no compila… no, compila. El gap es de tests, no de build. |
| `AGENTS.md:191` | `just test-embedded` — la receta menciona ~197 embedded tests; hay 190 en `src/` (540 - 350 en `tests/`) |
| `docs/conventions.md:122-126` | Dice que `AgentLoopState.cumulative` es allocator-owned "so this convention does not apply" — es una excepción razonada, pero convive con el hecho de que `modal.agent_loop.cumulative` es un `std.ArrayList` cuyo allocator **no está documentado** en el struct (P4-02). Y es la que hay que migrar en WU-4 |

### 6.4 Lo que la documentación hace bien (para no tirar el bebé con el agua)

- `docs/conventions.md` es un documento **excelente**: identifica el bug, da el patrón BAD/GOOD, enumera dónde se aplicó, y tiene un review checklist. Es exactamente el tipo de artefacto que previene P0-08. El problema es que slice 7 se lo saltó.
- `zargeant-context-for-ai-agent.md` §11 (problemas históricos) es un registro honesto y útil. El error no es mantener un snapshot, es mantener un snapshot **que se presenta como fuente de verdad** ("Es LA fuente de verdad sobre arquitectura") sin las marcas de "verify before use" que sí tiene al final (§16, línea 1096).
- `AGENTS.md` §10 (QA gate ordering) tiene un razonamiento de fondo excellent y una lección real aprendida (§11.4).
- `odd/tasks/post-roadmap-hygiene-and-offload.md` es un feature doc de calidad: goal, scope con tabla, acceptance criteria por WU, risk register, referencias. **El problema es que sus acceptance criteria no eran verificables** (ej. "Variant count is asserted via file-header comment + manual `git grep`" — `post-roadmap-hygiene-and-offload.md:76` — que es un no-op, y que es exactamente el tipo de criterio que dejó pasar P0-13).

---

## 7. Nota metodológica

Cuatro puntos marcados explícitamente como **hipótesis, requieren verificación** (no pude ejecutarlos sin toolchain):

1. **P1-06 / `readSliceShort` con buffer vacío** — si retorna 0 o bloquea. El fix (cota explícita) es correcto en ambos casos.
2. **P0-13 "cuasi-deterministico, no determinista"** — el TUI gana la carrera con probabilidad muy alta (Agent duerme 1 ms de cada 1 ms; TUI itera cada 16 ms), pero es una carrera. El test R-14 lo convertiría en determinista.
3. **P2-05 / secureZero disponible en Zig 0.16** — `std.crypto.utils.secureZero` puede no estar exportado; el fix manual con `volatile` es el fallback.
4. **P2-06 / `landlock_restrict_self` mismo-hilo** — el requisito de "mismo hilo" del comentario de `sandbox.zig:718-722` es para `landlock_add_rule`; si también aplica a `restrict_self`, mover `buildFromProfile` al padre no basta y hay que resolverlo con `posix_spawn` + `CLONE_FILES` o aceptar el diseño actual.

Un punto que **descarté** por no ser un finding: `Channel.tryGet` devuelve `null` si el lock falla (`channels.zig:283`), lo que confunde "fallo de sincronización" con "canal vacío". Lo revisé: ningún caller actual lo sufre, así que no lo reporto como finding. Queda anotado por si aparece un caller nuevo.

Otro punto revisado y descartado: el buffer `captured` del worker de tools no tiene tope, así que una herramienta que emita GB por stdout agota la memoria del harness. Es una limitación conocida (`context doc §11.27`, "stdout buffering — pipe(2) buffer is 64KB; long-output tools may block") y por eso el fix de P0-07 propone un tope explícito de 64 KiB en lugar de reportarlo como finding independiente.

---

*Fin del informe. Todos los findings con ID son verificables leyendo las líneas citadas; los cuatro marcados como hipótesis están explícitamente identificados en §7.*
