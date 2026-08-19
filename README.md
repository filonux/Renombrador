[![Icono de Renombrador](assets/icon.png)](assets/icon.png)

# Renombrador

Renombra archivos y carpetas por lotes desde un menú en la terminal o con clic derecho en Nemo, con vista previa antes de aplicar nada y la opción de deshacerlo después.

![Bash 4+](https://img.shields.io/badge/bash-%3E%3D4.0-4EAA25?logo=gnubash&logoColor=white)
![Linux Mint 22.3 Cinnamon](https://img.shields.io/badge/Linux%20Mint-22.3%20Cinnamon-87CF3E?logo=linuxmint&logoColor=white)
![Licencia GPLv3](https://img.shields.io/badge/licencia-GPLv3-blue)

---

Es un único script de Bash, sin más dependencia obligatoria que un selector gráfico de archivos (`zenity` o `kdialog`). Pensado para el uso de cada día: renombrar 40 fotos, 200 facturas o una carpeta de descargas con nombres inconsistentes, sin hacerlo archivo por archivo ni arriesgarse a que dos acaben con el mismo nombre.

**Índice:** [Compatibilidad](#compatibilidad) · [Instalación](#instalación) · [Guía rápida](#guía-rápida-renombrar-una-carpeta-de-fotos) · [Métodos disponibles](#métodos-de-renombrado-disponibles) · [Deshacer](#deshacer-y-por-qué-es-seguro) · [Línea de comandos](#modo-línea-de-comandos) · [Scriptya](#instalar-y-lanzar-renombrador-con-scriptya) · [Idioma y roadmap](#idioma-y-roadmap) · [Contribuir](#contribuir)

## Compatibilidad

Desarrollado y probado en **Linux Mint 22.3 Cinnamon**. El motor de renombrado en sí (Bash + coreutils) no depende de Cinnamon para nada: solo hace falta `zenity` o `kdialog` para los selectores gráficos, así que funciona igual en cualquier distro con Bash 4 o superior. Entre las más conocidas:

- **Basadas en Ubuntu/Debian**: Ubuntu, Debian, Linux Mint, Pop!_OS, elementary OS, Zorin OS, MX Linux...
- **Basadas en Fedora**: Fedora, Nobara...
- **Basadas en Arch**: Arch Linux, Manjaro, EndeavourOS...
- **openSUSE**: Leap y Tumbleweed

Si no hay `zenity` instalado, el propio script detecta cuál de estos gestores de paquetes usa el sistema (`apt`, `dnf`, `pacman` o `zypper`) y se ofrece a instalarlo automáticamente.

La integración de clic derecho es específica del gestor de archivos **Nemo** (el de Cinnamon), presente en Linux Mint y en cualquier distro que use el escritorio Cinnamon. Con el resto de escritorios (GNOME, KDE Plasma, Xfce, MATE...) el script funciona exactamente igual desde la terminal; simplemente no hay entrada en el menú contextual del gestor de archivos.

También se adapta a terminales más limitadas: en una consola virtual sin entorno gráfico o una sesión SSH sin locale UTF-8, los emoji y símbolos de los menús caen automáticamente a texto plano en vez de mostrarse como caracteres rotos.

## Instalación

```bash
git clone https://github.com/filonux/Renombrador.git
cd Renombrador/script
chmod +x renombrador.sh
./renombrador.sh
```

Eso abre el menú principal directamente, sin instalar nada en el sistema. Por ahora esta es la única vía de instalación — no hay paquete `.deb` todavía (ver el mini roadmap más abajo). Para tenerlo también en el clic derecho de Nemo:

```bash
./renombrador.sh --instalar-nemo
```

Esto copia el script y su icono a `~/.local/share/renombrador/` y añade la acción «Renombrar con Renombrador...» al menú contextual de Nemo. Para quitarla: `./renombrador.sh --desinstalar-nemo` (o la opción 5 del menú principal, que cambia sola entre «Integrar» y «Quitar integración» según el estado actual).

Dependencia opcional: `exiftool` (paquete `libimage-exiftool-perl`) o `identify` de ImageMagick, para leer la fecha real de captura de una foto. Sin ninguna de las dos, las opciones que dependen de esa fecha caen automáticamente en la fecha de modificación del archivo.

## Guía rápida: renombrar una carpeta de fotos

Un ejemplo completo, de principio a fin. Supongamos que hay una carpeta `~/Imágenes/Vacaciones` llena de fotos con nombres como `IMG_2031.jpg`, `IMG_2032.jpg`... y se quieren dejar como `Vacaciones_001.jpg`, `Vacaciones_002.jpg`..., numeradas por el orden real en que se tomaron.

1. Se abre una terminal y se ejecuta el script:

   ```bash
   ./renombrador.sh
   ```

   Aparece el menú principal.

2. Se elige `1` (**Renombrar una carpeta completa**). Se abre el selector de carpetas: se navega hasta `Vacaciones` y se acepta.

3. El script hace algunas preguntas de sí/no por teclado (subcarpetas, ocultos, filtro por extensión...). Para este caso basta con pulsar **Enter** en todas y dejar los valores por defecto.

4. Aparece el menú de métodos. Se elige `1` (**Numeración secuencial**).

5. Pregunta:
   - **Texto base**: se escribe `Vacaciones`
   - **Orden**: se elige `3` (fecha EXIF real de la foto), para que `001` sea la primera foto tomada de verdad y no la primera por orden alfabético
   - **Número inicial** y **dígitos de relleno**: Enter en ambos, para que el script los calcule solo

6. Aparece una vista previa: `IMG_2031.jpg → Vacaciones_001.jpg`, y así con cada archivo. Si se quiere añadir otra transformación encima (por ejemplo, pasar todo a minúsculas), se elige otro método del menú; si ya está como se quiere, se escribe `a` (**Aplicar todos los cambios**).

7. Pregunta si **mover** (renombra los archivos de verdad) o **copiar** (deja los originales intactos y crea copias con el nombre nuevo). Para una primera prueba, copiar es la opción más tranquila.

8. Se confirma con `s` y listo — las fotos ya tienen su nombre nuevo.

Escrito paso a paso parece largo, pero la mitad de esos pasos se resuelven pulsando Enter para aceptar el valor por defecto: en la práctica son un par de minutos de teclado para dejar ordenada toda la carpeta, en vez de renombrar las fotos una a una a mano.

¿Algo salió mal? Se vuelve al menú principal, opción `4` (**Deshacer renombrado**), Enter para elegir el lote más reciente, y confirmar. Todo vuelve a como estaba.

Para no tocar la terminal en el día a día: se instala la integración con Nemo una vez (`./renombrador.sh --instalar-nemo`) y luego, desde el gestor de archivos, se seleccionan los archivos y clic derecho → **«Renombrar con Renombrador...»**. Se abre una terminal con esos archivos ya cargados, directa en el paso 4 de arriba.

## Métodos de renombrado disponibles

Desde el menú de métodos se puede aplicar uno o varios de estos, en cualquier orden y encadenados entre sí, con vista previa acumulada en todo momento y la opción de deshacer el último paso si algo no cuadra, antes de confirmar nada:

| Método | Qué hace |
| --- | --- |
| Numeración secuencial | Texto fijo + número, o el nombre original + número. Se puede ordenar por orden actual, fecha de modificación, fecha EXIF real o tamaño. |
| Añadir prefijo | Antepone un texto a cada nombre. |
| Añadir sufijo | Añade un texto justo antes de la extensión. |
| Buscar y reemplazar | Texto literal o expresión regular (ERE), con grupos de captura `\1`, `\2`... en el reemplazo. |
| MAYÚSCULAS/minúsculas | minúsculas, MAYÚSCULAS, Capitalizar Cada Palabra, o solo la primera letra de la frase. |
| Insertar fecha | Fecha actual, fecha de modificación o fecha EXIF real, al principio o al final del nombre. |
| Limpiar nombre | Sustituye espacios por guion bajo, guion, o los elimina; quita caracteres no válidos en nombres de archivo. |
| Plantilla automática por tipo | Clasifica por tipo de archivo (Foto, Video, Audio, Documento, Comprimido, Código...) y numera dentro de cada tipo. |
| Plantilla personalizada | Aplica una plantilla ya guardada, con comodines. Se gestionan (crear, listar, eliminar, exportar, importar) desde la opción 3 del menú principal. |
| Patrón puntual | Igual que una plantilla, pero sin guardarla para más adelante. |

Las plantillas y el patrón puntual usan estos comodines:

| Comodín | Se sustituye por |
| --- | --- |
| `{name}` | Nombre original, sin extensión |
| `{ext}` | Extensión original, sin el punto |
| `{n}` | Número de secuencia (pregunta por dónde empieza y cuántos dígitos de relleno) |
| `{date}` | Fecha de hoy, en formato `AAAA-MM-DD` |
| `{parent}` | Nombre de la carpeta que contiene el archivo |

Si la plantilla no incluye `{ext}`, la extensión original se añade sola al final. Ejemplo: `{date}_{name}_{n}` sobre `factura.pdf` → `2026-08-04_factura_1.pdf`.

## Deshacer y por qué es seguro

Cada lote aplicado queda guardado en un historial: la opción `4` del menú principal deja repasar los últimos 20 lotes y deshacer el que se quiera, no solo el más reciente.

Deshacer un lote aplicado en modo copiar no «restaura» nada (los originales nunca se tocaron): simplemente borra las copias que se crearon. Un lote en modo mover sí devuelve cada archivo a su nombre original.

Por debajo, tanto al aplicar como al deshacer, los cambios se hacen en dos fases: primero se mueve todo a nombres temporales únicos y solo después a los nombres finales. Así, un lote donde el archivo A pasa a llamarse B y B pasa a llamarse A a la vez se resuelve bien, en lugar de que uno se sobrescriba al otro — algo con lo que un simple `mv` en bucle no sabe lidiar.

Los nombres nuevos también se sanean solos (se recortan espacios, se quitan caracteres no válidos, se limitan a 255 bytes), y nunca se sobrescribe nada sin que se diga explícitamente: por defecto, si un nombre ya existe, se le añade un sufijo automático `(1)`, `(2)`..., aunque también se puede pedir que sobrescriba el existente o que omita ese elemento en su lugar. En lotes de más de 200 elementos se muestra además una barra de progreso mientras se aplican los cambios.

## Modo línea de comandos

Todo lo anterior también se puede pedir sin pasar por ningún menú, para automatizarlo con atajos de teclado, scripts propios o tareas programadas. Es opcional — el uso normal, del día a día, no lo necesita. Cada método interactivo tiene su equivalente en flags:

| `--metodo` | Parámetros principales |
| --- | --- |
| `numeracion` | `--base TEXTO` o `--mantener-nombre`, `--inicio N`, `--digitos N`, `--orden actual\|fecha\|exif\|tamano` |
| `prefijo` | `--prefijo TEXTO` |
| `sufijo` | `--sufijo TEXTO` |
| `buscar-reemplazar` | `--buscar TEXTO --reemplazar TEXTO`, `--regex` |
| `mayus-minus` | `--caso minusculas\|mayusculas\|capitalizar\|frase` |
| `fecha` | `--fecha-origen actual\|modificacion\|exif`, `--fecha-pos inicio\|final` |
| `limpiar` | `--espacios guion_bajo\|guion\|eliminar` |
| `tipo` | (sin parámetros extra) |
| `plantilla` | `--plantilla NOMBRE` |
| `patron` | `--patron '{date}_{name}_{n}'` |

Más los flags generales: origen con `--carpeta RUTA` o `--archivo RUTA` (repetible); selección con `--recursivo`, `--ocultos`, `--incluir-carpetas`, `--seguir-enlaces`, `--filtro ext1,ext2`; y aplicación con `--modo mover\|copiar`, `--conflicto sufijo\|sobrescribir\|omitir`, `--dry-run` y `--sin-confirmar`.

```bash
./renombrador.sh --carpeta ~/Fotos --recursivo --metodo fecha --fecha-origen exif --dry-run
./renombrador.sh --carpeta ~/Descargas --metodo prefijo --prefijo "2026_" --sin-confirmar
```

`--dry-run` enseña el resultado sin tocar nada; `--sin-confirmar` aplica los cambios directamente. La lista completa está siempre disponible con `./renombrador.sh --ayuda`, y la versión instalada con `./renombrador.sh --version`.

## Instalar y lanzar Renombrador con Scriptya

[Scriptya](https://github.com/filonux/Scriptya) es un lanzador de scripts: organiza los tuyos en un menú con búsqueda y puede convertir cualquiera de ellos en una app de escritorio con su propio icono, sin escribir un `.desktop` a mano. Reconoce unos metadatos opcionales en las primeras líneas del script, justo después del shebang. Basta con añadir algo así al principio de `renombrador.sh` para que aparezca en el menú de Scriptya con nombre y descripción propios, en vez del nombre del archivo:

```bash
#!/usr/bin/env bash
# MENU: Renombrador
# DESCRIPTION: Renombra archivos y carpetas por lotes, con plantillas y deshacer
# TERMINAL: true
```

Si ya se tiene Scriptya instalado:

1. Se copia o clona `Renombrador/` (o solo `script/renombrador.sh`) dentro de la carpeta de scripts configurada en Scriptya.
2. Se abre Scriptya (`scriptya`). Renombrador aparece en el menú y se lanza en una terminal nueva al seleccionarlo.
3. Para un icono propio y una entrada independiente en el menú de Cinnamon o en el escritorio, se usa **«Instalar Scripts»** (en el propio menú de Scriptya, o con `scriptya --icons`), eligiendo `renombrador.sh` y apuntando a `assets/icon.png` de este repositorio cuando pida un icono.

Si todavía no se tiene Scriptya, su instalador (`./scriptya.sh --install`) deja elegir o crear esa carpeta de scripts la primera vez. Es completamente opcional: Renombrador funciona igual con o sin Scriptya de por medio.

## Idioma y roadmap

Renombrador está en español: menús, ayuda, mensajes y comentarios del código. No hay versión en inglés todavía.

**Mini roadmap**, sujeto a que haya interés real:

- [ ] Traducción completa de menús, ayuda y mensajes al inglés
- [ ] Forma de elegir idioma (detección del sistema o flag `--lang`)
- [ ] Documentación en inglés
- [ ] Paquete `.deb` para instalar con `apt`/`dpkg`, sin pasar por `git clone`

Si interesa usarlo en inglés o tener un paquete `.deb` listo para instalar, decirlo en un issue es la señal que hace falta para priorizarlo.

## Contribuir

Los issues y pull requests son bienvenidos — hay plantillas en `.github/` para reportar errores o proponer mejoras. La guía completa está en [CONTRIBUTING.md](.github/CONTRIBUTING.md), y las normas de convivencia del proyecto en [CODE_OF_CONDUCT.md](.github/CODE_OF_CONDUCT.md). Para reportar un fallo de seguridad, mejor en privado siguiendo [SECURITY.md](.github/SECURITY.md) que abriendo un issue público.

## Licencia

GPLv3. Consulta el fichero [LICENSE](LICENSE).

---

Hecho por **Filonux**.
