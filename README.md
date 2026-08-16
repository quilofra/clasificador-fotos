# Clasificador de Fotos

App nativa de macOS (SwiftUI) para repartir montones de fotos y vídeos entre carpetas **a golpe de tecla**. Pensada para cuando tienes miles de archivos de sitios distintos (una exportación de WhatsApp, la cámara, carpetas sueltas) y quieres decidir de quién es cada uno mientras los vas viendo, sin arrastrar nada a mano.

**Siempre copia, nunca mueve.** Tus originales no se tocan jamás.

## Cómo se usa

1. **Pool** — arrastra ahí fotos, vídeos o carpetas enteras. Se acumulan en una lista única.
2. **Clasificar** — te las enseña una a una a pantalla completa y decides con una tecla.
3. **Resumen** — sesiones, reparto por categoría, carpeta destino y las descartadas.

## Sesiones

Cada sesión es un **pool independiente**, con sus fotos, sus decisiones, su historial de deshacer y su carpeta destino. Sirve para tener varios trabajos a medias sin que se mezclen.

- **Nueva sesión** con `⌘N`. Hereda la carpeta destino de la actual y eliges qué clasificaciones tendrá.
- **Cambiar de sesión** guarda la actual automáticamente.
- **Duplicar** copia pool y decisiones a una sesión nueva, sin tocar el disco.
- **Eliminar** borra solo la sesión; ni originales ni copias ya hechas se tocan.

## Clasificaciones

Cada sesión tiene las suyas, elegidas al crearla y cambiables en **Resumen**. Por defecto vienen cuatro: `Persona 1`, `Persona 2`, `Las dos` y `Descartar`.

**La tecla es la posición, no la categoría.** En una sesión de dos clasificaciones, `2` es la segunda que tenga esa sesión. Lo que ves en el chip es siempre la tecla que hay que pulsar.

Por dentro cada clasificación tiene un id fijo, que es lo que se guarda en cada decisión: reordenar o quitar clasificaciones no altera lo ya clasificado, y no se puede quitar una que ya hayas usado.

| Categoría por defecto | Copia en |
|---|---|
| Persona 1 | `Persona 1/` |
| Persona 2 | `Persona 2/` |
| Las dos | `Persona 1/` + `Persona 2/` + `Las dos/` |
| Descartar | `Descartadas/` |

Se cambian en `Models.swift`, en `Category.defaults`: nombre, subcarpetas destino (varias = copia en todas, vacío = no copia), color e icono. Añade una quinta y saldrá sola con la tecla `5`.

## Atajos

| Tecla | Acción |
|---|---|
| `1` … `N` | clasificar (según la posición en esta sesión) |
| `←` `→` `↑` `↓` | lo mismo que 1 / 2 / 3 / 4 |
| deslizar | izquierda 1 · derecha 2 · arriba 3 · abajo 4 |
| `⌘Z` | deshacer la última |
| `R` / `⇧R` | girar a la derecha / izquierda |
| `+` `−` `0` | acercar · alejar · ajustar |
| `F` | pantalla completa |
| `T` | mostrar/ocultar la tira de miniaturas |
| `I` | panel con todos los datos |
| `V` | abrir en Vista previa |
| `C` | comparar con su gemela (si es duplicada) |
| `M` | silenciar el vídeo |
| `⇧←` `⇧→` | moverse sin clasificar |

## Ver y revisar

- **Barra fija de datos** bajo la foto: nombre, fecha (con su origen), tamaño, dimensiones, duración, cámara y si trae ubicación.
- **Panel completo con `I`**: además objetivo, focal, apertura, exposición, ISO y coordenadas GPS con enlace a Mapas. (Las fotos de WhatsApp no traen nada de esto: WhatsApp borra el EXIF entero.)
- **Zoom** con rueda, pellizco, `+` `−` o doble clic. Con zoom, arrastrar desplaza en vez de clasificar.
- **Tira de miniaturas** con el color de cómo quedó cada una.
- **Comparar duplicados** lado a lado con `C`.
- **Girar** con `R`: se aplica solo a la copia, nunca al original, y **sin recomprimir** — en fotos se reescribe la orientación EXIF; en vídeos, la matriz del átomo `tkhd`.

## En el Pool

- **Ordenar** por fecha, nombre, tamaño o tipo. Reordena el pool de verdad, así que cambia el orden en que las verás.
- **Filtrar** por nombre, tipo, año, «sin clasificar» o «duplicados».
- **Clasificar en lote**: selecciona varias y mándalas de golpe a una categoría.

## Detalles que importan

- **Las copias no ocupan disco.** Se hacen con `clonefile` de APFS: copia instantánea que comparte los datos con el original hasta que uno de los dos cambie. Son archivos normales, no alias: si borras el original, la copia sigue entera. Al moverlas a otro disco sí ocupan su tamaño real.
- **Duplicados**: detecta archivos con el mismo contenido aunque se llamen distinto. Para no leer decenas de GB, primero agrupa por tamaño y solo calcula el SHA-256 de los que coinciden. Te lo marca en naranja pero te enseña la foto igual: decides tú.
- **Estado**: se guarda solo en `~/Library/Application Support/ClasificadorFotos/`. Cierra la app a mitad de 5.000 fotos y al volver sigues donde estabas.
- **Deshacer** borra las copias creadas y devuelve la foto al montón.
- Las copias conservan la fecha del original.
- Las fotos grandes se cargan reducidas a tamaño de pantalla y la siguiente se precarga.

## Compilar

```bash
./construir.sh          # instala en ~/Applications
```

Necesita Xcode y Pillow (`pip install pillow`) para el icono. Compila, arma el `.app`, lo firma en modo ad-hoc y lo instala.

## Estructura

```
Sources/Clasificador/
├── App.swift          ventana, pestañas y menús
├── Models.swift       categorías y elementos del pool
├── Store.swift        estado, copiado, deshacer y sesiones
├── Media.swift        rastreo de carpetas, EXIF y duplicados
├── Thumbnail.swift    miniaturas con caché
├── PoolView.swift     pestaña Pool
├── ClassifyView.swift pestaña Clasificar
└── SummaryView.swift  pestaña Resumen
```

## Licencia

MIT.
