# Plan de remediación ODD — `zargeant`

> **Fecha**: 2026-10-01
> **Autor**: auditoría de código (41 findings) → diseño de remediación
> **Método**: ODD (Organic Driven Development) + Strict TDD (RED→GREEN) + RDD
> **Estado del repo al momento de escribir**: `zig build run` compila; CI verde; **el código es inseguro a pesar de ello**
> **Informe de auditoría base**: `AUDIT-REPORT.md` (3.014 líneas, 41 findings)

---

## 0. Veredicto y por qué este plan es urgente

La auditoría encontró que **las tres fronteras de confianza del proyecto están rotas de forma silenciosa y fail-open**:

| Frontera | Estado | Evidencia |
|---|---|---|
| **Sandbox (Landlock + Seccomp)** | **NO FUNCIONA** | `landlock_restrict_self` se llama antes de `PR_SET_NO_NEW_PRIVS` → `EPERM` garantizado, tragado con `catch {}` |
| **LTL / comunicación entre hilos** | **ROTA** | 5 use-after-free cross-thread; el hilo TUI consume su propio canal |
| **TLS** | **ROTA** | Sin timeout, sin cancel-pipe, fuga de memoria, errores enmascarados |

**El patrón que lo explica todo**: los controles *existen*, *se ejecutan*, y *sus errores se descartan*. El código fue escrito para ser correcto en el caso feliz y nadie verifica el caso infeliz — porque los tests que deberían hacerlo **mienten**: 9 "grep-tests" que leen su propio source, 5 tests tautológicos, 3 tests que pasan por permisos Unix en vez de por Landlock.

**Este plan no es una lista de deseos.** Es la secuencia mínima de commits trazables, cada uno con su test RED, su fix, y su gate de QA, respetando §10 (convenciones duras) y §14 (anti-patterns) del `zargeant-context-for-ai-agent.md`.

### 0.1 Verificación contra documentación oficial

Antes de diseñar los fixes, contrasté los hallazgos con documentación normativa. Resultado:

| Hallazgo | Fuente normativa | Resultado |
|---|---|---|
| **P0-01** (orden Landlock) | [`landlock_restrict_self(2)`](https://man7.org/linux/man-pages/man2/landlock_restrict_self.2.html) — *"either the caller must have the CAP_SYS_ADMIN capability in its user namespace, or the thread must already have the no_new_privs bit set"*; `EPERM` si no | ✅ **CONFIRMADO.** El orden en el código viola la especificación textualmente |
| **P0-02** (seccomp fail-open) | [`seccomp(2)`](https://manpages.debian.org/unstable/manpages-dev/seccomp.2.en.html) — *"If the filter is invalid, seccomp() fails, returning EINVAL"*; y requiere `no_new_privs` o `CAP_SYS_ADMIN`, si no `EACCES` | ✅ **CONFIRMADO.** `_ = seccomp(...)` descarta el único signal de que falló |
| **P0-03** (sin arch check en BPF) | [`seccomp_filter(2)`](https://docs.kernel.org/userspace-api/seccomp_filter.html) — el filtro se evalúa sobre `seccomp_data{arch, nr, ...}` | ✅ **CONFIRMADO.** Sin validación de `arch`, un atacante invoca la tabla i386 vía `int 0x80` y evade la allowlist x86-64 |
| **P0-11** (fuga en `HostName.init`) | [`std.http.Client.connectTcp`](https://ziglang.org/documentation/master/std/) / [`Bundle.rescan`](https://ziglang.org/documentation/0.11.0/std/src/std/crypto/Certificate/Bundle.zig.html) — `rescan` asigna el bundle vía el allocator recibido | ✅ **CONFIRMADO.** El bundle (~143 CAs en Arch) se fuga completo en cada hostname inválido |
| **P0-12** (TLS sin timeout) | `poll(2)` / `std.http.Client` no expone timeout de handshake sin wrapper explícito | ✅ **CONFIRMADO.** `connectTcp` bloquea hasta el timeout del socket del sistema (~2 min), no el de la app |
| **P0-10** (symlink en logger) | `open(2)` — `O_NOFOLLOW` es la única defensa contra symlink en el path final | ✅ **CONFIRMADO.** `O_CREAT\|O_TRUNC` sin `O_NOFOLLOW` sobre `/tmp/` = truncado arbitrario de archivo |

**Ningún hallazgo P0 quedó refutado por la documentación oficial.** Los 41 son válidos.

---

## 1. Visión de la secuencia

### 1.1 Principio rector

> **Ningún fix se mergea sin un test RED que falle por la razón correcta.**

Esto obliga a un cambio de orden respecto a lo que hizo slice 7: **primero se honestifican los tests del componente, después se arregla el componente.** Un test que miente no puede sostener un fix.

### 1.2 Orden de ejecución (y por qué este orden)

```
S1  sandbox-fail-closed-restoration   ← seguridad, no bloquea nada
S2  test-integrity-baseline           ← honestizar tests (HABILITA TDD de todo lo demás)
S3  wu3-tui-channel-ownership         ← desbloquea el path LLM completo
S4  cross-thread-lifetime             ← memory safety
S5  tls-path-hardening                ← TLS lifecycle
S6  sse-parser-lifecycle              ← arena + WU-4 tool_calls
S7  concurrency-lifecycle             ← poll nfds, join timeout
S8  logger-hardening                  ← symlink + buffer
S9  debt-consolidation                ← duplicación, anyerror, lazy else
S10 documentation-truth-pass          ← docs que mienten
```

**Por qué S2 va segundo y no al final:** 9 de los 41 findings son tests que pasan sin probar nada, y uno de ellos (`runtime.zig:1637`) **pasa mientras el bug de cancelación que encuentra vive en producción**. Si arreglo S1 y S3 sin honestizar los tests primero, no tengo forma de demostrar que los fixes funcionan. S2 es la infraestructura de verificación de todo lo demás.

**Por qué S3 va antes que S4/S5:** P0-13 hace que `Client.stream`, `api_sse.Parser` y `tls_conn` sean **código muerto en producción**. Arreglar el TLS (S5) sin arreglar S3 es arreglar código que nunca corre. S3 primero.

### 1.3 Mapa findings → slices

| Slice | Findings | # | Severidad máxima |
|---|---|---:|---|
| S1 `sandbox-fail-closed-restoration` | P0-01, P0-02, P0-03, P0-04, P0-05, P2-06, P3-02, P3-06, P5-03, P5-04 | 10 | **P0** |
| S2 `test-integrity-baseline` | P5-01, P5-02, P5-03, P5-04, P5-05, P5-06 | 6 | P5 |
| S3 `wu3-tui-channel-ownership` | P0-13, P4-03, P1-05 | 3 | **P0** |
| S4 `cross-thread-lifetime` | P0-06, P0-07, P0-08, P0-09, P2-01, P2-02, P2-04 | 7 | **P0** |
| S5 `tls-path-hardening` | P0-11, P0-12, P1-06, P2-03, P2-05, P3-01, P3-05 | 7 | **P0** |
| S6 `sse-parser-lifecycle` | P1-01, P1-02 + **WU-4** | 2+ | P1 |
| S7 `concurrency-lifecycle` | P1-03, P1-04 | 2 | P1 |
| S8 `logger-hardening` | P0-10, P3-04 | 2 | **P0** |
| S9 `debt-consolidation` | P3-03, P3-07, P4-01, P4-02 | 4 | P3 |
| S10 `documentation-truth-pass` | §6 del informe (drift) | — | — |

**Total cubierto: 41/41 findings.**

---

## S1 — `sandbox-fail-closed-restoration`

> **Severidad**: P0 · **Archivos**: `src/sandbox.zig`, `src/sandbox_linux.zig`, `src/sandbox_profile.zig` · **LOC estimado**: +180/-60
> **Feature doc**: `odd/tasks/sandbox-fail-closed-restoration.md`

### Contexto técnico

Hoy, el hijo sandboxed ejecuta esta secuencia (`sandbox.zig:744-812`):

```
1. sandbox_profile.buildFromProfile()      :744   construye ruleset
2. Landlock.restrictSelf(fd) catch {}      :755   ← FALLA SIEMPRE (EPERM), error tragado
3. close_range(3, maxInt)                  :769   cierra fds
4. prctl(PR_SET_NO_NEW_PRIVS, 1)           :772   ← TARDE
5. seccomp(SET_MODE_FILTER, ...)  _ =      :782   ← return-code descartado
6. execve(argv, argv_buf, envp)            :809
```

El paso 2 viola la especificación de `landlock_restrict_self(2)`, que exige `no_new_privs` **o** `CAP_SYS_ADMIN` **antes** de la llamada. Para un usuario no privilegiado el resultado es `EPERM` determinista, y `catch {}` lo descarta.

**Consecuencia**: el proceso hijo corre **sin Landlock**. Y si el BPF del paso 5 es inválido, corre **sin ningún confinement** — porque el único signal (`EINVAL`) se tira a la basura.

### WU-1.1 — Restaurar el orden de aislamiento y fail-closed

**Test RED** (`tests/sandbox_order.zig`, nuevo):

```zig
test "PR_SET_NO_NEW_PRIVS se establece ANTES de landlock_restrict_self" {
    // Guard de orden estático: el índice de la llamada a prctl
    // debe ser menor que el índice de restrictSelf.
    const src = @embedFile("../src/sandbox.zig");
    const prctl_idx = std.mem.indexOf(u8, src, "PR_SET_NO_NEW_PRIVS") orelse return error.NotFound;
    const restrict_idx = std.mem.indexOf(u8, src, "restrictSelf") orelse return error.NotFound;
    try testing.expect(prctl_idx < restrict_idx);
}
```

⚠️ **Este test es un grep-test y lo sé.** Es aceptable *aquí* porque el orden de dos llamadas es una propiedad estructural, no de comportamiento, y un test de comportamiento requeriría un kernel con Landlock ABI v1 en un contenedor privilegiado — no disponible en CI. Documentar la limitación en el feature doc.

**Fix** (`sandbox.zig:744-786`, reordenado):

```zig
// 1. Build Landlock ruleset (same thread as restrict_self).
const applied = sandbox_profile.buildFromProfile(allocator, profile) catch {
    std.os.linux.exit_group(1);
};

// 2. FAIL-CLOSED: no_new_privs ANTES de Landlock.
//    landlock_restrict_self(2) devuelve EPERM sin este bit y sin
//    CAP_SYS_ADMIN. No lo tragamos: si falla, el hijo no debe
//    ejecutar nada. ponytail: fail-closed > fail-open SIEMPRE en
//    una frontera de seguridad.
if (std.os.linux.prctl(
    sandbox_linux.PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0,
) != 0) {
    std.os.linux.exit_group(1);
}

// 3. Landlock. Cualquier error (EPERM, ENOSYS en kernel < 5.13,
//    EINVAL) es fatal: seguir sin Landlock es peor que no correr.
sandbox_linux.Landlock.restrictSelf(applied.landlock_fd) catch {
    std.os.linux.exit_group(1);
};

// 4. close_range ANTES de seccomp: si el filtro no permite
//    close_range, el sweeper de fds debe correr antes de instalarlo.
_ = std.os.linux.close_range(3, std.math.maxInt(i32), .{
    .UNSHARE = false,
    .CLOEXEC = false,
});

// 5. Seccomp. FAIL-CLOSED: EACCES (sin nnp), EINVAL (BPF malo),
//    EFAULT (prog puntero inválido) → todos son "no sandboxeado".
var fprog = SockFProg{
    .len = @intCast(tool_bpf_prog.len),
    .filter = &tool_bpf_prog,
};
if (std.os.linux.seccomp(
    sandbox_linux.SECCOMP.SET_MODE_FILTER,
    sandbox_linux.SECCOMP.FILTER_FLAG.TSYNC,
    @ptrCast(&fprog),
) != 0) {
    // Diagnóstico: el filtro NO quedó instalado.
    std.os.linux.exit_group(1);
}
```

**Nota sobre el exit code**: `exit_group(1)` antes de `execve` no ejecuta el binario. El padre debe distinguir "el hijo no pudo sandboxearse" de "el binario corrió y falló". `runtime.zig` ya tiene un parser de `WIFEXITED`; añadir el caso `exit(1)` pre-`execve` como `ToolError.SandboxSetupFailed` (nuevo error tipado, no `sandbox_violation` — ese es para `SIGSYS` en runtime).

### WU-1.2 — Validar `arch` en el BPF de producción

**Problema**: `buildToolBpf` (`:517-550`) omite la verificación de `arch`. El comentario en el código dice que `AUDIT_ARCH_X86_64 = 0xC000003E` "falsely KILLed every syscall" en el kernel Zen. **Ese comentario es factualmente incorrecto**: el valor *es* correcto; el problema original era que faltaba cargar `seccomp_data.arch` al filtro antes de comparar.

**Consecuencia de seguridad**: sin validación de `arch`, un proceso sandboxed puede invocar la **tabla de syscalls i386** vía `int 0x80`, que el filtro BPF no inspecciona (sólo matchea números de syscall x86-64). Bypass completo de la allowlist.

**Test RED**:

```zig
test "el BPF carga y valida seccomp_data.arch contra AUDIT_ARCH_X86_64" {
    const prog = buildToolBpf(&test_allowlist);
    // prog[0] debe ser LD_ABS(arch) → r0
    // prog[1] debe ser JEQ(r0, AUDIT_ARCH_X86_64) → KILL
    try testing.expectEqual(@as(u32, 0x20), prog[0].code & 0xFF); // BPF_LD|BPF_ABS|BPF_W
    try testing.expect(prog[1].code & 0xFF == 0x15);             // BPF_JMP|BPF_JEQ
    try testing.expectEqual(
        @as(i32, @bitCast(@as(u32, 0xC000003E))),
        prog[1].imm,
    );
}
```

**Fix**: agregar el prologue de arch y mover el resto del programa 2 instrucciones.

```zig
fn buildToolBpf(comptime allow: []const u32) [10 + allow.len]std.os.linux.BPF.Insn {
    const BPF = std.os.linux.BPF;
    const SECC = std.os.linux.SECCOMP;

    // ── Prologue: validar arch ANTES de tocar nr ──
    // Sin esto, un atacante puede usar la tabla i386 vía int 0x80.
    var prog: [10 + allow.len]BPF.Insn = undefined;

    // prog[0] = LD_ABS(offsetof(seccomp_data.arch)) → r0
    prog[0] = BPF.Insn.ld_abs(
        .word, .r0, .r0,
        @intCast(@offsetOf(SECC.data, "arch")),
    );
    // prog[1] = JEQ r0, AUDIT_ARCH_X86_64 → +8 (salta al check de nr)
    prog[1] = BPF.Insn.jeq(
        .r0, @bitCast(@as(u32, 0xC000003E)), 8,
    );
    // prog[2] = RET KILL_PROCESS (arch incorrecto)
    prog[2] = .{
        .code = BPF.RET | BPF.K,
        .dst = 0, .src = 0, .off = 0,
        .imm = @bitCast(@as(u32, SECC.RET.KILL_PROCESS)),
    };

    // ── Check de nr ──
    // prog[3] = LD_ABS(offsetof(seccomp_data.nr)) → r0
    prog[3] = BPF.Insn.ld_abs(
        .word, .r0, .r0,
        @intCast(@offsetOf(SECC.data, "nr")),
    );

    const last_idx: i64 = @intCast(prog.len - 1);
    for (allow, 0..) |syscall_nr, i| {
        const idx: i64 = @intCast(7 + i);
        const offset_to_allow: i16 = @intCast(last_idx - (idx + 1));
        prog[7 + i] = BPF.Insn.jeq(
            .r0, @intCast(syscall_nr), offset_to_allow,
        );
    }
    // Default deny
    prog[7 + allow.len] = .{
        .code = BPF.RET | BPF.K,
        .dst = 0, .src = 0, .off = 0,
        .imm = @bitCast(@as(u32, SECC.RET.KILL_PROCESS)),
    };
    prog[8 + allow.len] = .{
        .code = BPF.RET | BPF.K,
        .dst = 0, .src = 0, .off = 0,
        .imm = @bitCast(@as(u32, SECC.RET.ALLOW)),
    };
    return prog;
}
```

**Nota**: el array es `[10 + allow.len]` pero sólo se usan índices hasta `8 + allow.len`; el +2 es slack deliberado para que el compilador no optimice el salto. Ajustar a `[9 + allow.len]` si el test de bounds lo permite.

### WU-1.3 — Conectar `TOOLS_PROFILE.allowed_syscalls` al BPF real

**Problema** (`sandbox.zig:604-607`): el perfil del runtime define `allowed_syscalls` y `allowed_net_endpoints`, pero **el BPF que se instala se construye desde `diagnostic_allow`** (21 syscalls), no desde el perfil. `Seccomp.loadFilter` y `Seccomp.buildAllowlist` en `sandbox_linux.zig` están **correctamente implementados y son código muerto**.

**Test RED**:

```zig
test "el seccomp instalado deriva de TOOLS_PROFILE.allowed_syscalls" {
    const from_profile = sandbox_linux.Seccomp.buildAllowlist(&TOOLS_PROFILE);
    const from_diag = sandbox_linux.Seccomp.buildAllowlist(&DIAGNOSTIC_PROFILE);
    try testing.expect(from_profile.len != from_diag.len);
    try testing.expect(!std.mem.eql(u32, from_profile, from_diag));
}
```

**Fix**: en `sandbox.zig`, reemplazar la construcción del `tool_bpf_prog` por el perfil del runtime. Eliminar `diagnostic_allow` del path de producción (dejarlo sólo bajo `builtin.is_test`).

### WU-1.4 — Terminar `argv` en NUL y validar longitudes

**Problema** (`sandbox.zig:790-808`): `@as([*:0]const u8, @ptrCast(arg.ptr))` castea sin verificar NUL. Los elementos de `argv` vienen de `parse_argv`, que corta un buffer arbitrario — **no son necesariamente NUL-terminados**. Si `execve` los lee más allá del final, lee OOB de la memoria del proceso.

Además: `argv.len == 0` hace `argv[0]` OOB (`:809`), y `argv.len > 15` se trunca en silencio.

**Test RED**:

```zig
test "parse_argv + build_argv_buf produce argv NUL-terminado" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const args = try parse_argv(arena.allocator(), "ls  -la  /tmp");
    // Ningún elemento debe apuntar a un buffer no terminado.
    for (args) |arg| {
        const z: [*:0]const u8 = @ptrCast(arg.ptr);
        try testing.expect(std.mem.len(z) == arg.len);
    }
}

test "argv vacío se rechaza, no se lee OOB" {
    try testing.expectError(
        error.EmptyArgv,
        buildArgvBuf(&.{}, &buf),
    );
}
```

**Fix**:

```zig
fn buildArgvBuf(argv: []const []const u8, buf: *[16]?[*:0]const u8) !void {
    if (argv.len == 0) return error.EmptyArgv;
    if (argv.len > buf.len - 1) return error.TooManyArgs; // fail loud, no truncar
    for (argv, 0..) |arg, i| {
        buf[i] = try std.fmt.allocPrintSentinel(
            allocator, "{s}", .{arg}, 0,
        );
    }
    buf[@intCast(argv.len)] = null;
}
```

⚠️ Esto introduce una asignación. §10.1 prohíbe alloc en hot paths — pero `buildArgvBuf` corre **una vez por spawn de subprocess**, no en un hot path. Documentar la excepción en el feature doc.

### WU-1.5 — Eliminar la bomba de relojería `startup_allow_syscalls`

**Problema** (`sandbox.zig:43-503`): contiene `ptrace`, `mount`, `reboot`, `bpf`, `unshare`, `perf_event_open`, `userfaultfd` **con comentarios `// NO, denied` pero los números ESTÁN en la allowlist**.

Hoy es código muerto (el path de producción usa `diagnostic_allow`). **Pero el fix natural de WU-1.3 (delegar a la allowlist correcta) lo habilitaría accidentalmente.**

**Acción**: **borrar la función entera.** No "arreglarla". Una allowlist de 460 líneas con syscalls peligrosos comentados como denegados es exactamente el tipo de artefacto que se re-activa por accidente en un refactor.

**Test RED**:

```zig
test "ninguna allowlist de producción contiene syscalls de escape" {
    const forbidden = [_][]const u8{
        "ptrace", "mount", "reboot", "bpf", "unshare",
        "perf_event_open", "userfaultfd", "pivot_root",
    };
    for (forbidden) |name| {
        try testing.expect(
            !std.mem.containsAtLeast(u8, 1, production_allowlist_source, name),
        );
    }
}
```

### WU-1.6 — Mover el trabajo post-`clone` al hijo

**Problema** (P2-06, `sandbox.zig:744`): `buildFromProfile(allocator, ...)` hace trabajo de allocator y syscalls de FS **después del `clone`** en un proceso multi-hilo. El propio §3.2 del context doc prohíbe explícitamente *"Stack allocation post-clone está prohibido — corrompe heap del parent"*.

**Fix**: construir el ruleset en el **padre, antes del `clone`**, y sólo heredarlo al hijo. `close(2)` en el padre después del `clone` si el hijo no debe heredar el fd, o `SOCK.CLOEXEC` en el fd de ruleset.

### WU-1.7 — Endurecer el perfil por defecto

**Problema** (P3-02, `sandbox_profile.zig:66-67`): el perfil hardcodea `/home/josel/`. Eso es un path de home de una máquina específica hardcodeado en un perfil que se pretende default.

**Fix**: eliminar la entrada hardcodeada. El path de credenciales se resuelve vía `XDG_CONFIG_HOME` en runtime, no en el perfil compilado.

### Gate de QA de S1

```
just build && just build-safe && just build-fast   # §10, builds primero
just check
just test-all
just verify
just ci
```

**Gate adicional no negociable para S1**: un test manual que demuestre fail-closed.

```bash
# Debe ABORTAR (exit 1, sin ejecutar el binario), no correr sin sandbox:
ZARGEANT_FORCE_LANDLOCK_FAIL=1 zargeant --tool /bin/echo pwned
# output esperado: nada. NO debe imprimir "pwned".
```

### Criterio de aceptación de S1

- [ ] `prctl(NO_NEW_PRIVS)` precede a `restrictSelf` en el source
- [ ] Ningún error de `prctl`/`restrictSelf`/`seccomp` se descarta
- [ ] El BPF valida `arch`
- [ ] El seccomp instalado deriva de `TOOLS_PROFILE`, no de `diagnostic_allow`
- [ ] `argv` sale de `buildArgvBuf` con NUL garantizado, y `argv.len == 0` es error
- [ ] `startup_allow_syscalls` no existe
- [ ] Un fallo de sandbox **impide** la ejecución del tool (fail-closed verificado)
- [ ] `just ci` verde

---

## S2 — `test-integrity-baseline`

> **Severidad**: P5 pero **habilitante** · **Findings**: P5-01…P5-06 · **LOC**: +240/-80
> **Feature doc**: `odd/tasks/test-integrity-baseline.md`
> **Razón de ser aquí**: los tests de S1, S3, S4, S5 no pueden demostrar nada si la infraestructura de test miente.

### WU-2.1 — Clasificar los 9 grep-tests: máquina o conroecible

**Inventario** (de P5-01):

| Test | Ubicación | ¿Mecanismo? | Decisión |
|---|---|---|---|
| `"kills subprocess on cancel_pipe wakeup"` | `runtime.zig:1637` | ❌ **Pasa con el bug real (P1-03) vivo** | **REESCRIBIR** |
| `"no stdout or stderr writes"` | `api_client.zig` (dup2) | ⚠️ Parcialmente mecánico (dup2) | Reescribir con captura real |
| `"TLS via system CA bundle succeeds"` | `api_client.zig:1451` | ❌ Asserta que `"Bundle.rescan"` existe en el source | Reescribir con handshake real gateado |
| 6 restantes | varios | ⚠️ Varían | Auditar uno por uno |

**Principio** (a escribir en `docs/methodology.md`):

> Un grep-test es legítimo **sólo** cuando la propiedad que verifica es estructural y no conductual (orden de dos llamadas, ausencia de un import prohibido, tamaño de un enum). **Nunca** es válido como sustituto de un test de comportamiento en una frontera de seguridad.

**Test RED** para el guard que impide la regresión:

```zig
test "todo test que nombre un boundary de seguridad debe ejecutar código real" {
    // Meta-test: falla si aparece un grep-test sobre sandbox/tls/cancel.
    const suspicious = [_][]const u8{
        "indexOf(u8, src", "readFileAlloc(testing.allocator, @src().file",
    };
    // ... assertar que ninguno aparece cerca de un nombre de test de seguridad
}
```

### WU-2.2 — Arreglar el test de cancelación (P1-03 lo delata)

`runtime.zig:1637` verifica por grep que existe un string sobre `cancel_pipe`. El bug real (`poll(&pollfd, 1, ...)` sobre un array de 2) sigue vivo. **Este test es la prueba más dura de que la infraestructura de tests del proyecto no sirve para detectar regresiones de seguridad.**

**Test RED correcto**: comportamiento real con temporización.

```zig
test "cancel_pipe cierra el subprocess en vuelo" {
    // Spawn de un tool que duerma 10s.
    // Escribir al cancel_pipe write-end.
    // Assertar que el proceso sale en < 2s con SIGKILL,
    // NO en 10s por timeout natural.
    const start = std.time.milliTimestamp();
    cancel_pipe.write(1);
    const exit = waitTimeout(sub.pid, 2000);
    try testing.expectEqual(SIGKILL, exit);
    try testing.expect(std.time.milliTimestamp() - start < 2000);
}
```

Este test **falla hoy** (el bug P1-03) y **pasa después de S7**. Es el test que debió existir desde slice 7.

### WU-2.3 — Eliminar los 5 tests tautológicos

P5-02: `try testing.expect(true)` y equivalentes. Un test que no puede fallar no es un test.

**Acción**: borrar, o convertir en el test real que claramente pretendían ser. Si no se puede convertir, borrar y anotar en el feature doc qué cobertura se perdió.

### WU-2.4 — Tests que pasan por permisos Unix, no por Landlock (P5-03)

`sandbox.zig:899-910` prueba que el sandbox bloquea leer `/etc/shadow`. **Pasa sin Landlock** porque `/etc/shadow` es `0640 root:shadow` — ilegible igual. El test no prueba el sandbox; prueba permisos de archivo.

**Test RED correcto**: elegir un archivo que el usuario **puede** leer sin sandbox pero que Landlock debería bloquear.

```zig
test "Landlock bloquea lectura de un path FUERA del perfil" {
    // Crear un archivo legible en el home del usuario.
    const probe = tmpDir ++ "/landlock_probe.txt";
    try writeFile(probe, "secret");

    // Sin Landlock: legible.  Con Landlock: EACCES.
    const before = open(probe, .ACCMODE = .RDONLY);
    // ... spawning un tool que intente leerlo ...

    try testing.expectEqual(error.AccessDenied, result);
}
```

### WU-2.5 — Tests con `return` temprano silencioso (P5-04)

`sandbox.zig:919-935` y `api_client.zig:1158-1207` hacen `catch return` cuando su precondición no se cumple → **PASS**.

**Regla**: un test que no puede correr debe **fallar con diagnóstico explícito**, o declarar `error.SkipZigTest`. Nunca `return` silencioso.

```zig
// ANTES (falso PASS)
const bundle = loadBundle() catch return;

// DESPUÉS (honesto)
const bundle = loadBundle() catch |err| {
    std.debug.print("SKIP: CA bundle no disponible: {s}\n", .{@errorName(err)});
    return error.SkipZigTest;
};
```

### WU-2.6 — Tests de threading que no ejercitan threading (P5-05, P5-06)

`runtime.zig:1170-1179` — el test de "3 threads spawn+join" es secuencial. `runtime.zig:1236-1268` — 5 tests que no usan los canales cross-thread que dicen probar.

**Acción**: o se reescriben con concurrencia real (`std.Thread` + sincronización explícita + `testing.allocator` para detectar races de memoria), o se renombran para que no prometan lo que no prueban.

### Gate de QA de S2

- [ ] Los 9 grep-tests clasificados, con justificación escrita por test
- [ ] El test de cancelación rewritten y **fallando** por el bug correcto
- [ ] 0 tests con `try testing.expect(true)`
- [ ] 0 tests con `catch return` silencioso
- [ ] 0 tests de threading que no usen threads
- [ ] `just test-all` verde (y ahora meaningful)

---

## S3 — `wu3-tui-channel-ownership`

> **Severidad**: **P0** · **Archivo**: `src/tui.zig`, `src/channels.zig`, `src/modal.zig` · **LOC**: +40/-25
> **Feature doc**: `odd/tasks/wu3-tui-channel-ownership.md`

### Contexto técnico

`tui.zig:937-940`:

```zig
// 2. Drain channels.Shutdown from any edge (runtime signals all).
if (channels.tui_to_agent.tryGet(io)) |ev| switch (ev) {
    .Shutdown => return,
    else => continue,          // ← DESCARTA TODO LO DEMÁS
};
```

El hilo TUI está leyendo `tui_to_agent` — **el canal dirigido al hilo Agent**. Y descarta todo lo que no sea `Shutdown`.

Pero el TUI **es el productor** de ese canal: `modal.zig:910` postea `Event.ValidateApiRequest` a `tui_to_agent`. Resultado: **el TUI se auto-consume su propia petición antes de que el Agent la vea.** `validating` queda en `true` para siempre y la UI se queda clavada.

**Efecto dominó**: `Event.UserToolRequest` tampoco tiene productor real en producción → `Client.stream`, `api_sse.Parser` y `tls_conn` **nunca se ejecutan**. El path LLM completo es código muerto.

> **Esto es lo más importante del informe después de S1**: el commit `166d32e` fue marcado "FU-1 [HIGH] SHIPPED" y su test (`tests/tui/runtime_thread.zig`, +292 LoC) pasó en verde. El test ejercita `modal.zig` y `runtime.zig` por separado, nunca los tres hilos juntos, así que no podía detectar que el TUI roba su propio evento.

### WU-3.1 — El TUI no debe leer `tui_to_agent`

**Test RED** (`tests/tui/channel_ownership.zig`, nuevo):

```zig
test "ningún hilo lee un canal del que no es consumidor" {
    // El TUI produce hacia tui_to_agent; sólo el Agent debe consumirlo.
    // El Agent produce hacia agent_to_tui; sólo el TUI debe consumirlo.
    const tui_src = @embedFile("../../src/tui.zig");
    const agent_src = @embedFile("../../src/runtime.zig");

    try testing.expect(!referencesChannel(tui_src, "tui_to_agent"));
    try testing.expect(!referencesChannel(agent_src, "agent_to_tui"));
}
```

⚠️ grep-test de nuevo. **Justificación**: la propiedad "sólo el consumidor lee un canal" es estructural y deVcasi imposible de testear sin un harness de 3 hilos real. Aceptable bajo la regla de S2/WU-2.1.

**Fix** (`tui.zig:937-945`): eliminar el drain. Para recibir `Shutdown`, agregar un canal dedicado `shutdown_flag: std.atomic.Value(bool)` (que ya existe como `args.shutdown` por §1.2) o un canal unidireccional nuevo `ui_to_tui_shutdown`.

```zig
// ANTES — roba eventos del Agent
if (channels.tui_to_agent.tryGet(io)) |ev| switch (ev) {
    .Shutdown => return,
    else => continue,
};

// DESPUÉS — señal dedicada, sin tocar el canal del Agent
if (args.shutdown.load(.seq_cst)) return;
```

### WU-3.2 — Test de integración de los 3 hilos

Este es el test que **debió existir** desde slice 7.

```zig
test "ValidateApiRequest del TUI llega al Agent (3 hilos reales)" {
    // 1. Arrancar los 3 threads reales.
    // 2. El TUI postea ValidateApiRequest a tui_to_agent.
    // 3. El Agent debe recibirlo y postear ValidateApiReply.
    // 4. El TUI debe recibir el reply.
    // 5. Timeout de 2s: si no hay reply, FAIL (no skip).
    try testing.expectEqual(ReplyKind.Ok, result);
}
```

Este test **falla hoy** (P0-13) y es el guard que impide la regresión.

### WU-3.3 — Auditar las 5 variantes de `Event` sin productor (P4-03)

| Variante | ¿Productor? | Acción |
|---|---|---|
| `UserToolRequest` | ❌ | **Conectar** — es el path de tool calling |
| `ValidateApiRequest` | ⚠️ (robo) | Arreglar con WU-3.1 |
| `CancelTool` | ❌ | Conectar con el path de cancelación de S7 |
| `ToolCallsDetected` (proPUESTO) | — | Añadir con S6 (WU-4) |
| 1 más | ❌ | Documentar o borrar |

**Regla nueva para `docs/conventions.md`**: *toda variante de `Event` debe tener un productor en producción o marcarse explícitamente como reservada. Una variante sin productor es código muerto que el optimizer no puede eliminar porque es parte de una union.*

### Gate de QA de S3

- [ ] `tui.zig` no referencia `tui_to_agent`
- [ ] Test de 3 hilos reales pasa en < 2s
- [ ] `validating` vuelve a `false` tras un validate fallido
- [ ] `Client.stream` se ejecuta en producción (verificable por log)
- [ ] `just ci` verde

---

## S4 — `cross-thread-lifetime`

> **Severidad**: **P0** · **Archivos**: `src/runtime.zig`, `src/channels.zig`, `src/api_client.zig` · **LOC**: +120/-60
> **Feature doc**: `odd/tasks/cross-thread-lifetime.md`

### Contexto técnico

Esta slice restaura el **Bug 1** que `docs/conventions.md` documenta como cerrado, y que slice 7 reintrodujo 7 veces. `docs/conventions.md` §"State storage" ya tiene la regla correcta; el código nuevo no la siguió.

**Inventario de las 7 infecciones:**

| # | Ubicación | Mecanismo |
|---|---|---|
| P0-06 | `runtime.zig:564-566` | `stripEsc(...)` produce un slice alocado; `defer alloc.free(...)` lo libera; el slice ya está posteado al canal. **El TUI lee memoria liberada.** |
| P0-07 | `runtime.zig:931` + `:1050-1055` | `captured: ArrayList(u8)` con `defer deinit`; `.output = captured.items` se postea al canal; al salir del scope, el buffer se libera. |
| P0-08 | `runtime.zig:677, 860, 873, 887, 914` | `var buf: [64]u8` stack-local → `bufPrint` → `ToolError.message: []const u8` posteado al canal. El stack frame se recicla. |
| P0-09 | `api_client.zig:548-552, 690-694 → :325` | `body_bytes` es un slice a un array stack-local de 16 KiB; `Client.stream:325` lo lee **después** de que `tryOneAttempt` retornó. |
| P2-01 | `channels.zig:88-132` | 4 variantes de `Event` cruzan hilos con `[]const u8` en vez de inline buffer. La afirmación del doc de que "todos los payloads usan inline buffers" es falsa. |
| P2-02 | `runtime.zig:1129-1162` | `parse_argv` filtra los elementos ya asignados si `dupe` falla a mitad del bucle. |
| P2-04 | `api_auth.zig:662`, `modal.zig:1802` | `readEnv`/`readEnvVar` devuelven slices a un stack-local de 8 KiB, con un doc-comment que afirma *"safe to use for the duration of the process"*. Es falso **y** trunca a 8 KiB. |

### WU-4.1 — Inline buffers para `ToolError.message` (P0-08)

**Aplicar la convención canónica de `docs/conventions.md` §"Pattern (GOOD)"**:

```zig
// src/channels.zig — Event.ToolError
pub const ToolError = struct {
    id: u32,
    message_buf: [128]u8,
    message_len: usize,

    pub fn init(id: u32, message: []const u8) ToolError {
        var self: ToolError = .{
            .id = id,
            .message_buf = undefined,
            .message_len = @min(message.len, self.message_buf.len),
        };
        @memcpy(self.message_buf[0..self.message_len], message[0..self.message_len]);
        return self;
    }

    pub fn slice(self: *const ToolError) []const u8 {
        return self.message_buf[0..self.message_len];
    }
};
```

Y los 5 call sites pasan a `.message = ToolError.init(...)`.

**Test RED**:

```zig
test "ToolError no contiene slices, sólo inline buffers" {
    try testing.expect(@hasField(channels.Event.ToolError, "message_buf"));
    try testing.expect(!@hasField(channels.Event.ToolError, "message"));
}
```

### WU-4.2 — Ownership del texto SSE (P0-06)

**Test RED** (el test más importante de esta slice, porque usa ASan/GPA):

```zig
test "el texto SSE posteado al TUI sobrevive al scope del Agent" {
    // testing.allocator detecta use-after-free con .deinit() doble.
    const agent_alloc = testing.allocator;
    var ctx = try TestContext.init(agent_alloc);
    defer ctx.deinit();

    try ctx.postSseText("hola mundo");
    ctx.freeAgentScope();        // simula el `defer free` de runtime.zig:565
    try testing.expectEqualStrings("hola mundo", ctx.drainTuiText());
    // Falla HOY con use-after-free detectado por testing.allocator.
}
```

**Opciones de fix, en orden de preferencia:**

1. **Inline en el canal** (preferida, cumple `docs/conventions.md`): `StreamChunk` lleva `text_buf: [4096]u8 + text_len`. El texto SSE cabe en 4 KiB por chunk.
2. **Transferencia de ownership**: el que postea NO hace `defer free`; el que consume SÍ. Requiere documentar el ownership en el tipo.
3. **Arena compartida**: todos los `StreamChunk` de una request viven en una arena que se libera cuando el TUI confirma recepción.

**Recomendación**: opción 1. Es lo que `docs/conventions.md` §"State storage" exige, es bounded, y no requiere cambiar el modelo de ownership.

### WU-4.3 — Ownership de `captured.items` (P0-07)

Mismo patrón que WU-4.2. `ToolResult.output` necesita inline buffer o ownership explícito. `output` puede ser grande (stdout de un tool) — aquí la opción 1 no aplica si excede 4 KiB.

**Opción recomendada**: buffer estático grande en el `ToolResult` (`output_buf: [64]KiB]u8`), truncar explícitamente y registrar el truncamiento en el log (§11.27 ya documenta que el pipe buffer es 64 KB). Documentar el límite.

### WU-4.4 — `body_bytes` post-return (P0-09)

`api_client.zig:325` lee `body_bytes` después de que `tryOneAttempt` retornó. El array de 16 KiB es un stack-local del tryOneAttempt.

**Fix**: o mover el array a un struct que viva en el scope del caller, o hacer que `tryOneAttempt` escriba el body en un bufferr del caller (patrón `out: *[]u8`).

### WU-4.5 — `readEnv` devuelve ownership válido (P2-04)

Tres copias de `readEnv` (P4-01). Mientras S9 no consolide, corregir **la más peligrosa**: `api_auth.zig:662` y `modal.zig:1802`.

**Test RED**:

```zig
test "readEnv devuelve un slice whose backing store sobrevive al return" {
    const value = try readEnv(allocator, "HOME");
    // Si el backing es stack-local, este assert es UB y el
    // compilador en ReleaseSafe con GPA lo detecta.
    try testing.expect(std.mem.startsWith(u8, value, "/"));
}
```

**Fix**: `alloc.dupe(u8, buf[0..len])` y documentar que el caller owns el resultado.

### WU-4.6 — `parse_argv` cleanup en error (P2-02)

**Test RED**:

```zig
test "parse_argv libera lo ya asignado si dupe falla a mitad" {
    var failing = testing.FailingAllocator.init(testing.allocator, .{.fail_index = 3});
    try testing.expectError(error.OutOfMemory, parse_argv(failing.allocator(), "a b c d e"));
    // testing.allocator base reporta el leak si falta cleanup.
}
```

### Gate de QA de S4

- [ ] 0 slices en `Event` que cruzan hilos
- [ ] Test de supervivencia de texto SSE pasa bajo `testing.allocator`
- [ ] 0 leaks bajo `GPA` en `just test-all`
- [ ] `docs/conventions.md` §"State storage" actualizado con los 7 sitios
- [ ] `just ci` verde

---

## S5 — `tls-path-hardening`

> **Severidad**: **P0** · **Archivo**: `src/api_client.zig`, `src/api_auth.zig` · **LOC**: +150/-40
> **Feature doc**: `odd/tasks/tls-path-hardening.md`
> **⚠️ Depende de S3**: hasta que el path LLM no se ejecute, esto es hardening de código inerte.

### WU-5.1 — Fuga en el error path de `HostName.init` (P0-11)

```zig
// src/api_client.zig:1772 — LEAK
const hostname = std.Io.net.HostName.init(host) catch return error.TlsHandshakeFailed;
//                            ^^^ client_ptr (:1761) y su ca_bundle se fugan
```

**Test RED**:

```zig
test "connect() no fuga cuando HostName.init falla" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.testing.expect(gpa.deinit() == .ok) catch @panic("LEAK");

    const res = tls_conn.connect(io, gpa.allocator(), "", 443);
    try testing.expectError(error.TlsHandshakeFailed, res);
    // El deinit() de gpa falla hoy: ~143 CAs + std.http.Client fugados.
}
```

**Fix** — `errdefer` immediately after cada adquisición (AGENTS.md §1, Tiger Style):

```zig
const client_ptr = try alloc.create(std.http.Client);
errdefer alloc.destroy(client_ptr);
client_ptr.* = .{ .allocator = alloc, .io = io, .now = now, .ca_bundle = bundle };
errdefer client_ptr.ca_bundle.deinit(alloc);

const hostname = std.Io.net.HostName.init(host) catch
    return error.TlsHandshakeFailed;    // errdefer limpia ambos
```

⚠️ `errdefer` no dispara en `return` de éxito — correcto. Y `connectTcp` (`:1773-1777`) ya limpia, pero el `errdefer` lo hace redundante: **borrar el cleanup manual de `:1774-1775`** para tener un solo path de error.

### WU-5.2 — Timeout de handshake real (P0-12)

`handshake(timeout_ms)` es un no-op (`:1790`) y **nadie lo llama**. `connectTcp` bloquea hasta el timeout del socket del sistema (~2 min en Linux), no el de la app.

**Test RED**:

```zig
test "connect contra un host que no responde TLS aborta en el timeout" {
    const start = std.time.milliTimestamp();
    const res = tls_conn.connect(io, allocator, "10.255.255.1", 443);
    try testing.expectError(error.TlsHandshakeFailed, res);
    try testing.expect(std.time.milliTimestamp() - start < 5000);
    // Falla HOY: tarda ~2 min (timeout del SO).
}
```

**Fix**: envolver el handshake en un future con deadline usando el `std.Io` de 0.16, o hacer el `connect` en un thread con timeout y `cancel_pipe`. Dado que §10.1 prohíbe alloc en hot paths y el `tls_conn` ya es un struct heap-allocated (una vez por request), un `std.Io` future es aceptable.

**Decisión de diseño a documentar**: ¿`handshake(timeout_ms)` se implementa de verdad, o se **borra** junto con sus call sites (no tiene ninguno)? Recomiendo **borrarlo** y mover la lógica al timeout del connect, porque una API que dice "handshake" pero no lo hace es peor que no tenerla.

### WU-5.3 — Cancel-pipe en el path TLS (P0-12, P1-06)

El path plain consulta `cancel_pipe` (`:605`). **El path TLS no.** Un Ctrl+C durante una request real a `api.minimax.io` no la aborta.

**Test RED**:

```zig
test "cancel_pipe aborta una request TLS en vuelo" {
    // Spawn del request real a un endpoint lento (mock server que acepta
    // la conexión pero no responde).
    // Cerrar cancel_pipe.
    // Assertar que el request termina en < 1s, no al timeout completo.
}
```

**Fix**: unificar el loop de headers TLS con el del path plain — un solo loop con el chequeo de cancelación, no dos copias.

### WU-5.4 — Degradar el enmascaramiento de errores (P3-01)

```zig
// :1801 — traga TODO
const r = self.connection.reader();
const n = r.readSliceShort(dest) catch return error.ReadFailed;
```

Enmascara `EndOfStream`, `ConnectionReset`, `error.Tls`, `OutOfMemory`. Y el llamador (`:483`) mapea *todo* a `ReadFailed` otra vez.

**Fix**:

```zig
const n = r.readSliceShort(dest) catch |err| switch (err) {
    error.EndOfStream => return error.ConnectionClosed,
    error.OutOfMemory => return error.OutOfMemory,
    error.ConnectionResetByPeer => return error.ConnectionClosed,
    else => |e| return e,        // propaga, no enmascara
};
```

§10.2 + §6 de AGENTS.md: *"No Swallowing Errors"*.

### WU-5.5 — Wipe de la clave derivada (P2-05)

`api_auth.zig:486` y `:620`: la clave Argon2id derivada nunca se wipea. Queda en el heap hasta que el allocator la reutilice.

**Fix**:

```zig
var derived_key: [32]u8 = undefined;
defer std.crypto.secureZero(u8, &derived_key);   // verificar API 0.16
```

⚠️ **Nota**: el compilador puede optimizar un wipe si detecta que el buffer no se usa después. Mitigación: `std.crypto.secureZero` usa `@volatileStore` internamente. **Verificar que existe en 0.16** antes de usarlo (marcado como hipótesis en el informe).

### WU-5.6 — `statusToError` sin `anyerror` (P2-03)

`api_client.zig:725` devuelve `anyerror`, violando §10.2 y §14.2.

**Fix**: definir un error set explícito y mapear los status HTTP a ese set.

### Gate de QA de S5

- [ ] `gpa.deinit() == .ok` en el test de `HostName.init` fallido
- [ ] Handshake a host muerto aborta en < 5s
- [ ] Cancel-pipe aborta request TLS en < 1s
- [ ] 0 `anyerror` en `src/`
- [ ] Clave derivada wipeada
- [ ] `just ci` verde

---

## S6 — `sse-parser-lifecycle`

> **Severidad**: P1 + **WU-4** · **Archivo**: `src/api_sse.zig`, `src/channels.zig` · **LOC**: +300/-40
> **Feature doc**: `odd/tasks/sse-parser-lifecycle.md` (extiende `post-roadmap-hygiene-and-offload`)

### WU-6.1 — Reset de la arena del parser (P1-02)

`api_sse.zig:86, 184, 263, 315, 323` — la arena nunca se resetea. Con contenido acumulativo (el caso normal de un stream largo), el crecimiento es **O(n²)**.

**Test RED**:

```zig
test "la arena del parser no crece con contenido acumulativo" {
    var p = try Parser.init(testing.allocator, io);
    var before: usize = 0;
    for (0..1000) |_| {
        try p.feed(cumulative_content);  // 1 KiB acumulativo
        if (p.allocator().queryCapacity() catch 0 > before) before = ...;
    }
    // Assertar que la capacidad es O(1) en el número de feeds.
}
```

**Fix**: `defer parser.deinit()` por request, o `arena.reset(.retain_capacity)` entre mensajes.

### WU-6.2 — TOCTOU en `pushSseChunk` (P1-01)

`channels.zig:413-417`: `peekLast` y `replaceLast` no son atómicos juntos. Dos Productores (Agent thread y un path de tool) pueden perder un chunk.

**Fix**: un solo lock alrededor de `peekLast → replaceLast`, o `synchronized` sobre el backing store.

### WU-6.3 — WU-4: parseo de `tool_calls`

Este es el gap funcional del slice activo. **La auditoría encontró que la documentación se equivoca en un detalle importante.**

> **El doc dice** (§2.4): *"el SSE parser camina `choices[0].delta.content` y silenciosamente descarta `delta.tool_calls[i]`"*.
> **El código hace**: cae a `.err/MalformedStream`, y `ChunkEventStream.next:227` pone `finished = true` → **aborta el stream entero** en el primer chunk de tool_calls.

Es peor que "silencioso", y con síntomas distintos: el usuario ve el stream cortarse, no una respuesta incompleta.

**Diseño propuesto** (adaptado a los hallazgos de la auditoría):

1. **Nuevo `Event.ToolCallsDelta`** en `channels.zig` (19 → 20 variants):
   ```zig
   ToolCallsDelta: struct {
       index: u16,
       id_buf: [64]u8,  id_len: usize,
       name_buf: [64]u8, name_len: usize,
       args_buf: [512]u8, args_len: usize,
   },
   ```
   Inline buffers por `docs/conventions.md`. El SSE parte `arguments` en fragments, así que hay que **acumular** en el TUI hasta ver `"finish_reason":"tool_calls"`.

2. **Parser tolerante** (`api_sse.zig`): un `tool_calls` inesperado en un chunk de contenido **no** debe ser `MalformedStream`. Se parsea y se emite el delta.

3. **Decisión de diseño, escrita en el feature doc**: ¿`Event.ToolCallsDetected` (indicator) adicional, o el `ToolCallsDelta` por fragmento es suficiente? **Recomiendo NO añadir el indicator** — el TUI puede derivarlo de "hay ToolCallsDelta pendientes" sin un nuevo variant. Cada variant es superficie de API.

**Plan de tests RED→GREEN** (en orden):

| # | Test | Qué prueba |
|---|---|---|
| T1 | `delta.tool_calls` con `index`, `id`, `function.name`, `function.arguments` completos | Path de un solo chunk |
| T2 | `arguments` partido en 3 fragments | Acumulación |
| T3 | `message.tool_calls` (no-delta, shot único) | Path alternativo |
| T4 | `tool_calls` + `content` en el mismo `choices[0]` | Coexistencia |
| T5 | `tool_calls` malformado (sin `function`) | `MalformedStream` — **legítimo** aquí |
| T6 | Backward-compat: `UserToolRequest` verbatim-forward sigue funcionando | No regresión |
| T7 | `ChunkEventStream` NO aborta ante tool_calls | **Regresión directa de P0-13/WU-4** |

**T7 es el test que habría detectado el bug original.** Debe existir antes de T1.

### Gate de QA de S6

- [ ] Arena reseteada — test de crecimiento O(1) pasa
- [ ] `pushSseChunk` sin pérdida bajo concurrencia
- [ ] T1-T7 verdes
- [ ] `channels.zig` en 20 variants, todas con productor
- [ ] `just ci` verde

---

## S7 — `concurrency-lifecycle`

> **Severidad**: P1 · **Archivo**: `src/runtime.zig` · **LOC**: +60/-25
> **Feature doc**: `odd/tasks/concurrency-lifecycle.md`

### WU-7.1 — `poll(2)` con `nfds` incorrecto (P1-03)

```zig
// runtime.zig:950-953 — el array tiene 2 elementos, le pasas 1
var pollfd = [_]std.os.linux.pollfd{
    .{ .fd = sub.stdout_fd, ... },
    .{ .fd = args.cancel_pipe[0], ... },
};
_ = std.os.linux.poll(&pollfd, 1, poll_timeout);   // ← nfds = 1
// pollfd[1].revents NUNCA se evalúa
```

**Un carácter.** `1` → `2`.

**Test RED**: el de WU-2.2 (comportamiento real con temporización). Este fix y ese test van juntos.

**Fix**:

```zig
_ = std.os.linux.poll(&pollfd, pollfd.len, poll_timeout);
if (pollfd[1].revents & std.os.linux.POLL.IN != 0) {
    // cancel detectado → kill del subprocess en vuelo
}
```

⚠️ **Por qué el bug sobrevivió 7 slices**: el test que lo cubría (`runtime.zig:1637`) es un grep-test. Ver S2.

### WU-7.2 — `Runtime.join(timeout)` real (P1-04)

`join()` es bloqueante, así que `JoinResult.timeout` es **inalcanzable**. Combinado con el hang de TLS (S5), el proceso puede no terminar nunca.

**Fix**: `std.Thread` no expone join con timeout. Opciones:
1. `std.Thread.Semaphore` + un thread watchdog que hace `kill(pid, SIGKILL)` tras el timeout.
2. `std.os.linux.pidfd_open` + `poll` sobre el pidfd con timeout (Linux 5.3+; el proyecto ya exige ≥ 5.13).

**Recomendación**: opción 2. Es la correcta y usa lo que el kernel ya ofrece. `pidfd_open` da un fd pollable que se puede cerrar y que entrega el estado del hijo sin races con el reaping.

### WU-7.3 — `static_messages_storage` thread-local (P1-05)

`runtime.zig:120` es un global compartido, no thread-local. El doc (§3.1) afirma que es thread-local. Es doc drift **y** una carrera latente: si el Agent thread corre dos requests (hoy no, por diseño de "un in-flight"), corrompe.

**Fix**: `threadlocal var` + actualizar el doc.

### Gate de QA de S7

- [ ] Cancel-pipe mata el subprocess en < 2s (test de WU-2.2 verde)
- [ ] `JoinResult.timeout` es alcanzable (test con un thread colgado)
- [ ] `static_messages_storage` es `threadlocal`
- [ ] `just ci` verde

---

## S8 — `logger-hardening`

> **Severidad**: **P0** (en host multi-usuario) · **Archivo**: `src/logger.zig` · **LOC**: +40/-15
> **Feature doc**: `odd/tasks/logger-hardening.md`

### WU-8.1 — `O_NOFOLLOW` contra symlink attack (P0-10)

```zig
// logger.zig:55-60
const flags = .{
    .ACCMODE = .WRONLY,
    .CREAT = true,
    .TRUNC = true,     // ← trunca lo que haya
    .CLOEXEC = true,
};
// SIN .NOFOLLOW
```

**Ataque**: en un host multi-usuario, un atacante crea `/tmp/ai-harness-debug.log` como symlink a `~/.bashrc` o a un archivo del sistema. El harness lo abre con `O_TRUNC` → **truncado arbitrario de archivo + escritura de datos controlados por el atacante**. Y el `fchmod(0o600)` posterior cambia los permisos del archivo de la víctima.

**Test RED**:

```zig
test "el logger no sigue symlinks en el path del log" {
    const probe = tmpPath ++ "/logger_symlink_probe";
    try symlink("/etc/hostname", probe);
    // Intentar abrir el logger apuntando a `probe`.
    try testing.expectError(error.OpenFailed, Logger.open(allocator, probe));
    // Falla HOY: abre y trunca /etc/hostname (o el symlink).
}
```

**Fix**:

```zig
const flags: std.posix.O = .{
    .ACCMODE = .WRONLY,
    .CREAT = true,
    .TRUNC = true,
    .CLOEXEC = true,
    .NOFOLLOW = true,      // ← no seguir symlinks
};
```

**Defensa en profundidad** (recomendada, ambas): `openat` con `O_EXCL` + retry con nombre único si el archivo existe. Pero **`O_NOFOLLOW` es el fix mínimo correcto**.

**Nota de entorno**: §10.7 exige `XDG_RUNTIME_DIR` (0700) para IPC sockets. El log debería ir ahí, no en `/tmp/` compartido. Eso es un cambio de política, no de código — **decisión del usuario**.

### WU-8.2 — `MAX_MESSAGE_LEN` descuadrado (P3-04)

`logger.zig:42` declara 16 KiB; el buffer real (`:93`) es 4 KiB. Truncamiento silencioso en ~75% de los mensajes.

**Fix**: una sola constante, usada por la declaración y el assert.

```zig
const MAX_MESSAGE_LEN = 4096;
var buf: [MAX_MESSAGE_LEN]u8 = undefined;
```

### Gate de QA de S8

- [ ] Test de symlink verde
- [ ] `MAX_MESSAGE_LEN` consistente
- [ ] Log no contiene el API key (verificar con grep sobre un run real)
- [ ] `just ci` verde

---

## S9 — `debt-consolidation`

> **Severidad**: P3/P4 · **Archivos**: `src/modal.zig`, `src/api_auth.zig`, `src/logger.zig`, `src/runtime.zig` · **LOC**: -200/+80
> **Feature doc**: `odd/tasks/debt-consolidation.md`

### WU-9.1 — Consolidar las 3 copias de `readEnv` (P4-01)

`api_auth.zig`, `modal.zig`, `logger.zig` tienen copias divergentes del mismo helper. **Ya divergieron** (una trunca a 8 KiB, otra no; una devuelve slice stack-local, otra no).

**Fix**: un solo `readEnv` en el módulo más bajo (`api_auth.zig` o un nuevo `env.zig`), con la corrección de ownership de WU-4.5.

⚠️ §14.15 prohíbe "solid/DRY/KISS refactors abstractos" **sin un FU trazable**. Este WU está trazado: elimina 2 bugs reales (P2-04 ×2, P4-01).

### WU-9.2 — Eliminar `else =>` lazy (P3-03)

`runtime.zig:620` y `api_client.zig:237-245` usan `else =>` sobre unions, violando §10.4.

**Por qué importa**: un `else =>` sobre una union **no** es un default de runtime — es una rama que el compilador no puede marcar como alcanzable, y oculta variantes nuevas. El contrato de §10.4 es explícito.

**Fix**: `inline else` sólo con `@compileError` en el interior, o enumerar todas las variantes.

### WU-9.3 — `@intCast` con assert previo (P3-07)

`runtime.zig:1037` castea sin assert. §10.5 lo prohíbe. En `ReleaseFast` el assert desaparece → OOB silencioso.

**Fix**: `std.debug.assert(x >= min and x <= max)` antes de cada `@intCast` no trivial.

### WU-9.4 — `modal.zig` (2.598 LoC) (P4-02)

Monolith con 4 responsabilidades mezcladas: layout, state machine, input, API key entry.

⚠️ **Este NO lo arregles ahora.** Un split de 2.598 líneas es un slice grande, riesgoso, y el proyecto tiene slices más graves esperando. **Decisión: diferir a Phase 3.** Anotar en el roadmap. Lo que sí se puede hacer en S9 es el doc-comment que declare las 4 responsabilidades y sus fronteras, para que el split futuro tenga un mapa.

### Gate de QA de S9

- [ ] 1 copia de `readEnv`
- [ ] 0 `else =>` lazy sobre unions en `src/`
- [ ] 0 `@intCast` sin assert en paths con índice
- [ ] `just ci` verde

---

## S10 — `documentation-truth-pass`

> **Severidad**: baja de código, **alta de confianza** · **Finding**: §6 del informe (30 referencias a `sdd/*`, 3 a `apply-progress`, doc-comments falsos)
> **Feature doc**: `odd/tasks/documentation-truth-pass.md`

**Este slice es barato y previene que el próximo agente (humano o IA) tome decisiones sobre información falsa.**

### WU-10.1 — Corregir los doc-comments que mienten

| Ubicación | Afirmación falsa |
|---|---|
| `api_client.zig:1741-1742` | `.host` es "owned by the connection's TLS arena" — es el slice del caller |
| `api_client.zig:324` (P0-09) | "caller owns body bytes" — el caller no lo puede leer (ya se liberó) |
| `api_auth.zig:660`, `modal.zig:1800` | `readEnv` es "safe for the duration of the process" — es un stack-local de 8 KiB |
| `channels.zig:88` | "todos los payloads usan inline buffers" — 4 variantes cruzan con `[]const u8` |
| `runtime.zig:120` | `static_messages_storage` es thread-local — es un global compartido |
| `sandbox.zig:748-754` | "Failure here is tolerated… best-effort FS hardening" — **esto es la política que causó P0-01** |

⚠️ **El último es el más importante.** El comentario explica *por qué* el fail-open fue una decisión deliberada. Argumentar que "seccomp es la defensa principal y Landlock es best-effort" es razonable **sólo si seccomp funciona**. No funcionaba, y su error se descartaba. El comentario debe cambiar a "fail-closed: si Landlock falla, el hijo no ejecuta".

### WU-10.2 — Migrar el drift SDD → ODD

30 referencias a `sdd/*` en 18 archivos, 3 a `apply-progress` (fase que ya no existe), `root.zig:12` con un `id=` vacío.

**Acción**: `rg 'sdd/|apply-progress'` → reemplazar por la referencia ODD equivalente (`odd/tasks/<feature>.md`) o eliminar. Documentar en `AGENTS.md` que la fase SDD está cerrada.

### WU-10.3 — Corregir el context doc y el README

- **`tls_conn.zig` no existe** — está inline en `api_client.zig:1736-1833`. El README y el context doc mienten.
- **§1.2** menciona `src/tools_real_main` — no existe como archivo.
- **§3.1** dice `static_messages_storage` es thread-local — es global.
- **§5.1** dice `Phase 2 Tiger Style retrofit: ~5,375 LoC | 132 tests` — verificar contra el árbol real.
- **§9.1** dice "~197 embedded tests" — verificar.
- **`PR_SET_DUMPABLE`** se documenta en §10.7 como convención activa — **no existe en el código**.

### Gate de QA de S10

- [ ] `rg 'sdd/|apply-progress'` → 0 resultados
- [ ] Cada doc-comment marcado en WU-10.1 corregido
- [ ] README y context doc coherentes con el árbol real

---

## 2. Secuencia de merge y gates

### 2.1 Orden de merge (con razones)

```
1. S1  sandbox          → por qué primero: es la frontera de seguridad,
                          es independiente, y falla-closed es no negociable.
2. S2  test-integrity   → por qué segundo: sin esto, S3-S8 no se pueden
                          demostrar. Es la infraestructura de verificación.
3. S3  channel-ownership→ por qué tercero: desbloquea el path LLM. Sin esto,
                          S5 (TLS) y S6 (SSE) operarán sobre código muerto.
4. S4  lifetime         → memory safety, 7 bugs de una vez, mismo archivo
                          (runtime.zig) que S3 → coordenar el merge.
5. S5  tls              → ahora S3 hace que el path se ejecute; el hardening
                          es real.
6. S7  concurrency      → depende de S2 (test de cancelación) y S5 (join timeout)
7. S6  sse + WU-4       → el gap funcional. Va después de S3 porque ahora
                          el parser se ejecuta.
8. S8  logger           → independiente, se puede mover antes si hay hueco.
9. S9  debt             → último en código. Consolida lo que S1-S8 dejaron.
10. S10 docs            → escribe sobre el estado final, no el intermedio.
```

⚠️ **Coordinación de merges**: S3 y S4 tocan `src/runtime.zig`. **No mergear en paralelo**; o S3 primero y S4 rebase, o uno tras otro.

### 2.2 Gates de QA (AGENTS.md §10, sin excepciones)

Cada slice, antes de merge:

```bash
just build && just build-safe && just build-fast   # 1. builds PRIMERO
just check                                           # 2. guards estáticos
just test-all                                        # 3. tests
just verify                                          # 4. 3-mode compile
just ci                                              # 5. Podman, LAST
```

**Gate de RDD**: cada WU produce un receipt con:
- El commit SHA
- El test RED (nombre + por qué falla antes)
- El output del test RED antes del fix (**capturado, no de memoria**)
- El output del test VERDE después
- `just ci` en verde

⚠️ **Regla nueva que este plan impone**: *"Un WU sin output de test RED capturado no se mergea."* El proyecto tiene 500+ tests y esa cifra no impidió que 41 bugs sobrevivieran. mergeable.

### 2.3 Commits

Conventional Commits, **siempre `-S`** (GPG), **nunca `--no-verify`**, **sin AI co-author**:

```
fix(sandbox): fail-closed on landlock/seccomp setup failure
fix(sandbox): validate seccomp_data.arch in production BPF
fix(sandbox): wire TOOLS_PROFILE.allowed_syscalls into seccomp filter
fix(sandbox): nul-terminate argv and reject empty argv
refactor(sandbox): remove startup_allow_syscalls time bomb
...
fix(runtime): poll cancel_pipe with correct nfds
fix(tui): stop TUI from consuming tui_to_agent
fix(channels): inline buffers for ToolError.message
...
docs: correct stale tls_conn.zig references
```

---

## 3. Riesgos del plan

| Riesgo | Probabilidad | Mitigación |
|---|---|---|
| **Fail-closed rompe la ejecución en kernels sin Landlock** (< 5.13) | Media | El proyecto ya exige ≥ 5.13 (§4.4). Añadir un check de versión **antes** de fail-closed, con un mensaje claro, no un `exit_group(1)` mudo |
| **S1 rompe CI**: el contenedor Podman Alpine puede no tener Landlock ABI v1 | Media | Verificar la versión de kernel del CI. Si el CI no soporta Landlock, S1 necesita una flag de escape para CI que **sí** registre loudly |
| **S3 expone bugs latentes en `api_client`/`api_sse`** que estavam dormidos por ser código muerto | **Alta** | **Esperado y deseado.** Es el punto de S3. Presuponer 5-10 findings nuevos en S5/S6 |
| **S2 descubre que más tests de los contados mienten** | Media | Bajar el conteo de 41 findings a medida que S2 avanza. El informe es un snapshot, no un contrato |
| **S9 (debt) se infla y se vuelve un mega-PR** | Media | Límite duro: 4 WU. Si se pasa, es un slice nuevo |
| **El usuario no puede correr `zig build` localmente** | Baja | Ya confirmó que compila. Los tests RED son ejecutables en su máquina |

---

## 4. Lo que este plan NO arregla (declarado explícitamente)

Para que nadie asuma cobertura que no existe:

| No arreglado | Por qué | Dónde va |
|---|---|---|
| **Zig 0.16 `--listen=-` IPC hang** (§11.1) | Bug upstream de `std.zig.Server`. No es código del proyecto. Requiere investigation upstream | Track upstream, ver §13.1 del context doc |
| **Valgrind SIGILL en ReleaseFast+LTO** (§11.2) | Toolchain externa | §13.2 |
| **TSan no compila** (§11.3) | `<linux/scc.h>` removido del kernel | §13.3. **Mitigación parcial**: tests de concurrencia reales con `testing.allocator` (S2) + helgrind |
| **Port a macOS** | Fuera de scope de remediación | Roadmap §5.2 |
| **Release automation / v1.0.0 tag** | Producto, no ingeniería | §13.6 |
| **Split de `modal.zig`** | Slice grande y riesgoso, hay P0s primero | Phase 3 (S9/WU-9.4 lo documenta) |
| **`slice 7 PR1 (#55) cerrado sin merge`** | Decisión de proceso pasada | §13.4 |

---

## 5. Métricas de éxito

Definí esto **antes** de empezar, para no mover la portería:

| Métrica | Hoy | Objetivo |
|---|---|---|
| Findings P0 abiertos | 13 | **0** |
| Findings P1 abiertos | 6 | **0** |
| Tests que pasan sin probar nada | 14 (9 grep + 5 tautológicos) | **0** |
| Variantes de `Event` sin productor | 5 | **0** |
| Slices a un string de `sdd/*` | 30 | **0** |
| **Tests de seguridad que fallan si el sandbox se rompe** | **0** | **≥ 5** |
| Cobertura de enforcement de sandbox | 0/26 | ≥ 8/26 reales |

**La métrica que importa es la del sandbox.** Si al terminar de S1 hay **un solo test que falle si alguien revierte el orden de `prctl` y `restrictSelf`**, el proyecto habrá ganado más en confianza que en las otras 40 correcciones juntas.

---

## 6. Resumen ejecutivo del plan

**10 slices · ~34 work units · 41 findings cubiertos.**

El trabajo no es "arreglar 41 bugs" — es **restaurar la capacidad del proyecto de detectar sus propios bugs**. Slice 7 se mergeó con el sandbox en fail-open, 7 use-after-free, y el path LLM muerto, y todo pasó: 500+ tests verdes, CI verde, `zig build run` verde.

La causa no es disciplina del developer — el código de `src/terminal/` es excelente y muestra que el equipo sabe escribir bien. La causa es que **los tests nunca ejecutaron el código que rompió**.

Por eso S2 va segundo, y por eso el gate de "un WU sin output de test RED capturado no se mergea" es la regla más importante de este documento.

**Empieza por S1. Hoy el harness ejecuta código no confinado con la etiqueta de "sandboxed".**

---

*Fin del plan. Para los detalles completos de cada finding, ver `AUDIT-REPORT.md` (3.014 líneas).*
