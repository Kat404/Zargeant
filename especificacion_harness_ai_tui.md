# Especificación de Diseño de Software para un Harness de Ingeniería de Inteligencia Artificial en TUI

## Análisis Técnico en Rust y Zig

---

## 1. Arquitectura General del Sistema y Fundamentos del AI Harness Engineering

La evolución de los sistemas de desarrollo asistidos por inteligencia artificial ha desplazado la frontera de la innovación desde el diseño de instrucciones (_prompt engineering_) hacia la creación de entornos de ejecución estructurados, disciplina denominada **ingeniería de harness para IA (AI Harness Engineering)**.

En los entornos donde los modelos fundacionales operan de forma autónoma, la capacidad de ingeniería del sistema no reside en la inteligencia latente del modelo de lenguaje, sino en la infraestructura que rodea, restringe y realimenta dicho modelo.

La relación funcional del sistema se formaliza mediante la siguiente ecuación:

$$\text{Agente} = \text{Modelo} + \text{Harness}$$

En esta arquitectura:

- **El modelo** aporta capacidad de razonamiento probabilístico y generación de código.
- **El harness** provee la agencia operativa, la máquina de estados, los límites de permisos, la memoria de proyecto y las verificaciones deterministas.

---

### 1.1. La Brecha de Autonomía (_Autonomy Gap_) y Taxonomía de Fallos

Sin la presencia de un harness estructurado, los agentes de codificación incurren en la denominada **brecha de autonomía** (_autonomy gap_), la cual representa la discrepancia entre la habilidad local de un modelo para generar fragmentos de código correctos y la capacidad real del sistema para completar tareas complejas de ingeniería de software sin intervención humana.

Esta brecha se manifiesta en una taxonomía de fallos recurrentes:

- $F_{\text{context}}$: Pérdida de contexto.
- $F_{\text{tool}}$: Invocación errónea de herramientas.
- $F_{\text{feedback}}$: Incapacidad para interpretar la realimentación de compiladores.
- $F_{\text{verify}}$: Omisión de protocolos de verificación.
- $F_{\text{recovery}}$: Estancamiento en ciclos de recuperación.
- $F_{\text{entropy}}$: Acumulación de código redundante o degradación arquitectónica.

---

### 1.2. Responsabilidades Fundamentales del Harness

El harness se concibe como un **sustrato de ejecución en tiempo real** (_runtime substrate_) situado entre el modelo fundacional y el entorno de software local (repositorio, compiladores, suites de pruebas y sistema operativo).

El marco conceptual moderno establece **once responsabilidades fundamentales**:

1. **Gestor de especificación de tareas:** Procesará la intención del usuario y la traduce en objetivos ejecutables.
2. **Motor de selección de contexto:** Aplica técnicas de revelación progresiva para inyectar la cantidad óptima de artefactos en la ventana de atención del modelo.
3. **Superficie de acceso a herramientas:** Canaliza la ejecución de funciones mediante protocolos estandarizados como el Protocolo de Contexto de Modelo (_Model Context Protocol_ o **MCP**) o entornos de ejecución de código directo (_Code Mode_).
4. **Memoria de proyecto:** Conserva el conocimiento persistente a través de sesiones en archivos de restricciones del repositorio.
5. **Máquina de estado de tareas:** Rastrea la progresión del flujo de trabajo en etapas secuenciales o gráficos dirigidos acíclicos (**DAGs**).
6. **Capa de observabilidad:** Registra la totalidad de eventos, invocaciones y decisiones para su auditoría.
7. **Subsistema de atribución de fallos:** Clasifica los errores en tiempo de ejecución para orquestar estrategias de autorrecuperación.
8. **Protocolo de verificación:** Ejecuta validaciones deterministas como análisis estático, _linters_ y suites de pruebas.
9. **Límite de permisos y aislamiento (_sandboxing_):** Impone restricciones operativas bajo el principio de mínimo privilegio.
10. **Auditor de entropía:** Detecta e interpola la acumulación de inconsistencias en el código fuente.
11. **Registro de intervenciones humanas:** Almacena las correcciones realizadas por los desarrolladores para refinar los bucles de realimentación continuos.

---

### 1.3. Arquitectura en Entornos TUI

En el contexto de una interfaz de usuario basada en terminal (**TUI**) como _OpenCode_ o _Pi_ (_oh-my-pi_), el harness debe estar arquitectónicamente desacoplado de la capa de presentación:

- **Hilo principal (Renderizado TUI):** Mantiene una frecuencia constante de **60 cuadros por segundo (FPS)**.
- **Hilos secundarios (Trabajadores asíncronos):** Realizan las llamadas asíncronas de red a la API del modelo de lenguaje y la ejecución de subprocesos pesados (compilación de código, pruebas unitarias, etc.).

---

## 2. Requisitos del Sistema (Formato SDD)

### 2.1. Requisitos Funcionales

| ID        | Subsistema                     | Descripción Funcional                                                                                                         | Criterio de Aceptación                                                                                                    |
| :-------- | :----------------------------- | :---------------------------------------------------------------------------------------------------------------------------- | :------------------------------------------------------------------------------------------------------------------------ |
| **RF-01** | **Gestión de Contexto**        | Indexación incremental del árbol del repositorio mediante análisis del árbol de sintaxis abstracta (AST) y mapas de símbolos. | Generación de un mapa de símbolos del repositorio en menos de **100 ms** tras detectar cambios en el sistema de archivos. |
| **RF-02** | **Superficie de Herramientas** | Soporte dinámico para servidores MCP y ejecución de herramientas en entornos aislados.                                        | Validación rigurosa de los argumentos de cada herramienta contra un esquema JSON previo a su ejecución.                   |
| **RF-03** | **Interfaz TUI**               | Renderizado reactivo y flujo en tiempo real (_streaming_) de la respuesta del modelo de lenguaje en formato Markdown.         | Ausencia absoluta de congelamiento de la pantalla o parpadeo (_flicker_) durante la llegada de datos por red.             |
| **RF-04** | **Verificación en Bucle**      | Invocación automática de herramientas de validación estática y pruebas al finalizar las ediciones de código.                  | Inyección automática de los mensajes de error de compilación en el siguiente ciclo de inferencia del agente.              |
| **RF-05** | **Control de Estado**          | Creación de puntos de restauración (_checkpoints_) del árbol de archivos mediante deltas de Git o parches internos.           | Capacidad de revertir completamente las modificaciones del agente al estado previo a la tarea con un solo comando.        |

---

### 2.2. Requisitos No Funcionales

| ID         | Categoría                    | Métrica u Objetivo                                                                            | Restricción Técnica                                                                                   |
| :--------- | :--------------------------- | :-------------------------------------------------------------------------------------------- | :---------------------------------------------------------------------------------------------------- |
| **RNF-01** | **Rendimiento Visual**       | Tasa de actualización constante $\ge 60$ FPS ($\le 16.6$ ms por cuadro).                      | El hilo de renderizado TUI no debe realizar operaciones de I/O de disco, red o llamadas bloqueantes.  |
| **RNF-02** | **Consumo de Memoria**       | Huella base $\le 30$ MB en reposo; uso máximo $\le 250$ MB durante contextos extensos.        | Implementación de buffers circulares y liberación proactiva de cachés de contexto inactivo.           |
| **RNF-03** | **Latencia de Arranque**     | Tiempo de ejecución desde arranque en frío (_cold start_) hasta la TUI operativa $\le 50$ ms. | Carga diferida (_lazy loading_) de submódulos de herramientas y conexiones a servidores MCP externos. |
| **RNF-04** | **Aislamiento de Seguridad** | Aislamiento de subprocesos generados por el agente contra el sistema operativo anfitrión.     | Aplicación estricta de filtros Seccomp-BPF y restricciones de sistema de archivos vía Landlock LSM.   |

---

## 3. Especificación Técnica e Implementación en Rust

El lenguaje de programación **Rust** destaca por sus garantías de seguridad de memoria en tiempo de compilación sin recolector de basura, respaldado por un ecosistema maduro para la construcción de interfaces TUI asíncronas.

### 3.1. Evaluación de Componentes: Crates vs. Desarrollo Desde Cero

| Subsistema del Harness         | Crate Recomendado                | Alternativa _From Scratch_                                                        | Evaluación de Elección                                                                                                                          |
| :----------------------------- | :------------------------------- | :-------------------------------------------------------------------------------- | :---------------------------------------------------------------------------------------------------------------------------------------------- |
| **Motor de Renderizado TUI**   | `ratatui` + `crossterm`          | Emisión manual de secuencias de escape ANSI sobre `/dev/tty`                      | **Utilizar Crate:** `ratatui` ofrece primitivas de doble buffer, cálculo de recortes (_clipping_) y layouts reactivos altamente optimizados.    |
| **Runtime Asíncrono**          | `tokio`                          | Bucle de eventos propio implementado directamente con `mio` o `epoll`             | **Utilizar Crate:** `tokio` abstrae de manera eficiente el reactor de I/O y el programador de tareas asíncronas con M-hilos sobre N-hilos.      |
| **Aislamiento (_Sandboxing_)** | `landlock` + `seccomp-sys`       | Invocación de llamadas al sistema mediante ensamblador o FFI manual               | **Enfoque Híbrido:** Reorganizar abstracciones sobre `landlock` para el sistema de archivos y configurar filtros Seccomp-BPF personalizados.    |
| **Almacenamiento de Secretos** | `keyring`                        | Implementación manual de llamadas IPC a DBus (Linux) y Security Framework (macOS) | **Utilizar Crate:** La caja `keyring` abstrae la persistencia segura en los almacenes nativos del sistema operativo.                            |
| **Protocolo HTTP / MCP**       | `reqwest` + `eventsource-stream` | Cliente HTTP/1.1 y HTTP/2 construido directamente sobre `tokio::net::TcpStream`   | **Desde Cero / Ligero:** Implementar un cliente HTTP enfocado exclusivamente en _streaming_ SSE para eliminar dependencias transitivas pesadas. |

---

### 3.2. Arquitectura de Concurrencia y Bucle de Eventos

La arquitectura en Rust se articula mediante procesamiento de mensajes asíncronos con `tokio`, dividiendo la responsabilidad en tres tareas independientes comunicadas por canales delimitados (_bounded channels_):

1. **Tarea de Interfaz de Usuario (Main Thread):**
   - Captura eventos de entrada del teclado/ratón con `crossterm`.
   - Recibe actualizaciones de estado desde el canal de eventos de forma no bloqueante.
   - Calcula la geometría de componentes visuales y ejecuta el renderizado con `ratatui`.
2. **Tarea del Runtime del Agente:**
   - Mantiene la máquina de estados interna y orquesta el historial de conversación.
   - Envía solicitudes HTTP mediante _streaming_ a las APIs de los LLMs.
   - Empaqueta fragmentos de texto (_chunks_) en eventos hacia la TUI para su renderizado inmediato.
3. **Tarea Ejecutora de Herramientas:**
   - Gestiona un grupo de hilos dedicados (_thread pool_) para invocar subprocesos, herramientas locales o servidores MCP externos.
   - Aplica los perfiles de aislamiento de seguridad antes de ejecutar mandatos.

---

### 3.3. Gestión de Memoria y Propiedad de Datos

- **Manejo de Cadenas y Flujos:** Se emplean estructuras `Bytes` de `tokio` o envoltorios `Arc<str>` para compartir bloques de texto inmutables entre el runtime del agente y la capa de presentación TUI sin duplicación de memoria.
- **Modelo de Renderizado TUI:** `ratatui` adopta un modelo de modo inmediato adaptado. Para evitar asignaciones masivas en el bucle visual, se utilizan arenas de asignación a corto plazo y **buffers circulares** (_ring buffers_) para trazas de registros (_logs_) y salidas de terminal, garantizando una huella de RAM acotada.

---

### 3.4. Aislamiento de Seguridad y Custodia de Credenciales

- **Linux Sandboxing:**
  1. _Landlock LSM:_ Restringe operaciones de lectura/escritura exclusivamente al directorio del repositorio, bloqueando acceso a carpetas sensibles (`/etc`, `/home`, `/root`).
  2. _Seccomp-BPF:_ Deshabilita la creación de interfaces de red no autorizadas, inyección de código mediante `ptrace` y operaciones de montaje.
- **macOS Sandboxing:** Envoltorio mediante `sandbox_exec` parametrizado con perfiles expresados en **SBPL** (_Seatbelt Sandbox Profile Language_).
- **Custodia de Credenciales:** Delegación a la caja `keyring`, la cual interactúa con APIs nativas (_Secret Service_ vía DBus en Linux, _Keychain_ en macOS, _Credential Manager_ en Windows).

---

## 4. Especificación Técnica e Implementación en Zig

El lenguaje **Zig** ofrece control absoluto sobre el diseño del sistema: ausencia de comportamiento oculto, gestión explícita de memoria mediante pasaje de asignadores (_allocators_), metaprogramación en tiempo de compilación (`comptime`) e interop directa con C y llamadas al sistema nativas.

### 4.1. Evaluación de Módulos: Librerías vs. Desarrollo Desde Cero

| Subsistema del Harness         | Módulo Recomendado              | Alternativa _From Scratch_                                            | Evaluación de Elección                                                                                                                                                   |
| :----------------------------- | :------------------------------ | :-------------------------------------------------------------------- | :----------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Motor de Renderizado TUI**   | `libvaxis`                      | Implementación manual del parser VT100/ANSI y manipulación TTY        | **Utilizar Librería:** `libvaxis` proporciona un diseño moderno en Zig nativo (protocolo Kitty, sincronización de cuadros, gráficos nativos) sin depender de `terminfo`. |
| **Bucle de Eventos / I/O**     | `std.Thread` + `std.posix.poll` | Integración directa de `io_uring` o `epoll` mediante syscalls nativas | **Desde Cero:** La librería estándar de Zig contiene interfaces POSIX eficientes para construir un reactor de I/O a medida sin sobrecarga.                               |
| **Aislamiento (_Sandboxing_)** | Directo vía `std.os.linux`      | Creación de runtime de contenedores minimalista en Zig                | **Desde Cero:** Invocar Landlock y Seccomp-BPF directamente en Zig elimina dependencias C y otorga control total.                                                        |
| **Almacenamiento de Secretos** | Integración C vía `@cImport`    | Implementación desde cero de la pila del protocolo DBus               | **Enfoque Híbrido:** Importar encabezados de `libsecret-1` o librerías nativas usando las capacidades FFI de Zig.                                                        |
| **Parsing HTTP / JSON**        | `std.net.http` + `std.json`     | Parser de tokens JSON personalizado con metaprogramación `comptime`   | **Utilizar `std`:** La librería estándar posee utilidades de red y JSON maduras y sin asignaciones ocultas.                                                              |

---

### 4.2. Arquitectura del Bucle de Eventos y Concurrencia

Zig utiliza un modelo de subprocesos explícitos coordinados por colas de eventos libres de bloqueos (_lock-free queues_) o cerrojos livianos (`std.Thread.Mutex`):

- **Hilo Principal (Visual TUI):** Ejecuta el bucle de eventos de `libvaxis`, interceptando entradas de teclado, lecturas de terminal y señales `SIGWINCH`, despachando eventos dentro de una unión etiquetada (_tagged union_).
- **Hilo Secundario (Runtime del Agente):** Aloja la máquina de estados, gestiona conexiones HTTP con `std.net.http`, parsea eventos SSE y encola mensajes hacia el hilo principal.
- **Invocación de Herramientas:** Engendra subprocesos aislados mediante la API de procesos de Zig, capturando flujos `stdout` y `stderr`.

---

### 4.3. Gestión de Memoria y Patrones de Asignación

El principio de Zig de cero asignaciones ocultas permite definir estrategias explícitas:

- **Arena de Cuadro (_Frame Arena_):** Para la capa TUI se asigna un `std.heap.ArenaAllocator`. Durante el renderizado de cada cuadro, los cálculos temporales de texto y color consumen de esta arena. Al volcar el cuadro a la terminal, se invoca `reset()`, liberando toda la memoria consumida en $\mathcal{O}(1)$ sin fugas.
- **Memoria Persistente:** Para el historial de mensajes y árbol de contexto se utiliza `std.heap.GeneralPurposeAllocator` (GPA) en desarrollo para detección de fugas, y asignadores de páginas directo en producción.

---

### 4.4. Aislamiento de Seguridad y Custodia de Credenciales

- **Contención Nativa:** Creación de espacios de nombres (_namespaces_) de usuario, PID y montajes mediante las llamadas al sistema `unshare` o `clone`.
- **Landlock y Seccomp:**
  - Configuración de Landlock mediante `std.os.linux.landlock_create_ruleset` y `std.os.linux.landlock_add_rule`.
  - Generación de código BPF para Seccomp en tiempo de compilación con `comptime`.
- **Custodia de Credenciales:** Uso del compilador C integrado de Zig para importar cabeceras mediante `@cImport({ @cInclude("libsecret/secret.h"); })`, accediendo a la API del sistema con rendimiento C puro.

---

## 5. Análisis Comparativo Transversal y Directrices de Implementación

### 5.1. Comparativa Cualitativa y Cuantitativa

| Métrica / Dimensión Técnica           | Implementación en Rust                                                  | Implementación en Zig                                                                                  |
| :------------------------------------ | :---------------------------------------------------------------------- | :----------------------------------------------------------------------------------------------------- |
| **Tamaño del Binario Final**          | **5 MB a 15 MB** (aplicando LTO, `panic=abort` y `strip`).              | **200 KB a 1.5 MB** (binarios nativos extremadamente pequeños).                                        |
| **Tiempo de Arranque (_Cold Start_)** | **~15 ms a 40 ms**.                                                     | **< 5 ms** (arranque prácticamente instantáneo).                                                       |
| **Consumo Base de RAM**               | **~12 MB a 25 MB**.                                                     | **~2 MB a 8 MB**.                                                                                      |
| **Madurez del Ecosistema TUI**        | **Alta:** `ratatui` posee un ecosistema masivo de componentes visuales. | **Media/En Crecimiento:** `libvaxis` ofrece características modernas pero menor diversidad de widgets. |
| **Modelo de Concurrencia**            | Basado en el paradigma asíncrono `async`/`await` con Tokio.             | Basado en subprocesos explícitos, colas de eventos y primitivas del SO.                                |
| **Garantías de Seguridad de Memoria** | Verificación estática formal en compilación vía _Borrow Checker_.       | Gestión manual explícita mediante _Allocators_; detección vía GPA en _runtime_.                        |
| **Simplicidad para _Sandboxing_**     | Requiere cajas FFI wrappers sobre bibliotecas C de Linux.               | **Excelente:** Invocación directa de llamadas al sistema del kernel de Linux sin capas intermedias.    |

---

### 5.2. Mitigación de Vulnerabilidades de Agentes y Control del Entorno

Un riesgo crítico en agentes autónomos es el **secuestro de objetivos** (_Goal Hijacking_), donde un atacante introduce instrucciones maliciosas ocultas en comentarios de código, _pull requests_ o documentación que el agente analiza.

**Medidas de Contención:**

1. **Delimitación Estricta de Contexto:** Separación inequívoca entre instrucciones del sistema, mensajes del usuario y datos no fiables recuperados del repositorio.
2. **Sanitización de Salidas:** Eliminación de secuencias de control ANSI no autorizadas o tokens de control del modelo de lenguaje en la salida de las herramientas.

---

### 5.3. Arquitectura de Contexto Mediante Revelación Progresiva

Para evitar la saturación de la ventana de atención del modelo, el harness aplica **tres niveles jerárquicos de revelación progresiva**:

```
+-------------------------------------------------------------------+
| NIVEL 1: Mapa Global del Repositorio                             |
| Estructura de directorios, límites de módulos, restricciones AGENTS.md |
+-------------------------------------------------------------------+
                                  |
                                  v
+-------------------------------------------------------------------+
| NIVEL 2: Esqueletos de Archivos y Firmas de Código                |
| Parsers AST extraen firmas de funciones, structs y tipos exportados |
+-------------------------------------------------------------------+
                                  |
                                  v
+-------------------------------------------------------------------+
| NIVEL 3: Fragmento de Código Detallado (*Code Slices*)            |
| Rebanada exacta del código a modificar con dependencias directas |
+-------------------------------------------------------------------+
```

---

## 6. Conclusiones y Recomendaciones Arquitectónicas

1. **Adopción de Rust (`ratatui` + `tokio`):**
   - **Recomendado para:** Equipos que prioricen velocidad de desarrollo, ecosistema rico de UI preconstruido y máximas garantías de seguridad de memoria estática.
   - **Fortaleza:** Excelente manejo de concurrencia asíncrona para coordinar flujos HTTP concurrentes y eventos de interfaz.

2. **Adopción de Zig (`libvaxis` + `std`):**
   - **Recomendado para:** Proyectos que busquen la máxima eficiencia operativa, arranque en frío instantáneo ($\le 5$ ms), huella de RAM imperceptible ($\le 8$ MB) y _sandboxing_ mediante llamadas al sistema nativas sin dependencias ocultas.
   - **Fortaleza:** Control determinista de memoria mediante _arenas_ y vinculación directa con el kernel.

En ambos lenguajes, la combinación de **verificaciones deterministas en bucle cerrado**, **aislamiento vía Landlock LSM** y **gestión de contexto por revelación progresiva** constituye el pilar fundamental para construir un _AI Harness_ de nivel profesional en TUI.
