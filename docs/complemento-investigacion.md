# Anexo Técnico de Arquitectura y Decisiones de Diseño

**Proyecto:** AI Harness Engineering TUI (Zig Native)  
**Autor:** José Luis  
**Estado:** Especificación Complementaria de Implementación

---

## 1. Estrategia de Compilación y Optimización del Binario (Zig Toolchain)

Para cumplir con las métricas del RNF-01 ($\ge 60$ FPS, latencia de renderizado $\le 16.6$ ms) y RNF-03 (Arranque en frío $\le 50$ ms), la tubería de compilación se aleja de las abstracciones pesadas de runtimes tradicionales y explota las pasadas de optimización de LLVM a nivel de hardware nativo.

### 1.1 Configuración de Banderas en `build.zig`

- **Modo de Optimización:** `ReleaseFast` para build final de producción (`-Doptimize=ReleaseFast`).
  - _Efecto:_ Desactiva las comprobaciones de seguridad en tiempo de ejecución (`Runtime Safety = false`) y habilita vectorización SIMD agresiva en bucles de parsing de texto.
  - _Advertencia Crítica:_ El desarrollo activo **debe** realizarse en `Debug` o `ReleaseSafe` utilizando `std.heap.GeneralPurposeAllocator`. Saltarse este paso e iterar directamente en `ReleaseFast` ocultará _undefined behavior_ y desbordamientos de búfer que causarán cierres inesperados silenciosos (_segfaults_) en la TUI.
- **Target de Microarquitectura:** `-Dtarget=native` (compilación orientada al procesador anfitrión, aprovechando extensiones vectoriales AVX-512/FMA si están disponibles).
- **Link-Time Optimization (LTO):** `exe.want_lto = true` para permitir _inlining_ intermodular y eliminación de código muerto (_Dead Code Elimination_) a nivel global.
- **Depuración y Símbolos:** `exe.root_module.strip = true` para eliminar la tabla de símbolos y reducir la sobrecarga de lectura por parte del cargador ELF del sistema operativo durante el arranque.
- **Modelo Concurrente:** `exe.single_threaded = false` para preservar primitivas de sincronización multihilo atómicas y eficientes en hardware multinúcleo.

---

## 2. Capa de Presentación TUI: Evaluación y Adopción de `libvaxis`

Se descarta la implementación de un motor de secuencias ANSI desde cero por no representar un valor arquitectónico relevante respecto al costo de desarrollo ($2\text{--}3$ meses de trabajo duplicado en parsing VT100, manejo de `/dev/tty` e interrupciones `SIGWINCH`).

### 2.1 Justificación Técnica de `libvaxis`

1. **Zero-Dependency C:** Escrito en Zig puro, sin vinculación a `ncurses` o cabeceras C obsoletas.
2. **Protocolos Modernos:** Soporte nativo del _Kitty Keyboard Protocol_ (captura de combinaciones complejas de teclas sin ambigüedad) y renderizado sincronizado (prevención de _screen tearing_ durante ráfagas de texto via SSE).
3. **TrueColor 24-bit:** Manipulación de paletas de color para resaltado de sintaxis en Markdown y diffs de código sin pérdida de fidelidad.

### 2.2 Patrón de Asignación de Memoria por Cuadro (Frame Arena)

Para garantizar la ausencia total de fugas de memoria en la interfaz y eliminar la fragmentación del _heap_ en sesiones prolongadas:

- Se adopta un `std.heap.ArenaAllocator` dedicado exclusivamente a la capa visual (`frame_arena`).
- En cada iteración del bucle de eventos visuales, se invoca `_ = frame_arena.reset(.retain_capacity)`.
- **Costo de Liberación:** $\mathcal{O}(1)$ constante por cuadro.

---

## 3. Arquitectura de Concurrencia y Modelo de Hilos

El sistema se estructura en tres capas de ejecución estrictamente desacopladas para evitar el bloqueo del hilo gráfico:

@[arquitectura.png]

---

## 4. Custodia de Credenciales y Orden de Precedencia

El software aplica un esquema estandarizado para la resolución de claves API de múltiples proveedores (Minimax, Anthropic, OpenAI):

1. **Variables de Entorno (`$MINIMAX_API_KEY`):** Prioridad máxima. Sobrescribe cualquier configuración en disco (ideal para pruebas y entornos automatizados).
2. **Secret Service Nativo (Linux DBus / `libsecret`):** Almacenamiento preferente en entorno de escritorio mediante consultas IPC cifradas al Keyring del sistema.
3. **Archivo de Configuración XDG (`~/.config/ai-harness/credentials.json`):** Fallback local bajo el estándar XDG.
   - **Mecanismo de Seguridad:** Creación de archivo obligatoria con flag POSIX `0o600` (`-rw-------`). Lectura y escritura restringida exclusivamente al usuario dueño del proceso a nivel de sistema de archivos.

---

## 5. Integración con Minimax API (Debug I/O & Streaming)

Minimax servirá como el primer motor de validación para afinar el pipeline de comunicación del harness:

- **Endpoint:** `https://api.minimaxi.chat/v1/text/chatcompletion_v2`
- **Transporte:** HTTP/1.1 o HTTP/2 asíncrono sobre `std.net.http.Client`.
- **Formato de Respuesta:** _Server-Sent Events_ (`stream: true`). Los fragmentos de texto se leen en búferes estáticos y se envían inmediatamente al hilo principal a través de la cola de eventos compartida.

---

## 6. Observabilidad y Diagnóstico Desacoplado (Headless Logging)

Debido a que la TUI toma el control de la terminal anfitriona en modo _raw_, **está estrictamente prohibido escribir en `stdout` o `stderr`**.

- **Mecanismo:** Todos los eventos de I/O de red, transiciones de estado del agente, payloads JSON de Minimax y errores de ejecución de herramientas se canalizan hacia `/tmp/ai-harness-debug.log`.
- **Workflow de Depuración:** Monitoreo en paralelo desde una segunda ventana de terminal mediante:
  ```bash
  tail -f /tmp/ai-harness-debug.log
  ```

---

### Mi evaluación crítica sobre este plan

1. **El punto débil de `libvaxis`:** Aunque es la mejor opción actual en Zig, el ecosistema de librerías en Zig cambia rápido. `libvaxis` todavía no tiene el nivel de madurez ni la cantidad de _widgets_ construidos que tiene `ratatui` en Rust. Vas a tener que construir manualmente varios componentes de UI (como áreas de texto con scroll suave o renderizadores de Markdown estilizados).
2. **La API HTTP de la Librería Estándar (`std.net.http`):** Ha mejorado significativamente en versiones recientes de Zig, pero manejar reconexiones automáticas, timeouts finos y parsing estricto de SSE a bajo nivel requiere probar minuciosamente los casos de borde (por ejemplo, desconexiones repentinas de red a mitad del streaming de Minimax).

<ElicitationsGroup message="¿Cuál es el siguiente paso práctico con el que deseas avanzar?">
  <Elicitation label="Escribir la plantilla base del proyecto en Zig (build.zig + estructura de carpetas)" query="Crea la estructura de archivos y el build.zig completo optimizado para empezar a programar la TUI con libvaxis y el cliente HTTP."/>
  <Elicitation label="Implementar el sistema de logs desacoplado para /tmp/ai-harness-debug.log" query="Muestra la implementación en Zig de un logger thread-safe que escriba eventos y payloads JSON en /tmp/ai-harness-debug.log sin bloquear la TUI."/>
</ElicitationsGroup>
