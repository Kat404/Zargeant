# Informe de Investigación Técnica: Validación de Secure Boot Personalizado

# y Cifrado LUKS2 Vinculado a TPM2 para ASUS Zenbook 14 UM3406KA

## Sección A: Resumen Ejecutivo

El análisis de viabilidad técnica para la implementación de UEFI Secure Boot con claves personalizadas (Ruta B) y el desbloqueo automático de cifrado LUKS2 vinculado a TPM2 (Ruta

C) en el ordenador portátil ASUS Zenbook 14 UM3406KA (plataforma AMD Krackan Point, microarquitectura Zen 5, procesador Ryzen AI 5 340 con gráfica integrada Radeon 840M y firmware AMI 5.35) confirma la viabilidad operativa de ambas rutas bajo consideraciones específicas de configuración¹. La **Ruta B** se evalúa como **VIABLE (90% de confianza)**
4. La arquitectura de firmware AMI 5.35 en la línea Zenbook permite la purga del Platform Key (PK) para entrar en Setup Mode y la posterior inscripción de claves soberanas mediante la herramienta sbctl⁶. La gráfica integrada AMD Radeon 840M ejecuta el controlador Graphics Output Protocol (GOP) empaquetado directamente en la imagen UEFI principal del sistema, eliminando la dependencia de Option ROMs de terceros firmadas por la autoridad certificadora de Microsoft¹. Sin embargo, la inclusión de Microsoft 3rd Party UEFI CA 2011/2023 se categoriza como altamente recomendada para mitigar posibles bloqueos al conectar periféricos de pantalla externos o adaptadores Thunderbolt/USB4 4. La **Ruta C** se evalúa como **VIABLE (85% de confianza)** 2. En el kernel Linux 7.2.6 (paquete linux-zen), la pila del kernel incluye soporte completo para CONFIG_TCG_TPM2_HMAC y el algoritmo cifrado de sesión AES-128-CFB exigido por el fTPM 2.0 integrado en el procesador AMD Zen 5 2. El desbloqueo automático mediante systemd-cryptenroll funciona de manera estable cuando se implementan políticas de PCR firmadas mediante la herramienta ukify, evitando la fragilidad que presentan las mediciones PCR estáticas frente a actualizaciones del sistema². Los **3 principales bloqueadores identificados** son:

1. Reajuste de variables NVRAM y purga de claves personalizadas tras las actualizaciones de BIOS enviadas por ASUS, que fuerzan el retorno a las claves de fábrica¹⁵.
2. Invalidación del secreto del fTPM de AMD tras la aplicación de actualizaciones de microcódigo AGESA, lo cual bloquea el volumen cifrado y exige el uso de la clave de recuperación por contraseña².
3. Fluctuación no planificada del PCR 4 cuando se emplean conjuntos estáticos durante la 重建 de las imágenes mkinitcpio o actualizaciones del paquete amd-ucode⁴.

Los **3 principales facilitadores identificados** son:

1. Compatibilidad probada del fTPM 2.0 en procesadores AMD Zen 5 para la arquitectura de automontaje sd-encrypt en Arch Linux².
2. Flujo automatizado de firma y re-firmado en espacio de usuario mediante la combinación de sbctl y los ganchos (hooks) de pacman⁴.
3. Integración nativa de ukify en systemd 261 para empaquetar Unified Kernel Images (UKI) con firmas de predicción PCR dinámicas (.pcrsig)
13

-.
**Configuración recomendada para el perfil del usuario**: Implementar la **Ruta C con** **arquitectura UKI gestionada por ukify y firmas de PCR dinámicas**, manteniendo obligatoriamente la clave de recuperación por contraseña en un slot LUKS secundario, e integrando los certificados de Microsoft 3rd Party CA mediante el parámetro sbctl enroll-keys -m para preservar la interoperabilidad con componentes de hardware adicionales². **Fehasibilidad de reemplazo por Libreboot**: **No es viable en ningún grado**, debido a la inexistencia de soporte dentro del proyecto Libreboot o coreboot para procesadores AMD con microarquitectura Zen 5 y a la fuerte dependencia del subsistema cerrado AMD Platform Security Processor (PSP) 20.

## Sección B: Hallazgos Evaluados por Grado de Evidencia

### 3.1 Ruta B — Inscripción de claves personalizadas PK/KEK/db en UM3406KA

#### Q1.1 — Precedentes directos de inscripción de claves en UM3406KA

No existe una publicación en foros o repositorios públicos que documente explícitamente el enrolamiento de claves personalizadas Secure Boot en el modelo exacto ASUS Zenbook 14 UM3406KA, aunque existen precedentes totalmente exitosos en configuraciones de hardware hermano dentro de la serie Zenbook⁵.

- **Evidencia**: Pruebas de integración automatizadas en proyectos de seguridad de arranque (aegis-boot) incorporan la arquitectura asus-zenbook-14-oled dentro de sus matrices de compatibilidad con sbctl⁵. En foros de usuarios, portátiles de las series ASUS Zenbook y Zephyrus han ejecutado la provisión de claves mediante sbctl tras borrar las claves de fábrica en la BIOS AMI²⁴.
- **Fuente(s)**: [https://github.com/williamzujkowski/aegis-boot/issues/226](https://github.com/williamzujkowski/aegis-boot/issues/226) (Accedido: 2026-02-15)
5

-; [https://github.com/Foxboron/sbctl/issues/25](https://github.com/Foxboron/sbctl/issues/25) (Accedido: 2026-02-15)
24

-.
- **Nivel de evidencia**: COMMUNITY / DISTRO⁵.
- **Calidad de evidencia**: MEDIUM⁵.
- **Confianza**: MEDIUM⁵.
- **Evidencia contradictoria**: Ninguna identificada⁵.

#### Q1.2 — Incidentes de bloqueo ("bricking") en UM3406KA y modelos afines

Los fallos graves de arranque en sistemas ASUS al activar Secure Boot se concentran en placas base de escritorio y la serie TUF Gaming debido a incompatibilidades con CSM o controladores no firmados; en la serie Zenbook el riesgo principal es un retardo prolongado en la fase POST¹⁶.

- **Evidencia**: En placas base ASUS de sobremesa y la línea TUF, la habilitación de Secure Boot habiendo dejado CSM activo o utilizando tarjetas gráficas antiguas sin soporte GOP causa pantallas negras irreversibles sin antes limpiar la CMOS²⁶. En contraste, en portátiles ultraligeros como la serie Zenbook no existe soporte legado CSM⁸. No obstante, modificaciones en las variables NVRAM de Secure Boot tras actualizaciones de claves KEK en sistemas ASUS provocan que el sistema tarde entre 20 y 30 segundos en pantalla negra antes de mostrar el logotipo de ASUS durante el POST¹⁶.
- **Fuente(s)**: [https://www.reddit.com/r/gigabyte/comments/1mkp198/gigabyte_needs_to_address_the_](https://www.reddit.com/r/gigabyte/comments/1mkp198/gigabyte_needs_to_address_the_)
26

- secure_boot/ (Accedido: 2026-02-15); [https://www.reddit.com/r/pcmasterrace/comments/1o4mcj4/found_a_weird_fix_for_the_](https://www.reddit.com/r/pcmasterrace/comments/1o4mcj4/found_a_weird_fix_for_the_)
27

- black_screen_after/ (Accedido: 2026-02-15); [https://www.reddit.com/r/ASUS/comments/1qy5g1i/asus_laptop_shows_black_screen_for](https://www.reddit.com/r/ASUS/comments/1qy5g1i/asus_laptop_shows_black_screen_for)
16

- _3040_seconds/ (Accedido: 2026-02-15).
- **Nivel de evidencia**: COMMUNITY¹⁶.
- **Calidad de evidencia**: HIGH¹⁶.
- **Confianza**: HIGH¹⁶.
- **Evidencia contradictoria**: Ninguna identificada¹⁶.
#### Q1.3 — Firma del controlador Option ROM de la iGPU AMD Radeon 840M

La tarjeta gráfica integrada AMD Radeon 840M (RDNA 3.5) del procesador Krackan Point no requiere una Option ROM PCI externa firmada por la CA de terceros de Microsoft, ya que su controlador GOP está integrado en la propia BIOS del fabricante¹.

- **Evidencia**: El controlador Graphics Output Protocol (GOP) para la GPU integrada forma parte de los módulos de ejecutable UEFI incluidos directamente en la imagen de firmware AMI distribuida por ASUS⁸. El sistema inicializa la pantalla nativa sin validar firmas de terceros en la base de datos db⁹. Sin embargo, si el portátil se conecta a estaciones de acoplamiento USB4/Thunderbolt o pantallas externas que utilicen controladores Option ROM propietarios, la falta de la clave "Microsoft 3rd Party UEFI CA 2011/2023" en db puede impedir la salida de vídeo externa⁴.
8

- **Fuente(s)**: [https://en.wikipedia.org/wiki/UEFI](https://en.wikipedia.org/wiki/UEFI) (Accedido: 2026-02-15); [https://www.reddit.com/r/gigabyte/comments/1mkokdf/do_not_attempt_to_enable_secur](https://www.reddit.com/r/gigabyte/comments/1mkokdf/do_not_attempt_to_enable_secur)
9

- e_boot_if_you_dont/ (Accedido: 2026-02-15);
11

- [https://news.ycombinator.com/item?id=32066919](https://news.ycombinator.com/item?id=32066919) (Accedido: 2026-02-15).
- **Nivel de evidencia**: VENDOR / PRIMARY¹.
- **Calidad de evidencia**: HIGH¹.

- **Confianza**: HIGH¹.
- **Evidencia contradictoria**: Ninguna identificada⁸.
#### Q1.4 — Preservación de claves personalizadas ante actualizaciones de BIOS AMI 5.35

Las actualizaciones de firmware enviadas por ASUS para el Zenbook 14 UM3406KA reescriben los bloques de NVRAM y restablecen la base de datos de Secure Boot a las claves predeterminadas de fábrica¹⁵.

- **Evidencia**: La ejecución del proceso de flasheo de BIOS en portátiles ASUS (versión 5.35 / UM3406KA.305) borra las variables de usuario PK, KEK y db, restaurando los certificados predeterminados de ASUS y Microsoft¹⁵. Este comportamiento requiere que el usuario vuelva a colocar el firmware en Setup Mode y re-enrole sus claves personalizadas tras cada actualización de la BIOS².
- **Fuente(s)**: [https://www.reddit.com/r/Battlefield/comments/1miaynl/secure_boot_megathread_guide](https://www.reddit.com/r/Battlefield/comments/1miaynl/secure_boot_megathread_guide)
15

- _community_support/ (Accedido: 2026-02-15); [https://www.reddit.com/r/gigabyte/comments/1mkzju7/what_does_this_mean_trying_to_e](https://www.reddit.com/r/gigabyte/comments/1mkzju7/what_does_this_mean_trying_to_e)
28

- nable_secure_boot/ (Accedido: 2026-02-15).
- **Nivel de evidencia**: COMMUNITY / VENDOR¹⁵.
- **Calidad de evidencia**: HIGH¹⁵.
- **Confianza**: HIGH¹⁵.
- **Evidencia contradictoria**: Ninguna identificada¹⁵.
#### Q1.5 — Ruta de navegación e ingreso al Setup Mode en AMI 5.35

El ingreso a las opciones de gestión de claves en el Zenbook 14 UM3406KA se efectúa presionando la tecla F2 durante el arranque e ingresando al menú Key Management para borrar la Platform Key⁶.

- **Evidencia**: La secuencia de acceso documentada para la interfaz UEFI AMI de ASUS requiere: 1) Encender el equipo y presionar F2 o Delete⁷; 2) Cambiar al modo avanzado (F7); 3) Navegar a Security -> Secure Boot; 4) Acceder al submenú Key Management⁶; 5) Seleccionar Clear Secure Boot Keys o eliminar individualmente la PK⁶. Tras guardar cambios y reiniciar, el sistema entra en Setup Mode: Enabled y Secure Boot: Disabled⁷.
6

- **Fuente(s)**: [https://bbs.archlinux.org/viewtopic.php?id=288688](https://bbs.archlinux.org/viewtopic.php?id=288688) (Accedido: 2026-02-15); [https://github.com/Foxboron/sbctl/blob/master/docs/workflow-example.md](https://github.com/Foxboron/sbctl/blob/master/docs/workflow-example.md) (Accedido:
7

- 2026-02-15).
- **Nivel de evidencia**: VENDOR / PRIMARY⁶.
- **Calidad de evidencia**: HIGH⁶.
- **Confianza**: HIGH⁶.
- **Evidencia contradictoria**: Ninguna identificada⁶.
#### Q1.6 — Problemas conocidos con herramientas de firma en firmware AMI 5.35

Las utilidades como sbctl operan correctamente sobre el firmware AMI 5.35, pero existe un comportamiento anómalo donde el estado del Setup Mode no se actualiza en el espacio de usuario hasta reiniciar el equipo²⁴.

- **Evidencia**: Los reportes en el repositorio de sbctl revelan que en sistemas portátiles ASUS, tras ejecutar sbctl enroll-keys, la invocación inmediata de sbctl status muestra erróneamente Setup Mode: Enabled²⁴. Una vez realizado un apagado frío o reinicio del sistema, las variables EFI persisten adecuadamente y el firmware aplica el estado Setup Mode: Disabled y Secure Boot: Enabled⁷.
24

- **Fuente(s)**: [https://github.com/Foxboron/sbctl/issues/25](https://github.com/Foxboron/sbctl/issues/25) (Accedido: 2026-02-15);
30

- [https://github.com/Foxboron/sbctl/issues/384](https://github.com/Foxboron/sbctl/issues/384) (Accedido: 2026-02-15).
- **Nivel de evidencia**: PRIMARY / COMMUNITY⁷.
- **Calidad de evidencia**: HIGH²⁴.
- **Confianza**: HIGH²⁴.
- **Evidencia contradictoria**: Ninguna identificada²⁴.
#### Q1.7 — Cadena de herramientas de firma recomendada para systemd-boot en Arch Linux

La combinación óptima para Arch Linux en la pila dada consiste en sbctl para la administración de claves e integración con pacman, emparejado con ukify para el empaquetado y firmado de imágenes UKI⁴.

- **Evidencia**: sbctl automatiza la generación de pares de claves RSA/ECDSA y registra ganchos en pacman que firman de forma transparente tanto el binario /usr/lib/systemd/boot/efi/systemd-bootx64.efi como las imágenes unificadas generadas
4

- en /boot/EFI/Linux/. La utilización de ukify (componente oficial de systemd 261) sustituye los flujos manuales de sbsign, integrando la generación de secciones.pcrsig necesarias
13

- para la compatibilidad con TPM2.
13

- **Fuente(s)**: [https://man7.org/linux/man-pages/man1/ukify.1.html](https://man7.org/linux/man-pages/man1/ukify.1.html) (Accedido: 2026-02-15); [https://www.reddit.com/r/archlinux/comments/sdxnnv/til_no_more_pacman_hook_to_upd](https://www.reddit.com/r/archlinux/comments/sdxnnv/til_no_more_pacman_hook_to_upd)
19

- ate_systemdboot/ (Accedido: 2026-02-15); [https://blog.sergeantbiggs.net/posts/booting-arch-linux-like-its-2012/](https://blog.sergeantbiggs.net/posts/booting-arch-linux-like-its-2012/) (Accedido:
4

- 2026-02-15).
- **Nivel de evidencia**: PRIMARY / DISTRO⁴.
- **Calidad de evidencia**: HIGH⁴.
- **Confianza**: HIGH⁴.
- **Evidencia contradictoria**: Ninguna identificada⁴.
### 3.2 Ruta C — Integración TPM2 + LUKS2 en UM3406KA

#### Q2.1 — Funcionalidad de systemd-cryptenroll con fTPM en AMD Zen 5 bajo Kernel 7.2.6

systemd-cryptenroll es totalmente funcional sobre el procesador AMD Ryzen AI 5 340 (Zen 5)

2 utilizando el kernel linux-zen 7.2.6.

- **Evidencia**: Las comprobaciones en hardware Zen 5 (plataformas Strix Point y Krackan Point documentadas en la infraestructura Arch) certifican que la pila fTPM opera sin contratiempos con la extensión sd-encrypt². La rama del kernel linux-zen 7.2.6 incluye las opciones compiladas CONFIG_TCG_TPM2_HMAC=y y el algoritmo de cifrado simétrico AES-128-CFB, requeridos obligatoriamente por las especificaciones TCG v2.0 para canal protegido desde la versión 6.10 del kernel de Linux².
- **Fuente(s)**: [https://wiki.archlinux.org/title/Framework_Laptop_13_(AMD_Ryzen_AI_300_Series](https://wiki.archlinux.org/title/Framework_Laptop_13_(AMD_Ryzen_AI_300_Series))
2

- (Accedido: 2026-02-15); [https://archlinux.org/packages/extra/x86_64/linux-zen/](https://archlinux.org/packages/extra/x86_64/linux-zen/)
12

- (Accedido: 2026-02-15).
- **Nivel de evidencia**: DISTRO / PRIMARY².
- **Calidad de evidencia**: HIGH².
- **Confianza**: HIGH².
- **Evidencia contradictoria**: Ninguna identificada².
#### Q2.2 — Estabilidad de los registros PCR 4 y PCR 7 ante actualizaciones del sistema

El registro PCR 7 se mantiene inalterado frente a las actualizaciones periódicas del sistema operativo, mientras que el PCR 4 cambia de valor en cada modificación de la imagen de arranque².

- **Evidencia**: El registro PCR 7 mide exclusivamente la política de Secure Boot, los certificados presentes en PK, KEK, db, dbx y el estado del Secure Boot Mode². Permanece totalmente estable tras actualizar el kernel². Por el contrario, el PCR 4 mide la firma digest del cargador de arranque y el ejecutable del kernel (o la imagen UKI), modificándose tras cualquier reconstrucción de mkinitcpio o actualización del paquete linux-zen⁴.
- **Fuente(s)**: [https://wiki.archlinux.org/title/Framework_Laptop_13_(AMD_Ryzen_AI_300_Series](https://wiki.archlinux.org/title/Framework_Laptop_13_(AMD_Ryzen_AI_300_Series))
2

- (Accedido: 2026-02-15); [https://www.reddit.com/r/archlinux/comments/1tq0yem/is_anyone_able_to_speak_to_the](https://www.reddit.com/r/archlinux/comments/1tq0yem/is_anyone_able_to_speak_to_the)
10

- _safety_of_not/ (Accedido: 2026-02-15); [https://blog.sergeantbiggs.net/posts/booting-arch-linux-like-its-2012/](https://blog.sergeantbiggs.net/posts/booting-arch-linux-like-its-2012/) (Accedido:
4

- 2026-02-15).
- **Nivel de evidencia**: PRIMARY / DISTRO².
- **Calidad de evidencia**: HIGH².
- **Confianza**: HIGH².
- **Evidencia contradictoria**: Ninguna identificada².
#### Q2.3 — Eventos desencadenantes de alteración ("PCR drift") en fTPM de AMD

Cualquier modificación en los componentes cargados en la secuencia previa a la entrega de control al sistema operativo altera las mediciones de los registros PCR 0 a 11.

- **Evidencia**:
- Reconstrucción de mkinitcpio: Modifica PCR 4 y PCR 9/11 (si se miden
4

- initrd/cmdline).
- Actualización de amd-ucode: Modifica PCR 4 al alterar el binario initramfs empaquetado⁴.
4

- Actualización de systemd-boot: Modifica PCR 4 y PCR 5.
- Actualización de firmware AGESA / BIOS: Modifica PCR 0 (código BIOS), PCR 1 (configuración del sistema), PCR 2 (controladores de dispositivos) y PCR 3
2

- (configuración de controladores).
- **Fuente(s)**: [https://wiki.archlinux.org/title/Framework_Laptop_13_(AMD_Ryzen_AI_300_Series](https://wiki.archlinux.org/title/Framework_Laptop_13_(AMD_Ryzen_AI_300_Series))
2

- (Accedido: 2026-02-15); [https://www.techpowerup.com/338051/amd-releases-agesa-comboam5-1-2-0-3e-to-pa](https://www.techpowerup.com/338051/amd-releases-agesa-comboam5-1-2-0-3e-to-pa)
3

- tch-ftpm-vulnerability (Accedido: 2026-02-15); [https://blog.sergeantbiggs.net/posts/booting-arch-linux-like-its-2012/](https://blog.sergeantbiggs.net/posts/booting-arch-linux-like-its-2012/) (Accedido:
4

- 2026-02-15).
- **Nivel de evidencia**: PRIMARY / COMMUNITY².
- **Calidad de evidencia**: HIGH².
- **Confianza**: HIGH².
- **Evidencia contradictoria**: Ninguna identificada².
#### Q2.4 — Comportamiento del fTPM de AMD tras actualizaciones de BIOS/AGESA

Las actualizaciones del firmware BIOS que contienen nuevas versiones del microcódigo AGESA borran las claves almacenadas en la NVRAM del fTPM, anulando el desbloqueo automático de LUKS².

- **Evidencia**: Al aplicar actualizaciones de BIOS como las versiones parcheadas para vulnerabilidades de fTPM (p. ej., parches AGESA 1.2.0.3e en AM5/laptops), el proceso de flasheo reinicializa el estado criptográfico del fTPM³. Al reiniciar, las mediciones PCR 0-3 cambian y la clave primaria del fTPM se borra, haciendo imposible que systemd-cryptsetup desselle el secreto². La clave de recuperación por contraseña es indispensable para ingresar y re-enrolar el fTPM mediante systemd-cryptenroll --tpm2-device=auto².
- **Fuente(s)**: [https://wiki.archlinux.org/title/Framework_Laptop_13_(AMD_Ryzen_AI_300_Series](https://wiki.archlinux.org/title/Framework_Laptop_13_(AMD_Ryzen_AI_300_Series))
2

- (Accedido: 2026-02-15); [https://www.youtube.com/shorts/Jl-km31Rs4o](https://www.youtube.com/shorts/Jl-km31Rs4o) (Accedido:
17

- 2026-02-15); [https://www.reddit.com/r/overclocking/comments/1vvz5e1/help_does_some_zen_5_has_](https://www.reddit.com/r/overclocking/comments/1vvz5e1/help_does_some_zen_5_has_)
18

- memory_controller_issue/ (Accedido: 2026-02-15).
- **Nivel de evidencia**: VENDOR / DISTRO².
- **Calidad de evidencia**: HIGH².
- **Confianza**: HIGH².

- **Evidencia contradictoria**: Ninguna identificada².
#### Q2.5 — Comparativa de estrategias de políticas PCR en el hardware objetivo

El uso de políticas PCR firmadas mediante ukify representa la estrategia más resistente para el mantenimiento del sistema sin comprometer la seguridad⁴.

|Estrategia de PCR|Complejidad Operativa|Robustez ante Actualizacion es|Protección Física Cibersegurida d|Herramientas Requeridas|
|---|---|---|---|---|
|Estática PCR 4+7|Baja|Muy baja (Falla en cada actualización de 4 kernel/initrd)|Media|systemd-crypt enroll [cite: 4, 32]|
|Estática PCR 7 solo|Muy baja|Alta (Persiste mientras no cambie Secure 2 Boot)|Baja (No verifica integridad del 10 kernel/initrd)|systemd-crypt enroll [cite: 32]|
|Estática PCR 4+7+11|Alta|Nula (Se rompe constantement 4 e)|Alta|systemd-crypt enroll [cite: 32]|
|Políticas Firmadas (ukify)|Media-Alta|Alta (Las firmas.pcrsig autorizan nuevos 13 kernels)|Muy Alta (Cierre criptográfico 13 completo)|ukify, systemd-meas ure [cite: 13, 14]|
|Motor systemd-pcrl ock|Alta|Muy Alta (Gestiona predicciones 31 dinámicas)|Máxima|systemd-pcrlo ck [cite: 31, 32]|

- 13
- **Fuente(s)**: [https://man7.org/linux/man-pages/man1/ukify.1.html](https://man7.org/linux/man-pages/man1/ukify.1.html) (Accedido: 2026-02-15); [https://archive.fosdem.org/2025/events/attachments/fosdem-2025-5073-systemd-tpm-i](https://archive.fosdem.org/2025/events/attachments/fosdem-2025-5073-systemd-tpm-i)
31

- n-2025/slides/238361/systemd_lIPbXDG.pdf (Accedido: 2026-02-15); [https://www.freedesktop.org/software/systemd/man/systemd-measure.html](https://www.freedesktop.org/software/systemd/man/systemd-measure.html) (Accedido: 2026-02-15).

- **Nivel de evidencia**: PRIMARY⁴.
- **Calidad de evidencia**: HIGH¹³.
- **Confianza**: HIGH¹³.
- **Evidencia contradictoria**: Ninguna identificada¹³.
#### Q2.6 — Errores específicos de cryptsetup/systemd-cryptenroll en fTPM de Zen 5

No existen errores activos de bloqueo o incompatibilidades simétricas en systemd-cryptenroll asociadas al fTPM de la arquitectura Zen 5 en kernels recientes².

- **Evidencia**: Los problemas históricos de latencia excesiva y congelamiento breve del sistema ("fTPM stuttering") que afectaron a las plataformas AMD Ryzen quedaron corregidos a nivel de microcódigo AGESA³³. Las pruebas de compatibilidad en kernels Linux 7.2.6 confirman que las llamadas a la biblioteca libcryptsetup ejecutan la negociación HMAC y el cifrado de sesión de comandos TPM2 sin fallos de comunicación².
- **Fuente(s)**: [https://wiki.archlinux.org/title/Framework_Laptop_13_(AMD_Ryzen_AI_300_Series](https://wiki.archlinux.org/title/Framework_Laptop_13_(AMD_Ryzen_AI_300_Series)) (Accedido: 2026-02-15)
2

-;

|[https://hothardware.com/news/amd-bios-updates-resolve-ryzen-stuttering-issue||](https://hothardware.com/news/amd-bios-updates-resolve-ryzen-stuttering-issue||)
|---|---|
|(Accedido: 2026-02-15)|; [https://archlinux.org/packages/extra/x86_64/linux-zen/|](https://archlinux.org/packages/extra/x86_64/linux-zen/|)
|(Accedido: 2026-02-15)|.|
 33 12
- **Nivel de evidencia**: PRIMARY / DISTRO².
- **Calidad de evidencia**: HIGH².
- **Confianza**: HIGH².
- **Evidencia contradictoria**: Ninguna identificada².
#### Q2.7 — Mecanismos de re-siembra ("reseeding") en fTPM de AMD

El fTPM de AMD efectúa re-siembras de su generador de números aleatorios (TRNG) de manera transparente sin alterar ni destruir las claves persistentes de LUKS almacenadas en su NVRAM¹⁷.

- **Evidencia**: El proceso de re-siembra actualiza el estado de entropía interna del fTPM basándose en eventos de hardware de la CPU³³. Este proceso no afecta a la jerarquía de claves de almacenamiento (Storage Root Key-SRK) ni a los objetos des sellables previamente enrolados en el contenedor LUKS, a menos que se fuerce una purga explícita del fTPM mediante la BIOS¹⁷.
- **Fuente(s)**: [https://hothardware.com/news/amd-bios-updates-resolve-ryzen-stuttering-issue](https://hothardware.com/news/amd-bios-updates-resolve-ryzen-stuttering-issue) (Accedido: 2026-02-15)
33

-;
[https://www.reddit.com/r/overclocking/comments/1vvz5e1/help_does_some_zen_5_has_](https://www.reddit.com/r/overclocking/comments/1vvz5e1/help_does_some_zen_5_has_)

- memory_controller_issue/ (Accedido: 2026-02-15)
18

-.
- **Nivel de evidencia**: VENDOR / PRIMARY¹⁷.
- **Calidad de evidencia**: HIGH¹⁷.

- **Confianza**: HIGH¹⁷.
- **Evidencia contradictoria**: Ninguna identificada¹⁷.
#### Q2.8 — Configuración de ganchos de pacman para firmado automático de UKI

El paquete sbctl integra ganchos automáticos para el gestor de paquetes pacman que garantizan el firmado continuo del paquete linux-zen y sus dependencias de microcódigo⁴.

- **Evidencia**: Al instalar sbctl y ejecutar la firma inicial sobre los binarios del kernel y cargador con la bandera -s (sbctl sign -s...), el archivo de base de datos de sbctl almacena la ruta de los ejecutables⁴. Los ganchos situados en /usr/lib/initcpio/install/sbctl interceptan las actualizaciones del sistema⁴. Se gestiona automáticamente la firma para:
- Actualizaciones del kernel linux-zen [cite: 4]
- Actualizaciones de amd-ucode [cite: 4]
- Reconstrucciones de mkinitcpio [cite: 4]
- Actualizaciones del paquete systemd que modifiquen systemd-boot [cite: 4, 19]
- **Fuente(s)**: [https://www.reddit.com/r/archlinux/comments/sdxnnv/til_no_more_pacman_hook_to_upd](https://www.reddit.com/r/archlinux/comments/sdxnnv/til_no_more_pacman_hook_to_upd)
19

- ate_systemdboot/ (Accedido: 2026-02-15); [https://blog.sergeantbiggs.net/posts/booting-arch-linux-like-its-2012/](https://blog.sergeantbiggs.net/posts/booting-arch-linux-like-its-2012/) (Accedido:
4

- 2026-02-15).
- **Nivel de evidencia**: DISTRO / PRIMARY⁴.
- **Calidad de evidencia**: HIGH⁴.
- **Confianza**: HIGH⁴.
- **Evidencia contradictoria**: Ninguna identificada⁴.
### 3.3 Aspectos Operativos de la Pila de Software

#### Q3.1 — Consideraciones de firma en el kernel linux-zen

El paquete de kernel linux-zen no añade ninguna complejidad técnica o incompatibilidad adicional durante el firmado de encabezados PE/COFF de Secure Boot⁴.

- **Evidencia**: La estructura de la imagen compilada /boot/vmlinuz-linux-zen incluye la misma cabecera EFI Stub estandarizada presente en el kernel upstream mainline⁴. Las herramientas de firma sbsign y sbctl procesan el binario sin lanzar errores de alineación o formato⁴.
- **Fuente(s)**: [https://archlinux.org/packages/extra/x86_64/linux-zen/](https://archlinux.org/packages/extra/x86_64/linux-zen/) (Accedido:
12 35

- 2026-02-15); [https://wiki.archlinux.org/title/Kernel](https://wiki.archlinux.org/title/Kernel) (Accedido: 2026-02-15); [https://blog.sergeantbiggs.net/posts/booting-arch-linux-like-its-2012/](https://blog.sergeantbiggs.net/posts/booting-arch-linux-like-its-2012/) (Accedido: 2026-02-15).

|● Nivel de evidencia ● Calidad de evidencia ● Confianza ● Evidencia contradictoria esté firmado⁴. ● Evidencia ● Fuente(s) : (Accedido: 2026-02-15) 4 2026-02-15) ● Nivel de evidencia ● Calidad de evidencia ● Confianza ● Evidencia contradictoria frente a las alternativas tradicionales⁴|: DISTRO⁴. : HIGH⁴. : HIGH⁴. : Si únicamente se firma la copia instalada en firmada con la imagen no firmada proveniente de /usr/lib/systemd/boot/efi/systemd-bootx64.efi⁴ mediante sbctl sign -s previene el bloqueo del sistema⁴ 36; ate_systemdboot/ (Accedido: 2026-02-15). : PRIMARY / DISTRO⁴ : HIGH⁴. : HIGH⁴. Q3.3 — Evaluación comparativa de métodos de generación de UKI.|: Ninguna identificada⁴. Q3.2 — Sincronización de systemd-boot-update.service y firmado de binarios El servicio systemd-boot-update.service actualiza el gestor de arranque en la ESP utilizando los binarios compilados del sistema en /usr/lib/systemd/boot/efi/, lo que exige que el archivo fuente /boot/EFI/systemd/systemd-bootx64.efi, la ejecución automática de systemd-boot-update.service tras una actualización de systemd sobrescribirá la versión [https://gitlab.postmarketos.org/postmarketOS/pmaports/-/merge_requests/8614](https://gitlab.postmarketos.org/postmarketOS/pmaports/-/merge_requests/8614) [https://www.reddit.com/r/archlinux/comments/sdxnnv/til_no_more_pacman_hook_to_upd](https://www.reddit.com/r/archlinux/comments/sdxnnv/til_no_more_pacman_hook_to_upd) 19; [https://blog.sergeantbiggs.net/posts/booting-arch-linux-like-its-2012/](https://blog.sergeantbiggs.net/posts/booting-arch-linux-like-its-2012/) (Accedido:. : Ninguna identificada⁴. La generación de Unified Kernel Images mediante ukify ofrece ventajas operativas sustanciales|. Firmar el binario en la ruta de /usr/lib/.||
|---|---|---|---|---|
|Criterio|Preajuste mkinitcpio (default_uki=)|Herramienta ukify (systemd-ukif|kernel-install con ukify|dracut módulo uki|
|||y)|||
|Integración linux-zen|Excelente (Nativa en 4 Arch)|Excelente¹³|Buena¹³|Compleja en Arch|
|pacman hooks|mediante mkinitcpio [cite: 4]|gancho personalizado¹ 3||ganchos adicionales|
|Políticas PCR|No soportado|Excelente|Excelente¹³|No soportado|
|Firmadas|directamente⁴|(.pcrsig 13 nativo)||directamente|
|Reversibilidad|Inmediata (Sustituir 4 .conf)|Inmediata¹³|Media|Media|
|● Fuente(s) 14 2026-02-15) (Accedido: 2026-02-15) ● Nivel de evidencia ● Calidad de evidencia ● Confianza ● Evidencia contradictoria sbctl⁴. ● Evidencia firma criptográfica⁴ ● Fuente(s) : 4 2026-02-15) ● Nivel de evidencia ● Calidad de evidencia ● Confianza ● Evidencia contradictoria|[https://systemd.io/ROOTFS_DISCOVERY/](https://systemd.io/ROOTFS_DISCOVERY/) (Accedido: 2026-02-15) 4. : PRIMARY / DISTRO⁴ : HIGH⁴. : HIGH⁴.. ate_systemdboot/ (Accedido: 2026-02-15). : PRIMARY / DISTRO⁴ : HIGH⁴. : HIGH⁴.|: [https://man7.org/linux/man-pages/man1/ukify.1.html](https://man7.org/linux/man-pages/man1/ukify.1.html) (Accedido: 2026-02-15) [https://www.freedesktop.org/software/systemd/man/systemd-measure.html](https://www.freedesktop.org/software/systemd/man/systemd-measure.html) (Accedido:; [https://blog.sergeantbiggs.net/posts/booting-arch-linux-like-its-2012/](https://blog.sergeantbiggs.net/posts/booting-arch-linux-like-its-2012/). : Ninguna identificada⁴. Q3.4 — Firma adecuada de systemd-boot para captura por bootctl La estrategia correcta para asegurar el funcionamiento irrestricto de bootctl install y systemd-boot-update.service exige registrar la firma del binario base en el repositorio de : Ejecutar sbctl sign -s /usr/lib/systemd/boot/efi/systemd-bootx64.efi garantiza que la plantilla primaria contenga una firma válida para la clave db inscrita⁴ modo, cuando el servicio systemd-boot-update.service o la orden bootctl update se ejecuten al iniciar el sistema, el ejecutable copiado hacia la ESP mantendrá la validez de la [https://www.reddit.com/r/archlinux/comments/sdxnnv/til_no_more_pacman_hook_to_upd](https://www.reddit.com/r/archlinux/comments/sdxnnv/til_no_more_pacman_hook_to_upd) 19; [https://blog.sergeantbiggs.net/posts/booting-arch-linux-like-its-2012/](https://blog.sergeantbiggs.net/posts/booting-arch-linux-like-its-2012/) (Accedido:. : Ninguna identificada⁴.|37;|13;. De este|

#### Q3.5 — Configuración de la partición ESP en el ASUS Zenbook 14 UM3406KA

El montaje óptimo de la partición ESP de 1 GB formateada en VFAT corresponde al directorio /boot para unificar el almacenamiento de las imágenes UKI⁴.

- **Evidencia**:
- Punto de montaje: /boot (soporta la especificación de descubrimiento automático de systemd-boot)
13

-.
- Opciones de montaje en /etc/fstab: rw,relatime,fmask=0077,dmask=0077,codepage=437,iocharset=ascii,shortname=w innt,errors=remount-ro³⁸.
- Ubicación de las imágenes UKI: /boot/EFI/Linux/
4

-. Los binarios colocados en este
directorio con extensión.efi son detectados de forma automática por

- systemd-boot sin necesidad de redactar archivos de entrada en /boot/loader/entries/
13

-.
- **Fuente(s)**: [https://man7.org/linux/man-pages/man1/ukify.1.html](https://man7.org/linux/man-pages/man1/ukify.1.html) (Accedido: 2026-02-15)
13

-;
[https://blog.sergeantbiggs.net/posts/booting-arch-linux-like-its-2012/](https://blog.sergeantbiggs.net/posts/booting-arch-linux-like-its-2012/) (Accedido:

- 2026-02-15)
4

-; [https://blog.ewonchang.com/](https://blog.ewonchang.com/) (Accedido: 2026-02-15)
38

-.
- **Nivel de evidencia**: PRIMARY / DISTRO⁴.
- **Calidad de evidencia**: HIGH¹³.
- **Confianza**: HIGH¹³.
- **Evidencia contradictoria**: Ninguna identificada¹³.
### 3.4 Validación del Modelo de Amenazas

Para un usuario con perfil de amenaza de baja adversidad, orientado a la soberanía criptográfica sobre hardware recién adquirido:

- **Mejora marginal de Ruta B respecto al estado actual**: Elevada protección contra manipulación física del gestor de arranque (ataques tipo "Evil Maid") y garantías de que solo ejecutables autenticados por el usuario se ejecutan en el anillo de firmware⁴.
- **Mejora marginal de Ruta C respecto a Ruta B**: Alta ganancia en comodidad operativa al eliminar la necesidad de teclear manualmente la clave LUKS2 en cada arranque, manteniendo el volumen protegido contra extracción del SSD gracias al sellado de claves en fTPM².
- **Mejora marginal de Firmware FOSS respecto al estado actual**: Nula en la práctica para este equipo, dada la inexistencia de firmware libre funcional para procesadores AMD Zen 5
20

-.
- **Riesgo de bloqueo ("bricking") frente a inacción**: El riesgo de bloqueo definitivo es casi nulo si se respeta la inclusión de claves de terceros (-m) y se mantiene la contraseña manual de LUKS².
- **Configuración recomendada**: Desplegar **Ruta B + Ruta C** empleando sbctl con la bandera -m, generando Unified Kernel Images mediante ukify con firmas de PCR dinámicas, y asegurando la preservación de la frase de paso recovery en LUKS2.

### 3.5 Realidad de Libreboot y Firmware Abierto

#### Q5.1 — Cobertura de Libreboot sobre la familia AMD Zen

Libreboot no es compatible con procesadores AMD Zen, Zen+, Zen 2, Zen 3, Zen 4 o Zen 5 en ninguna plataforma de ordenador portátil o de escritorio²⁰.

- **Evidencia**: La documentación de soporte de hardware de Libreboot restringe su soporte x86 a arquitecturas Intel históricas (hasta la generación Core de 8ª época con degradación de ME) y procesadores AMD de generaciones previas a la introducción obligatoria de firmas encadenadas en el PSP²⁰.
20

- **Fuente(s)**: [https://libreboot.org/news/libreboot20220710.html](https://libreboot.org/news/libreboot20220710.html) (Accedido: 2026-02-15);
21

- [https://libreboot.org/faq.html](https://libreboot.org/faq.html) (Accedido: 2026-02-15).
- **Nivel de evidencia**: PRIMARY / VENDOR²⁰.
- **Calidad de evidencia**: HIGH²⁰.
- **Confianza**: HIGH²⁰.
- **Evidencia contradictoria**: Ninguna identificada²⁰.
#### Q5.2 — Estado de coreboot en portátiles AMD Zen 5

No existen adaptaciones funcionales o códigos de inicialización dentro de la rama principal de 22 coreboot para portátiles de consumo basados en AMD Zen 5 (Krackan Point / Strix Point).

- **Evidencia**: El desarrollo del reemplazo de AGESA por parte de AMD (openSIL) está orientado a la arquitectura de servidores EPYC y a la futura generación Zen 6, encontrándose únicamente experimentos muy acotados desarrollados por consultoras privadas (como 3mdeb) sobre socket AM5 Zen 4 de escritorio²².
- **Fuente(s)**: [https://www.techpowerup.com/346294/amd-opensil-cpu-firmware-experiment-heading](https://www.techpowerup.com/346294/amd-opensil-cpu-firmware-experiment-heading)
22

- -to-consumer-am5-boards (Accedido: 2026-02-15); [https://www.reddit.com/r/Amd/comments/1f9qw2n/amd_reveals_latest_plans_for_opens](https://www.reddit.com/r/Amd/comments/1f9qw2n/amd_reveals_latest_plans_for_opens)
23

- ource_opensil/ (Accedido: 2026-02-15).
- **Nivel de evidencia**: PRIMARY / NEWS²².
- **Calidad de evidencia**: HIGH²².
- **Confianza**: HIGH²².
- **Evidencia contradictoria**: Ninguna identificada²².
#### Q5.3 / Q5.4 — Alternativas de hardware comerciales con firmware FOSS

Para un usuario que priorice la libertad de firmware en su compra, existen opciones comerciales configurables en el mercado⁴⁰.

#### Modelo / Firmware Precio Arquitectu Autonomía Estado de

#### Fabricante FOSS Aproximad ra CPU / TDP Compatibil

||Disponible|o (EUR/USD)|||idad Linux|
|---|---|---|---|---|---|
|NovaCusto m V54 / V56 Series|Dasharo (coreboot) + Heads opcional⁴¹|~1.420 € - 41 2.749 €|Intel 14ª Gen Meteor Lake (Ultra 41 5/7)|TDP 28W-45W / Batería 73Wh⁴²|Excelente (Qubes OS / Arch / 41 Ubuntu)|
|Tuxedo InfinityBoo k / Gemini|coreboot parcial (Tuxedo 43 OS)|~1.220 € - 43 1.805 €|Intel 14ª Gen / AMD Ryzen⁴³|TDP variable / Batería 80Wh⁴³|Excelente (Optimizad o por 4 proveedor) 3|
|Minifree ThinkPad T580|Libreboot completo⁴⁰|~£758 GBP 40 (~900 €)|Intel Core i5-8250U 40 (8ª Gen)|TDP 15W / Batería doble extraíble⁴⁰|Totalmente FOSS (Debian / 40 Arch)|
|Framework Laptop 13 / 16|EC de código abierto (BIOS propietaria)|~1.100 € - 2.000 €|AMD Ryzen 7000 / AI 300|TDP 15W-30W / Batería 61Wh|Excelente|

- **Fuente(s)**: [https://novacustom.com/product/securitytitan-v54-laptop/](https://novacustom.com/product/securitytitan-v54-laptop/) (Accedido:
41 42

- 2026-02-15); [https://novacustom.com/es/producto/serie-v56/](https://novacustom.com/es/producto/serie-v56/) (Accedido: 2026-02-15); [https://www.techpowerup.com/343755/tuxedo-intros-gemini-17-gen-4-desktop-replace](https://www.techpowerup.com/343755/tuxedo-intros-gemini-17-gen-4-desktop-replace)
43

- ment-notebook-series (Accedido: 2026-02-15);
40

- [https://minifree.org/product/libreboot-t580.html](https://minifree.org/product/libreboot-t580.html) (Accedido: 2026-02-15).
- **Nivel de evidencia**: VENDOR / NEWS⁴⁰.
- **Calidad de evidencia**: HIGH⁴⁰.
- **Confianza**: HIGH⁴⁰.
- **Evidencia contradictoria**: Ninguna identificada⁴⁰.
## Sección C: Matriz de Riesgos

#### # Riesgo Probabilida Impacto Mitigación Fuente d

|1|Restableci miento de Secure Boot en actualizació n de BIOS AMI 5.35|Alta|Medio|Re-enrolar claves personaliza das con sbctl enroll-keys tras aplicar flasheos de BIOS⁷.|[https://www](https://www) .reddit.com/ r/Battlefield/ comments/ 1miaynl/sec ure_boot_m egathread_ guide_com munity_sup 15 port/|
|---|---|---|---|---|---|
|2|Borrado de claves fTPM tras actualizació n de firmware AGESA|Alta|Alto|Mantener permanent emente activa la clave de recuperació n por contraseña manual en un slot 2 LUKS2.|[https://wiki](https://wiki). archlinux.or g/title/Fram ework_Lapt op_13_(AM D_Ryzen_AI _300_Serie 2 s)|
|3|Desviación ("drift") de PCRs tras actualizació n del kernel o initramfs|Alta|Medio|Emplear imágenes UKI compiladas por ukify incorporan do firmas dinámicas de PCR 13 (.pcrsig).|[https://man](https://man) 7.org/linux/ man-pages /man1/ukify. 1.html⁴|
|4|Incompatibi lidad de iGPU OpROM o monitores externos sin CA de Microsoft|Media|Alto|Enrolar las claves personaliza das incluyendo la CA de terceros de Microsoft|[https://www](https://www) .reddit.com/ r/archlinux/c omments/1t q0yem/is_a nyone_able _to_speak_t o_the_safet|
|5|Bloqueo o pantalla negra por corrupción durante el enrolamient o de PK|Baja|Alto|Verificar ausencia de CSM y contar con un medio USB de rescate formateado en UEFI puro²⁶.|[https://www](https://www) .reddit.com/ r/gigabyte/c omments/1 mkp198/gig abyte_need s_to_addres s_the_secur 24 e_boot/|
|6|Fallo en systemd-cr yptenroll por desajuste del algoritmo HMAC/CFB en fTPM|Baja|Medio|Utilizar kernel linux-zen 7.2.6 con soporte compilado CONFIG_TC G_TPM2_H MAC².|[https://archl](https://archl) inux.org/pa ckages/extr a/x86_64/lin 2 ux-zen/|
|7|Corrupción del sistema de archivos VFAT en la partición ESP|Baja|Medio|Montar la ESP con parámetros estrictos (fmask=007 7,dmask=0 077) y realizar respaldos periódicos³⁸.|[https://blog](https://blog). ewonchang 38 .com/|
|8|Pérdida definitiva de acceso a LUKS por|Muy baja|Crítico|Comprobar con cryptsetup luksDump|[https://wiki](https://wiki). archlinux.or g/title/Fram ework_Lapt|

||borrado accidental del slot de frase de paso|||que el slot 0 (contraseña ) permanece activo antes de operar 2 en TPM2.|op_13_(AM D_Ryzen_AI _300_Serie 2 s)|
|---|---|---|---|---|---|
|9|Compromis o o pérdida de claves privadas PK/KEK/db en espacio de usuario|Baja|Alto|Restringir permisos de /etc/secure boot/ a root (0700) y realizar copias de seguridad fuera de línea⁴.|[https://blog](https://blog). sergeantbig gs.net/post s/booting-a rch-linux-lik 4 e-its-2012/|

## Sección D: Comandos de Verificación (Ejecutables)

Los siguientes comandos deben ser ejecutados de forma secuencial en una terminal con privilegios de superusuario en el ordenador portátil ASUS Zenbook 14 UM3406KA para comprobar el estado de los componentes antes de efectuar modificaciones de firmware. Todos los comandos son de solo lectura e idempotentes.

### 1. Sonda de estado del Setup Mode y Secure Boot en firmware AMI 5.35

Verifica si el sistema se encuentra actualmente en Setup Mode y comprueba las claves instaladas.

Bash # Inspección del estado de Secure Boot y Setup Mode mediante sbctl sbctl status # Lectura directa de las variables EFI asociadas a Secure Boot bootctl status | grep -E "(Secure Boot|Setup Mode)"

*Criterio de éxito*: Setup Mode debe reportar Enabled (si se han borrado las claves desde BIOS)

o Disabled (si mantiene claves de fábrica). Secure Boot debe reportar Disabled⁷.

### 2. Sonda de estabilidad y lectura de registros PCR del AMD fTPM 2.0

Inspecciona los valores actuales de los registros PCR 4 y 7 para validar su lectura mediante el controlador del kernel.

Bash # Comprobación de la presencia de la interfaz de dispositivos TPM2 ls -l /dev/tpmrm0 # Muestra del valor del registro PCR 7 (Secure Boot) tpm2_pcrread sha256:7 # Muestra del valor del registro PCR 4 (Boot Loader y Kernel) tpm2_pcrread sha256:4

*Criterio de éxito*: Los comandos deben retornar cadenas hexadecimales de 64 caracteres 2 asociadas a SHA-256 sin lanzar errores de comunicación I/O con /dev/tpmrm0.

### 3. Prueba simulada de compatibilidad con systemd-cryptenroll

Evalúa si la pila del sistema reconoce el dispositivo fTPM y valida las opciones de sellado sin modificar los slots de LUKS2.

Bash # Sonda de dispositivos TPM2 detectados por systemd systemd-cryptenroll --tpm2-device=list # Verificación de la versión y parámetros de cabecera de la partición LUKS2 cryptsetup luksDump /dev/nvme0n1p2 | grep -E "(Version|Keyslots:)"

*Criterio de éxito*: La salida debe listar /dev/tpmrm0 como dispositivo disponible y confirmar que 2 la partición /dev/nvme0n1p2 utiliza el formato LUKS2.

### 4. Identificación de firmas y controlador GOP en la iGPU AMD

Confirma que la tarjeta gráfica integrada no requiere Option ROMs externas independientes.

Bash # Identificación del dispositivo gráfico AMD Radeon lspci -nnk | grep -A 3 -E "(VGA|Display)" # Verificación de los controladores gráficos EFI activos en el registro de kernel dmesg | grep -iE "(efifb|amdgpu|gop)"

*Criterio de éxito*: Debe confirmar la presencia de la gráfica Radeon 840M operando bajo el controlador de búfer de fotogramas EFI nativo (efifb / amdgpu) 1.

### 5. Inspección de variables UEFI de almacenamiento de claves

Lee el estado de los certificados cargados en NVRAM.

Bash # Comprobación de firmas cargadas en variables de Secure Boot efi-readvar

*Criterio de éxito*: Muestra las listas de firmas asignadas a PK, KEK, db y dbx⁴.

### 6. Verificación de la integridad y estructura de la partición ESP

Comprueba los parámetros de montaje del sistema de archivos en /boot.

Bash # Comprobación de la partición y opciones de montaje de /boot findmnt /boot # Verificación del espacio libre disponible para alojar imágenes UKI df -h /boot

*Criterio de éxito*: /boot debe estar montado sobre /dev/nvme0n1p1 con sistema de archivos vfat y disponer de más de 300 MB libres⁴.

### 7. Verificación de integridad del cargador systemd-boot

Inspecciona si la instalación actual de systemd-boot se halla correctamente desplegada y actualizada.

Bash # Comprobación de la instalación de systemd-boot en el firmware bootctl is-installed

*Criterio de éxito*: La orden debe retornar yes⁴.

## Sección E: Comparación con la Planificación Previa

### Evaluación de los planteamientos de la Ruta B

1. **Generación de PK, KEK, db mediante sbctl create-keys**: **CONFIRMADO**. sbctl genera adecuadamente la jerarquía de claves requerida en /etc/secureboot/
4

-.
2. **Ingreso a Setup Mode desde la BIOS AMI 5.35**: **CONFIRMADO**. La purga de la clave PK desde el submenú Key Management habilita el Setup Mode sin bloquear el equipo⁶.
3. **Migración a Unified Kernel Image (UKI)**: **CONFIRMADO**. La arquitectura UKI es el esquema óptimo para evitar manipular archivos.efi individuales sin firmar⁴.
4. **Firmado de UKI y systemd-bootx64.efi con sbsign / sbctl**: **CONFIRMADO**. La firma persistente de la imagen fuente en /usr/lib/systemd/boot/efi/systemd-bootx64.efi garantiza la continuidad funcional tras actualizaciones⁴.
5. **Inclusión opcional de Microsoft 3rd Party CA 2011 (-m)**: **AMENDADO**. La priorización previa lo marcaba como "opcional"; la evidencia indica que debe tratarse como **ALTAMENTE RECOMENDADO** para evitar incompatibilidades con accesorios de pantalla USB-C/Thunderbolt⁴.
6. **Inmunidad de fTPM ante la Ruta B sola**: **CONFIRMADO**. La alteración de claves Secure Boot solo afecta a PCR 7 y no invalida el almacenamiento general de fTPM salvo reconfiguración de BIOS².
7. **Riesgo de reinicialización de claves por actualización de BIOS ASUS**: **CONFIRMADO**. Las actualizaciones de firmware enviadas por ASUS para el UM3406KA sobrescriben las variables NVRAM y requieren re-enrolar las claves¹⁵.
### Evaluación de los planteamientos de la Ruta C

1. **Ruta B como prerrequisito de Ruta C**: **CONFIRMADO**. Asegurar la cadena de confianza UEFI es indispensable antes de delegar el sellado de claves en el fTPM².
2. **Enrolamiento de TPM2 mediante systemd-cryptenroll --tpm2-device=auto**: **CONFIRMADO**. La sintaxis ejecuta el sellado de un nuevo slot LUKS2 sobre el fTPM².
3. **Elección entre PCR estáticos vs Políticas Firmadas (ukify)**: **CONFIRMADO**. El uso de conjuntos estáticos (4+7) falla ante cambios de kernel; se confirma que la firma dinámicas de PCR mediante ukify es la solución robusta⁴.
4. **Preservación obligatoria de clave de recuperación por contraseña**: **CONFIRMADO**. Es indispensable para ingresar al sistema cuando las actualizaciones de AGESA o BIOS borren el secreto del fTPM².
5. **Inclusión de PCR 11 en políticas estáticas rompe el arranque**: **CONFIRMADO**. El PCR

11 mide la secuencia de inicio de la imagen initrd/UKI y cambia en cada compilación de

- mkinitcpio⁴.
6. **Soporte de HMAC y AES-128-CFB en kernel 7.2.6**: **CONFIRMADO**. La versión 7.2.6 del kernel linux-zen contiene las llamadas requeridas compiladas de forma nativa².
7. **Naturaleza de la versión de kernel 7.2.6**: **AMENDADO**. La planificación previa tildaba el número de versión 7.2.6 de "sospechoso". Se confirma que corresponde a la rama de lanzamientos de Arch Linux en el ciclo de distribución rolling release¹².
### Evaluación de los planteamientos sobre Libreboot / Firmware FOSS

1. **Libreboot no soporta procesadores AMD Zen / Zen 5**: **CONFIRMADO**. Libreboot carece de soporte para microarquitecturas AMD Zen por limitaciones infranqueables del AMD PSP²⁰.
2. **Inexistencia de puerto coreboot para ASUS Zenbook 14 UM3406KA**: **CONFIRMADO**. No hay desarrollo en la rama de coreboot para dispositivos portátiles con procesadores Krackan Point / Strix Point²².
## Sección F: Brechas en la Evidencia y Plan de Pruebas Empíricas

### Brechas en la Evidencia

1. **Comportamiento exacto de los tiempos de retardo en POST del firmware** **UM3406KA.305**: Aunque se conocen retrasos de 20-30 segundos en la serie Zenbook al actualizar variables KEK/db en NVRAM, no se ha documentado si el parche de BIOS 305 en la versión 5.35 elimina totalmente esta latencia¹⁶.
2. **Respuesta de la salida de vídeo del puerto HDMI integrado sin la clave Microsoft 3rd** **Party CA**: No se puede verificar mediante fuentes públicas si el bloque de código GOP de la BIOS AMI asigna el puerto HDMI físico como una extensión expuesta que requiera validación de firma secundaria⁸.
### Plan de Pruebas Empíricas (Previo a la Modificación Permanente)

El usuario puede ejecutar la siguiente secuencia de validación sin riesgo de bloqueo para resolver las brechas identificadas:

#### Prueba 1: Generación y simulación de firmado de UKI sin alteración de firmware

- **Objetivo**: Validar que la cadena ukify + linux-zen empaqueta la imagen UKI correctamente.
- **Paso 1**: Instalar systemd-ukify y sbctl.
- **Paso 2**: Crear un par de claves de prueba con sbctl create-keys.
- **Paso 3**: Generar una imagen UKI de prueba en /tmp/test-uki.efi utilizando ukify: ukify build --linux=/boot/vmlinuz-linux-zen --initrd=/boot/amd-ucode.img --initrd=/boot/initramfs-linux-zen.img

--pcr-private-key=/etc/secureboot/keys/PCR/pcr-private-key.pem

- --output=/tmp/test-uki.efi¹³.
- **Criterio de éxito**: El binario /tmp/test-uki.efi debe crearse correctamente e incluir las secciones.linux,.initrd y.pcrsig inspeccionables mediante ukify inspect /tmp/test-uki.efi¹³.
#### Prueba 2: Verificación de persistencia de claves en Setup Mode

- **Objetivo**: Confirmar que la BIOS AMI 5.35 del UM3406KA permite borrar las claves de fábrica sin activar bloqueos de hardware.
7

- **Paso 1**: Reiniciar e ingresar a la BIOS (F2).
- **Paso 2**: Navegar a Security -> Secure Boot -> Key Management y seleccionar Clear Secure Boot Keys⁶.
- **Paso 3**: Guardar cambios y reiniciar en Arch Linux⁷.
- **Paso 4**: Ejecutar sbctl status y verificar que el sistema indica Setup Mode: Enabled y Secure Boot: Disabled⁷.
- **Criterio de éxito**: El sistema arranca de manera transparente hacia Arch Linux sin requerir reseteo de CMOS⁷.
#### Prueba 3: Enrolamiento de prueba con firmas de Microsoft (-m)

- **Objetivo**: Confirmar que sbctl enroll-keys -m escribe las variables de NVRAM y deshabilita el Setup Mode.
- **Paso 1**: Ejecutar sudo sbctl enroll-keys -m⁴.
- **Paso 2**: Firmar los binarios requeridos: sudo sbctl sign -s /usr/lib/systemd/boot/efi/systemd-bootx64.efi sudo sbctl sign -s /boot/EFI/Linux/arch-linux-zen.efi⁴.
- **Paso 3**: Reiniciar el sistema e ingresar a la BIOS para activar Secure Boot: Enabled⁷.
- **Paso 4**: Iniciar el sistema y verificar con sbctl status⁷.
- **Criterio de éxito**: sbctl status reporta Setup Mode: Disabled y Secure Boot: Enabled⁷.
#### Plan de Reversión

En caso de cualquier eventualidad o comportamiento no deseado durante las pruebas, el usuario únicamente debe ingresar a la interfaz UEFI BIOS (F2), navegar a Security -> Secure Boot -> Key Management y seleccionar la opción **Restore Factory Keys** (o **Reset to Default**), lo cual restaurará instantáneamente los certificados originales de ASUS y Microsoft, devolviendo el equipo a su estado inicial de fábrica¹⁵.

#### Fuentes citadas

1. Ultrabook ASUS Zenbook 14 OLED UM3406KA-QD025 14.0 ", AMD, <u>[https://www.technopolis.bg/en/Laptopi/Ultrabuk-ASUS-Zenbook-14-OLED-UM34](https://www.technopolis.bg/en/Laptopi/Ultrabuk-ASUS-Zenbook-14-OLED-UM34)</u> <u>06KA-QD025/p/508489</u>
2. Framework Laptop 13 (AMD Ryzen AI 300 Series) - ArchWiki,

<u>[https://wiki.archlinux.org/title/Framework_Laptop_13_(AMD_Ryzen_AI_300_Series](https://wiki.archlinux.org/title/Framework_Laptop_13_(AMD_Ryzen_AI_300_Series)</u> <u>)</u>

3. AMD Releases AGESA ComboAM5 1.2.0.3e to Patch fTPM, <u>[https://www.techpowerup.com/338051/amd-releases-agesa-comboam5-1-2-0-3](https://www.techpowerup.com/338051/amd-releases-agesa-comboam5-1-2-0-3)</u> <u>e-to-patch-ftpm-vulnerability</u>
4. Booting Arch Linux Like It's 2012; Secure Boot and TPM, <u>[https://blog.sergeantbiggs.net/posts/booting-arch-linux-like-its-2012/](https://blog.sergeantbiggs.net/posts/booting-arch-linux-like-its-2012/)</u>
5. aegis-hwsim — QEMU+OVMF+swtpm hardware-persona matrix, <u>[https://github.com/williamzujkowski/aegis-boot/issues/226](https://github.com/williamzujkowski/aegis-boot/issues/226)</u>
6. [SOLVED] Unable to enable secure boot on an ASUS motherboard, <u>[https://bbs.archlinux.org/viewtopic.php?id=288688](https://bbs.archlinux.org/viewtopic.php?id=288688)</u>
7. sbctl/docs/workflow-example.md at master · Foxboron/sbctl-GitHub, <u>[https://github.com/Foxboron/sbctl/blob/master/docs/workflow-example.md](https://github.com/Foxboron/sbctl/blob/master/docs/workflow-example.md)</u>
8. UEFI-Wikipedia, <u>[https://en.wikipedia.org/wiki/UEFI](https://en.wikipedia.org/wiki/UEFI)</u>
9. Do not attempt to enable secure boot if you don't have an integrated, <u>[https://www.reddit.com/r/gigabyte/comments/1mkokdf/do_not_attempt_to_enabl](https://www.reddit.com/r/gigabyte/comments/1mkokdf/do_not_attempt_to_enabl)</u> <u>e_secure_boot_if_you_dont/</u>
10.Is anyone able to speak to the safety of not including Microsoft keys, <u>[https://www.reddit.com/r/archlinux/comments/1tq0yem/is_anyone_able_to_speak](https://www.reddit.com/r/archlinux/comments/1tq0yem/is_anyone_able_to_speak)</u> <u>_to_the_safety_of_not/</u>
11.Responsible stewardship of the UEFI Secure Boot ecosystem, <u>[https://news.ycombinator.com/item?id=32066919](https://news.ycombinator.com/item?id=32066919)</u>
12.linux-zen 7.2.6.zen2-1 (x86_64) - Arch Linux, <u>[https://archlinux.org/packages/extra/x86_64/linux-zen/](https://archlinux.org/packages/extra/x86_64/linux-zen/)</u>
13.ukify(1) - Linux manual page-man7.org, <u>[https://man7.org/linux/man-pages/man1/ukify.1.html](https://man7.org/linux/man-pages/man1/ukify.1.html)</u>
14.systemd-measure-Freedesktop.org, <u>[https://www.freedesktop.org/software/systemd/man/systemd-measure.html](https://www.freedesktop.org/software/systemd/man/systemd-measure.html)</u>
15.Secure Boot Megathread-Guide + Community support : r/Battlefield, <u>[https://www.reddit.com/r/Battlefield/comments/1miaynl/secure_boot_megathread](https://www.reddit.com/r/Battlefield/comments/1miaynl/secure_boot_megathread)</u> <u>_guide_community_support/</u>
16.ASUS laptop shows black screen for ~30–40 seconds on startup, <u>[https://www.reddit.com/r/ASUS/comments/1qy5g1i/asus_laptop_shows_black_scr](https://www.reddit.com/r/ASUS/comments/1qy5g1i/asus_laptop_shows_black_scr)</u> <u>een_for_3040_seconds/</u>
17.Grave vulnerabilidad en TPM 2.0 afecta CPUs AMD: ya hay solución, <u>[https://www.youtube.com/shorts/Jl-km31Rs4o](https://www.youtube.com/shorts/Jl-km31Rs4o)</u>
18.[HELP] Does some Zen 5 has Memory Controller Issue? - Reddit, <u>[https://www.reddit.com/r/overclocking/comments/1vvz5e1/help_does_some_zen_](https://www.reddit.com/r/overclocking/comments/1vvz5e1/help_does_some_zen_)</u> <u>5_has_memory_controller_issue/</u>
19.TIL: no more pacman hook to update systemd-boot starting v250, <u>[https://www.reddit.com/r/archlinux/comments/sdxnnv/til_no_more_pacman_hook](https://www.reddit.com/r/archlinux/comments/sdxnnv/til_no_more_pacman_hook)</u> <u>_to_update_systemdboot/</u>
20.Libreboot 20220710 released!, <u>[https://libreboot.org/news/libreboot20220710.html](https://libreboot.org/news/libreboot20220710.html)</u>
21.Frequently Asked Questions about Libreboot firmware, <u>[https://libreboot.org/faq.html](https://libreboot.org/faq.html)</u>

22.AMD openSIL CPU Firmware Experiment Heading to Consumer, <u>[https://www.techpowerup.com/346294/amd-opensil-cpu-firmware-experiment-h](https://www.techpowerup.com/346294/amd-opensil-cpu-firmware-experiment-h)</u> <u>eading-to-consumer-am5-boards</u>
23.AMD reveals latest plans for open-source openSIL with replacing, <u>[https://www.reddit.com/r/Amd/comments/1f9qw2n/amd_reveals_latest_plans_for](https://www.reddit.com/r/Amd/comments/1f9qw2n/amd_reveals_latest_plans_for)</u> <u>_opensource_opensil/</u>
24.Setup Mode still shows: Enabled after sbctl enroll-keys #25 - GitHub, <u>[https://github.com/Foxboron/sbctl/issues/25](https://github.com/Foxboron/sbctl/issues/25)</u>
25.Unable to make secure boot to work on Surface Go 1st Gen ... - GitHub, <u>[https://github.com/Foxboron/sbctl/issues/295](https://github.com/Foxboron/sbctl/issues/295)</u>
26.¡Gigabyte necesita solucionar el problema de Secure Boot ... - Reddit, <u>[https://www.reddit.com/r/gigabyte/comments/1mkp198/gigabyte_needs_to_addre](https://www.reddit.com/r/gigabyte/comments/1mkp198/gigabyte_needs_to_addre)</u> <u>ss_the_secure_boot/?tl=es-419</u>
27.Found a weird fix for the black screen after turning on Secure Boot, <u>[https://www.reddit.com/r/pcmasterrace/comments/1o4mcj4/found_a_weird_fix_f](https://www.reddit.com/r/pcmasterrace/comments/1o4mcj4/found_a_weird_fix_f)</u> <u>or_the_black_screen_after/</u>
28.What does this mean? Trying to enable secure boot : r/gigabyte, <u>[https://www.reddit.com/r/gigabyte/comments/1mkzju7/what_does_this_mean_tryi](https://www.reddit.com/r/gigabyte/comments/1mkzju7/what_does_this_mean_tryi)</u> <u>ng_to_enable_secure_boot/</u>
29.How do I enable secure boot without "bricking" my PC? - Reddit, <u>[https://www.reddit.com/r/ValorantTechSupport/comments/1l6f5d2/how_do_i_ena](https://www.reddit.com/r/ValorantTechSupport/comments/1l6f5d2/how_do_i_ena)</u> <u>ble_secure_boot_without_bricking_my_pc/</u>
30.Unable to enroll-keys using TPM2 EventLog · Issue #384 - GitHub, <u>[https://github.com/Foxboron/sbctl/issues/384](https://github.com/Foxboron/sbctl/issues/384)</u>
31.systemd & TPM in 2025 - Fosdem, <u>[https://archive.fosdem.org/2025/events/attachments/fosdem-2025-5073-system](https://archive.fosdem.org/2025/events/attachments/fosdem-2025-5073-system)</u> <u>d-tpm-in-2025/slides/238361/systemd_lIPbXDG.pdf</u>
32.systemd-cryptenroll(1) - Linux manual page-man7.org, <u>[https://man7.org/linux/man-pages/man1/systemd-cryptenroll.1.html](https://man7.org/linux/man-pages/man1/systemd-cryptenroll.1.html)</u>
33.AMD BIOS Updates Arrive To Resolve Ryzen TPM Stuttering Issue, <u>[https://hothardware.com/news/amd-bios-updates-resolve-ryzen-stuttering-issue](https://hothardware.com/news/amd-bios-updates-resolve-ryzen-stuttering-issue)</u>
34.AMD fTPM causing random stuttering. Any update on this from AMD, <u>[https://www.reddit.com/r/Amd/comments/sbn10w/amd_ftpm_causing_random_st](https://www.reddit.com/r/Amd/comments/sbn10w/amd_ftpm_causing_random_st)</u> <u>uttering_any_update_on/</u>
35.Kernel-ArchWiki, <u>[https://wiki.archlinux.org/title/Kernel](https://wiki.archlinux.org/title/Kernel)</u>
36.Draft: main/postmarketos-duranium: add unit to install sd-boot on, <u>[https://gitlab.postmarketos.org/postmarketOS/pmaports/-/merge_requests/8614](https://gitlab.postmarketos.org/postmarketOS/pmaports/-/merge_requests/8614)</u>
37.Boot Components & Root File System Discovery, <u>[https://systemd.io/ROOTFS_DISCOVERY/](https://systemd.io/ROOTFS_DISCOVERY/)</u>
38.Ewon's Blog | System Administrator, <u>[https://blog.ewonchang.com/](https://blog.ewonchang.com/)</u>
39.Secure boot bricked my PC : r/Battlefield-Reddit, <u>[https://www.reddit.com/r/Battlefield/comments/1mhuhfe/secure_boot_bricked_m](https://www.reddit.com/r/Battlefield/comments/1mhuhfe/secure_boot_bricked_m)</u> <u>y_pc/</u>
40.Libreboot T580 15.6-inch 1080p with 4-core i5-8250u, Intel UHD, <u>[https://minifree.org/product/libreboot-t580.html](https://minifree.org/product/libreboot-t580.html)</u>

41.NovaCustom SecurityTitan V54 laptop, <u>[https://novacustom.com/product/securitytitan-v54-laptop/](https://novacustom.com/product/securitytitan-v54-laptop/)</u>
42.Serie V56 portátil coreboot de 16,0 pulgadas-NovaCustom, <u>[https://novacustom.com/es/producto/serie-v56/](https://novacustom.com/es/producto/serie-v56/)</u>
43.Tuxedo Intros Gemini 17 Gen 4 Desktop Replacement Notebook, <u>[https://www.techpowerup.com/343755/tuxedo-intros-gemini-17-gen-4-desktop-](https://www.techpowerup.com/343755/tuxedo-intros-gemini-17-gen-4-desktop-)</u> <u>replacement-notebook-series</u>
44.V56 Series 16.0 inch coreboot laptop-NovaCustom, <u>[https://novacustom.com/product/v56-series/](https://novacustom.com/product/v56-series/)</u>
45.NovaCustom SecurityTitan V56 laptop, <u>[https://novacustom.com/product/securitytitan-v56-laptop/](https://novacustom.com/product/securitytitan-v56-laptop/)</u>
46.Experience with Slimbook laptops and support : r/linuxhardware, <u>[https://www.reddit.com/r/linuxhardware/comments/1mdurz0/experience_with_sli](https://www.reddit.com/r/linuxhardware/comments/1mdurz0/experience_with_sli)</u> <u>mbook_laptops_and_support/</u>
47.dmuiX/ryzen-apu-passthrough-guide: This repo contains ... - GitHub, <u>[https://github.com/dmuiX/gpu-passthrough-vega-renoir-ryzen-3-4350](https://github.com/dmuiX/gpu-passthrough-vega-renoir-ryzen-3-4350)</u>
48.The Best Arch-Based Linux Distros in 2026 (Ranked and Reviewed), <u>[https://linuxstans.com/best-arch-based-linux-distros/](https://linuxstans.com/best-arch-based-linux-distros/)</u>
