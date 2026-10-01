#!/usr/bin/env bash
# Renombrador - terminal-menu batch renaming for files/folders (CLI mode, templates, undo, optional Nemo integration)
# Copyright (C) 2026 Filonux - GPLv3 license (see LICENSE.txt)

# Bash 4.1+ ({fd} redirections); checked first so an older Bash stops before any newer syntax.
if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 1) )); then
  printf 'Renombrador requiere Bash 4.1 o superior (versión detectada: %s).\n' "${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}" >&2
  printf 'Renombrador requires Bash 4.1 or newer (detected version: %s).\n' "${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}" >&2
  return 1 2>/dev/null || exit 1
fi

VERSION="1.1.0"
# Bash 5.2 expands "&" in ${v//pat/repl}; names like "Q&A" must stay literal.
shopt -u patsub_replacement 2>/dev/null
CONFIG_DIR="$HOME/.config/renombrador"
TEMPLATES_FILE="$CONFIG_DIR/plantillas.conf"
PLANTILLAS_LOCK_FILE="$CONFIG_DIR/plantillas.lock"
IDIOMA_FILE="$CONFIG_DIR/idioma.conf"
HISTORY_DIR="$CONFIG_DIR/historial"
MAX_HISTORIAL=20
LOG_SEP=$'\x1f'  # history field separator
NEMO_DIR="$HOME/.local/share/nemo/actions"
NEMO_ACTION="$NEMO_DIR/renombrador.nemo_action"
APP_DIR="$HOME/.local/share/renombrador"
APP_SCRIPT="$APP_DIR/renombrador.sh"
# Nemo reliably accepts only theme icon names in Icon-Name (older versions ignore absolute
# paths): the icon goes into the user's hicolor theme and is referenced by name.
APP_ICON_NAME="renombrador"
APP_ICON_THEME="$HOME/.local/share/icons/hicolor"
APP_ICON="$APP_ICON_THEME/64x64/apps/$APP_ICON_NAME.png"

# ---- Language ----
# Detected first: I_WARN needs APP_LANG.

detectar_idioma() {
  local loc="${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}"
  loc="${loc,,}"
  [[ "$loc" =~ ^es([_.@-]|$) ]] && printf 'es' || printf 'en'
}

# Saved language: a regular file (never a symlink) holding exactly "es" or "en".
idioma_guardado() {
  local v=""
  [[ -f "$IDIOMA_FILE" && ! -L "$IDIOMA_FILE" ]] || return 1
  IFS= read -r v < "$IDIOMA_FILE" || [[ -n "$v" ]]
  [[ "$v" == es || "$v" == en ]] && printf '%s' "$v"
}

# Precedence: RENOMBRADOR_LANG, saved language, system locale.
if [[ "${RENOMBRADOR_LANG:-}" == "es" || "${RENOMBRADOR_LANG:-}" == "en" ]]; then
  APP_LANG="$RENOMBRADOR_LANG"
else
  APP_LANG="$(idioma_guardado || detectar_idioma)"
fi

if [[ -t 1 ]] && (( $(tput colors 2>/dev/null || echo 0) >= 256 )); then
  C_RESET=$'\e[0m'; C_TITLE=$'\e[1;38;5;51m'; C_ACCENT=$'\e[38;5;213m'
  C_OK=$'\e[1;38;5;114m'; C_WARN=$'\e[1;38;5;221m'; C_ERR=$'\e[1;38;5;203m'
  C_DIM=$'\e[2;38;5;245m'; C_PROMPT=$'\e[38;5;75m'; C_BORDER=$'\e[38;5;39m'
elif [[ -t 1 ]]; then
  C_RESET=$'\e[0m'; C_TITLE=$'\e[1;36m'; C_ACCENT=$'\e[1;35m'
  C_OK=$'\e[1;32m'; C_WARN=$'\e[1;33m'; C_ERR=$'\e[1;31m'
  C_DIM=$'\e[2;37m'; C_PROMPT=$'\e[36m'; C_BORDER=$'\e[34m'
else
  C_RESET=''; C_TITLE=''; C_ACCENT=''; C_OK=''; C_WARN=''; C_ERR=''; C_DIM=''; C_PROMPT=''; C_BORDER=''
fi

# Plain bullet instead of emoji when the locale is not UTF-8 or on the Linux
# console (TERM=linux), whose font has no emoji glyphs.
SIN_EMOJI=0
_loc="${LC_ALL:-${LC_CTYPE:-${LANG:-}}}"
if [[ "${_loc^^}" != *UTF-8* && "${_loc^^}" != *UTF8* ]]; then
  SIN_EMOJI=1
elif [[ "${TERM:-}" == "linux" ]]; then
  SIN_EMOJI=1
fi
unset _loc

# Status symbols share the SIN_EMOJI fallback; I_WARN depends on APP_LANG, so
# actualizar_icono_aviso() re-runs on every language change.
if (( SIN_EMOJI )); then
  I_OK='OK:'; I_ERR='ERROR:'; I_ARROW='->'
else
  I_OK='✔'; I_ERR='✖'; I_ARROW='→'
fi
actualizar_icono_aviso() {
  if (( SIN_EMOJI )); then
    [[ "$APP_LANG" == "en" ]] && I_WARN='WARN:' || I_WARN='AVISO:'
  else
    I_WARN='⚠'
  fi
}
actualizar_icono_aviso

declare -A TXT_ES=(
  [pause]="Pulsa Enter para continuar..."
  [nemo_name]="Renombrar con Renombrador..."
  [nemo_comment]="Renombra los archivos o carpetas seleccionadas"
  [nemo_integrated]="Integrado en Nemo."
  [nemo_refresh]="Si no aparece de inmediato, cierra y vuelve a abrir Nemo."
  [nemo_reload_hint]="Si Nemo no refleja el cambio, ciérralo y ábrelo de nuevo."
  [nemo_removed]="Acción de Nemo eliminada."
  [nemo_remove_error]="No se pudo quitar la acción de Nemo."
  [icon_install_error]="No se pudo instalar el icono de Renombrador."
  [nemo_action_error]="No se pudo instalar la acción de Nemo."
  [nemo_activated]="Acción de Nemo activada."
  [nemo_deactivated]="Acción de Nemo desactivada."
  [nemo_toggle_error]="No se pudo actualizar la acción de Nemo."
  [nemo_not_installed]="La integración con Nemo no está instalada."
  [nemo_state_active]="activa"
  [nemo_state_inactive]="desactivada"
  [nemo_manage_prompt]="La integración con Nemo está %s. [a] Activar/desactivar   [q] Quitar integración   [Enter] Volver: "
  [nemo_remove_confirm]="¿Quitar la integración con Nemo? (s/n) [n]: "
  [selector_missing]="No se encontró 'zenity' ni 'kdialog' (selector gráfico de archivos)."
  [install_selector]="¿Instalar zenity ahora? (s/n): "
  [selector_required]="No se puede continuar sin un selector gráfico."
  [unknown_package]="Gestor de paquetes no reconocido. Instala zenity manualmente."
  [install_failed]="No se pudo instalar zenity."
  [cancelled]="Cancelado."
  [select_folder]="Selecciona una carpeta"
  [select_files]="Selecciona archivos"
  [include_subdirs]="¿Incluir subcarpetas? (s/n) [n]: "
  [include_hidden]="¿Incluir archivos y carpetas ocultas? (s/n) [n]: "
  [include_folders]="¿Incluir también las carpetas como elementos a renombrar? (s/n) [n]: "
  [follow_links]="¿Seguir enlaces simbólicos al buscar? (s/n) [n]: "
  [filter_ext]="Filtrar por extensión, ej: jpg,png [Enter = todas]: "
  [none_found]="No se encontraron elementos."
  [found]="%s elemento(s) encontrado(s)."
  [large_batch]="Es un lote muy grande, ¿continuar de todas formas? (s/n) [n]: "
  [selected]="%s archivo(s) seleccionado(s)."
  [no_undo_steps]="No hay pasos que deshacer."
  [preview_queue_title]="Vista previa acumulada"
  [queue_steps]="%s paso(s) en cola"
  [more_files]="... %s archivo(s) más ..."
  [more_elements]="... %s elemento(s) más ..."
  [conflict_found]="%s nombre(s) ya existían fuera del lote. ¿Qué hacer con ellos?"
  [conflict_suffix]="Añadir sufijo automático (1), (2)...  [por defecto]"
  [conflict_overwrite]="Sobrescribir el archivo o carpeta existente (irreversible)"
  [conflict_skip]="Omitir (no renombrar esos elementos)"
  [conflict_prompt]="➤ Opción [1]: "
  [omitted]="Omitidos: %s"
  [unchanged]="Sin cambios: %s"
  [summary_move]="Renombrados"
  [summary_copy]="Copias creadas"
  [preview]="Vista previa"
  [preview_count]="(%s elemento(s))"
  [collision]="%s colisión(es) entre los nuevos nombres: se resolverán solas con un sufijo (1), (2)..."
  [apply_move]="Mover / renombrar los originales  [por defecto]"
  [apply_copy]="Copiar (deja los originales intactos)"
  [apply_prompt]="➤ ¿Cómo aplicar los cambios? [1]: "
  [nested_copy_warn]="El lote incluye una carpeta y elementos dentro de ella: en modo copiar cada uno se copia por separado (no se anidan entre sí)."
  [dry_run]="Vista previa únicamente (--dry-run): no se aplicó ningún cambio."
  [confirm_apply]="➤ ¿Aplicar estos cambios? (s/n): "
  [copy_error]="Error al copiar '%s'"
  [prepare_error]="No se pudo preparar '%s'"
  [move_error]="Error al mover '%s' a su nombre final"
  [readonly_target]="No se puede escribir en '%s' ahora mismo (¿unidad de solo lectura, pestillo de protección activado, o sin permisos?). No se aplicó ningún cambio."
  [no_history]="No hay lotes en el historial."
  [history_invalid]="El historial está dañado o contiene una entrada no válida."
  [history_moved]="archivo(s) renombrado(s)"
  [history_copy]="copia(s) creada(s)"
  [undo_title]="Deshacer renombrado"
  [undo_subtitle]="Elige un lote del historial"
  [undo_prompt]="➤ Número de lote (Enter = más reciente, 0 = cancelar): "
  [original_exists]="'%s' ya existe, no se restaura '%s'"
  [copies_deleted]="Copias eliminadas: %s"
  [undone]="Deshechos: %s"
  [errors]="Fallos: %s"
  [numbering_custom]="Texto personalizado"
  [numbering_keep]="Mantener nombre original + número"
  [numbering_order]="Orden para asignar los números:"
  [numbering_current]="Como aparecen ahora"
  [numbering_mtime]="Fecha de modificación (antigua %s nueva)"
  [numbering_exif]="Fecha EXIF real de la foto (antigua %s nueva)"
  [numbering_size]="Tamaño (pequeño %s grande)"
  [numbering_start_hint]="Con qué número empieza la serie; el resto de archivos lo continúa desde ahí."
  [numbering_start]="Número inicial [1]: "
  [numbering_digits_hint]="Ceros a la izquierda para igualar el largo de los números (ej: con %s, «%s» se escribe «%s»)."
  [numbering_digits]="Dígitos de relleno [%s]: "
  [exif_fallback_short]="No se encontró 'exiftool' ni 'identify': se usará la fecha de modificación como respaldo."
  [exif_fallback_long]="No se encontró 'exiftool' ni 'identify' (ImageMagick): se usará la fecha de modificación como respaldo."
  [exif_install]="Instala 'libimage-exiftool-perl' para leer la fecha EXIF real de las fotos."
  [prefix]="Prefijo a añadir: "
  [suffix]="Sufijo a añadir (antes de la extensión): "
  [replace_literal]="Texto literal"
  [replace_regex]="Expresión regular (ERE)"
  [search]="Texto a buscar: "
  [replace]="Reemplazar por: "
  [empty_search]="Texto de búsqueda vacío, cancelado."
  [capture_hint]="Puedes usar grupos de captura \\1, \\2... en el reemplazo."
  [invalid_regex]="Expresión regular no válida: %s"
  [case_lower]="minúsculas"
  [case_upper]="MAYÚSCULAS"
  [case_title]="Capitalizar cada palabra"
  [case_sentence]="Primera letra de la frase"
  [invalid_option_no_change]="Opción no válida, no se aplicó ningún cambio."
  [date_current]="Fecha actual"
  [date_modified]="Fecha de modificación del archivo"
  [date_exif]="Fecha EXIF real (fotos)"
  [position_start]="Al principio"
  [position_end]="Al final"
  [clean_spaces]="Espacios"
  [clean_underscore]="guion bajo"
  [clean_dash]="guion"
  [clean_remove]="Eliminar espacios"
  [method_title]="Método de renombrado"
  [method_selected]="%s archivo(s) seleccionado(s)"
  [steps_pending]=" · %s paso(s) en cola sin aplicar"
  [method_numbering]="Numeración secuencial"
  [method_prefix]="Añadir prefijo"
  [method_suffix]="Añadir sufijo"
  [method_replace]="Buscar y reemplazar (texto o regex)"
  [method_case]="Cambiar MAYÚSCULAS/minúsculas"
  [method_date]="Insertar fecha"
  [method_clean]="Limpiar nombre (espacios y caracteres especiales)"
  [method_type]="Plantilla automática por tipo de archivo"
  [method_template]="Usar plantilla personalizada guardada"
  [method_new_template]="Crear y aplicar plantilla nueva"
  [method_pattern]="Aplicar patrón puntual (sin guardar)"
  [preview_queue]="Ver vista previa acumulada"
  [undo_step]="Deshacer último paso en cola"
  [apply_all]="Aplicar todos los cambios"
  [back]="Volver"
  [discard_pending]="Hay %s paso(s) sin aplicar, ¿descartarlos y volver? (s/n) [n]: "
  [template_hint]="Comodines: {name} {ext} {n} {date} {parent} {filedate} {filetime}\\n     {date} es hoy; {filedate}/{filetime} son la fecha y hora de cada archivo (EXIF en fotos)\\n     {ext} no incluye el punto · si el patrón no usa {ext}, la extensión original se añade sola al final"
  [pattern_n_hint]="El patrón usa {n}: con qué número empieza esa parte (el resto de archivos lo continúan)."
  [pattern_n_start]="Número inicial para {n} [1]: "
  [pattern_n_digits]="Ceros a la izquierda para {n} (ej: con %s, «%s» se escribe «%s»). Vacío = sin relleno."
  [pattern_n_digits_prompt]="Dígitos de relleno para {n} [sin relleno]: "
  [ambiguous_pattern]="El patrón no usa {name}, {n}, {date}, {parent}, {filedate} ni {filetime}: todos los archivos partirían del mismo nombre (se numerarán automáticamente)."
  [template_name]="Nombre para la plantilla: "
  [template_default_name]="Plantilla_%s"
  [pattern_prompt]="Patrón (ej: {date}_{name}_{n}): "
  [empty_pattern]="Patrón vacío, cancelado."
  [template_saved]="Plantilla «%s» guardada."
  [no_templates]="No hay plantillas guardadas."
  [load_templates_prompt]="¿Cargar plantillas desde un archivo guardado? (s/n) [n]: "
  [import_not_text]="El archivo no parece de texto o es demasiado grande: no es un archivo de plantillas."
  [select_template]="Selecciona una plantilla: "
  [applying_template]="Aplicando «%s»..."
  [delete_template_number]="Número de plantilla a eliminar: "
  [delete_template_confirm]="¿Eliminar «%s»? (s/n) [n]: "
  [template_deleted]="Plantilla «%s» eliminada."
  [templates_changed]="La lista de plantillas cambió mientras decidías; no se eliminó nada."
  [export_default]="plantillas_renombrador.txt"
  [export_title]="Exportar plantillas"
  [import_title]="Importar plantillas"
  [no_templates_export]="No hay plantillas para exportar."
  [exported]="Plantillas exportadas a '%s'."
  [export_failed]="No se pudo exportar."
  [file_not_found]="El archivo no existe."
  [file_unreadable]="No se puede leer el archivo (sin permiso de lectura)."
  [imported]="%s plantilla(s) importada(s).  (%s duplicada(s) omitida(s), %s línea(s) no válida(s))"
  [import_none]="Ninguna plantilla importada: el archivo no tiene líneas válidas con el formato «Nombre|Patrón».  (%s línea(s) no válida(s))"
  [templates_title]="Plantillas personalizadas"
  [templates_subtitle]="Crea, usa o elimina tus patrones de renombrado"
  [templates_list]="Listar plantillas"
  [templates_create]="Crear plantilla nueva"
  [templates_delete]="Eliminar plantilla"
  [templates_export]="Exportar plantillas a archivo"
  [templates_import]="Importar plantillas desde archivo"
  [received]="%s elemento(s) recibido(s) desde Nemo"
  [ready]="Listo para renombrar."
  [main_subtitle]="Renombrado de archivos por lotes"
  [main_folder]="Renombrar una carpeta completa"
  [main_files]="Renombrar archivos seleccionados"
  [main_templates]="Gestionar plantillas personalizadas"
  [main_undo]="Deshacer renombrado (historial)"
  [main_nemo_add]="Integrar con Nemo (clic derecho)"
  [main_nemo_remove]="Quitar integración con Nemo"
  [main_exit]="Salir"
  [option_prompt]="➤ Opción: "
  [choice_default]="Opción [1]: "
  [position_prompt]="Posición [2]: "
  [switch_to_en]="Cambiar a inglés"
  [switch_to_es]="Cambiar a español"
  [language_changed]="Idioma cambiado a español."
  [language_save_error]="No se pudo guardar el idioma: al reabrir volverá al predeterminado."
  [goodbye]="¡Hasta pronto!"
  [step_numbering]="Numeración"
  [step_prefix]="Prefijo"
  [step_suffix]="Sufijo"
  [step_regex]="Regex"
  [step_replace]="Buscar/reemplazar"
  [step_case]="Mayúsculas/minúsculas"
  [step_date_current]="Insertar fecha (actual)"
  [step_date_modified]="Insertar fecha (modificación)"
  [step_date_exif]="Insertar fecha (EXIF)"
  [step_clean]="Limpiar nombre"
  [step_type]="Tipo de archivo"
  [step_template]="Plantilla"
  [base_text]="Texto base (ej: Vacaciones): "
  [cli_need_value]="La opción '%s' necesita un valor."
  [cli_unknown_arg]="Argumento no reconocido: '%s' (usa --ayuda para ver las opciones)"
  [cli_digits_invalid]="Valor de --digitos no válido: '%s'"
  [cli_both_source]="Usa --carpeta o --archivo, no ambos a la vez."
  [cli_folder_missing]="La carpeta no existe: '%s'"
  [cli_unsafe_source]="No se puede procesar esta ruta: '%s'."
  [cli_start_invalid]="Valor de --inicio no válido: '%s'"
  [cli_item_missing]="No existe el elemento: '%s'"
  [cli_no_source]="Falta el origen: usa --carpeta RUTA o --archivo RUTA (repetible)."
  [cli_none]="No se encontraron elementos para renombrar."
  [cli_large]="Se han encontrado %s elementos; es un lote muy grande."
  [cli_found]="%s elemento(s) encontrado(s)."
  [cli_numbering_need_base]="El método 'numeracion' necesita --base TEXTO (o --mantener-nombre)."
  [cli_order_invalid]="Valor de --orden no válido: '%s' (usa: actual, fecha, exif, tamano)"
  [cli_replace_need_search]="El método 'buscar-reemplazar' necesita --buscar TEXTO."
  [cli_regex_invalid]="Expresión regular no válida: %s"
  [cli_case_invalid]="Valor de --caso no válido: '%s' (usa: minusculas, mayusculas, capitalizar, frase)"
  [cli_date_source_invalid]="Valor de --fecha-origen no válido: '%s' (usa: actual, modificacion, exif)"
  [cli_date_pos_invalid]="Valor de --fecha-pos no válido: '%s' (usa: inicio, final)"
  [cli_spaces_invalid]="Valor de --espacios no válido: '%s' (usa: guion_bajo, guion, eliminar)"
  [cli_template_need]="El método 'plantilla' necesita --plantilla NOMBRE."
  [cli_template_missing]="No existe la plantilla «%s»."
  [cli_pattern_need]="El método 'patron' necesita --patron 'TEXTO'."
  [cli_method_need]="Falta --metodo (usa --ayuda para ver la lista de métodos)."
  [cli_method_unknown]="Método no reconocido: '%s' (usa --ayuda para ver la lista de métodos)."
  [cli_lang_invalid]="Valor de --lang no válido: '%s' (usa: es, en)"
  [cli_mode_invalid]="Valor de --modo no válido: '%s' (usa: mover, copiar)"
  [cli_conflict_invalid]="Valor de --conflicto no válido: '%s' (usa: sufijo, sobrescribir, omitir)"
  [internal_error]="Error interno: las listas de nombres no coinciden."
  [storage_error]="No se pudo preparar el almacenamiento de configuración."
  [history_write_error]="No se pudo guardar el historial de forma segura."
  [history_changed]="El elemento cambió desde que se aplicó el lote; no se ha revertido."
  [history_legacy]="Este historial antiguo no puede deshacerse de forma segura porque no contiene una verificación del estado."
  [rollback_error]="No se pudo restaurar por completo el lote tras el error de historial."
  [backup_kept]="No se pudo devolver el original sobrescrito a su nombre; se conserva como '%s'."
  [restored_as]="Su nombre original ya estaba ocupado: el elemento queda como '%s'."
  [orphans_kept]="%s elemento(s) de una ejecución interrumpida en '%s' (.renombrador_tmp_*, .renombrador_undo_tmp_*, .renombrador_backup_*). Pueden ser tus archivos: no se borran; revísalos y renómbralos a mano."
  [interrupted]="Interrumpido. El lote quedó en un estado consistente; no se continúa."
  [invalid_option]="Opción no válida."
  [numbering_order_mtime_label]=", por fecha de modificación"
  [numbering_order_exif_label]=", por fecha EXIF"
  [numbering_order_size_label]=", por tamaño"
)

declare -A TXT_EN=(
  [pause]="Press Enter to continue..."
  [nemo_name]="Rename with Renombrador..."
  [nemo_comment]="Rename the selected files or folders"
  [nemo_integrated]="Integrated with Nemo."
  [nemo_refresh]="If it does not appear immediately, close and reopen Nemo."
  [nemo_reload_hint]="If Nemo does not show the change, close and reopen it."
  [nemo_removed]="Nemo action removed."
  [nemo_remove_error]="Could not remove the Nemo action."
  [icon_install_error]="Could not install the Renombrador icon."
  [nemo_action_error]="Could not install the Nemo action."
  [nemo_activated]="Nemo action activated."
  [nemo_deactivated]="Nemo action deactivated."
  [nemo_toggle_error]="Could not update the Nemo action."
  [nemo_not_installed]="The Nemo integration is not installed."
  [nemo_state_active]="active"
  [nemo_state_inactive]="disabled"
  [nemo_manage_prompt]="The Nemo integration is %s. [a] Activate/deactivate   [q] Remove integration   [Enter] Back: "
  [nemo_remove_confirm]="Remove the Nemo integration? (y/n) [n]: "
  [selector_missing]="Neither 'zenity' nor 'kdialog' was found (graphical file selector)."
  [install_selector]="Install zenity now? (y/n): "
  [selector_required]="Cannot continue without a graphical file selector."
  [unknown_package]="Unknown package manager. Install zenity manually."
  [install_failed]="Could not install zenity."
  [cancelled]="Cancelled."
  [select_folder]="Select a folder"
  [select_files]="Select files"
  [include_subdirs]="Include subfolders? (y/n) [n]: "
  [include_hidden]="Include hidden files and folders? (y/n) [n]: "
  [include_folders]="Include folders as items to rename? (y/n) [n]: "
  [follow_links]="Follow symbolic links when searching? (y/n) [n]: "
  [filter_ext]="Filter by extension, e.g. jpg,png [Enter = all]: "
  [none_found]="No items found."
  [found]="Found %s item(s)."
  [large_batch]="This is a very large batch. Continue anyway? (y/n) [n]: "
  [selected]="Selected %s file(s)."
  [no_undo_steps]="There are no steps to undo."
  [preview_queue_title]="Preview of queued changes"
  [queue_steps]="%s step(s) queued"
  [more_files]="... %s more file(s) ..."
  [more_elements]="... %s more item(s) ..."
  [conflict_found]="%s name(s) already exist outside this batch. What should we do with them?"
  [conflict_suffix]="Add an automatic suffix (1), (2)...  [default]"
  [conflict_overwrite]="Overwrite the existing file or folder (irreversible)"
  [conflict_skip]="Skip (do not rename those items)"
  [conflict_prompt]="➤ Option [1]: "
  [omitted]="Skipped: %s"
  [unchanged]="Unchanged: %s"
  [summary_move]="Renamed"
  [summary_copy]="Copies created"
  [preview]="Preview"
  [preview_count]="(%s item(s))"
  [collision]="%s name collision(s) among the new names: they will be resolved automatically with a suffix (1), (2)..."
  [apply_move]="Move / rename the originals  [default]"
  [apply_copy]="Copy (leave the originals untouched)"
  [apply_prompt]="➤ How should the changes be applied? [1]: "
  [nested_copy_warn]="The batch includes a folder and items inside it: in copy mode each one is copied separately (they are not nested into each other)."
  [dry_run]="Preview only (--dry-run): no changes were applied."
  [confirm_apply]="➤ Apply these changes? (y/n): "
  [copy_error]="Error copying '%s'"
  [prepare_error]="Could not prepare '%s'"
  [move_error]="Error moving '%s' to its final name"
  [readonly_target]="Cannot write to '%s' right now (read-only mount, write-protect tab, or missing permissions?). No changes were applied."
  [no_history]="There are no batches in the history."
  [history_invalid]="The history is corrupted or contains an invalid entry."
  [history_moved]="file(s) renamed"
  [history_copy]="copies created"
  [undo_title]="Undo renaming"
  [undo_subtitle]="Choose a batch from the history"
  [undo_prompt]="➤ Batch number (Enter = most recent, 0 = cancel): "
  [original_exists]="'%s' already exists; '%s' will not be restored"
  [copies_deleted]="Copies deleted: %s"
  [undone]="Reverted: %s"
  [errors]="Failures: %s"
  [numbering_custom]="Custom text"
  [numbering_keep]="Keep original name + number"
  [numbering_order]="Order used to assign numbers:"
  [numbering_current]="As currently listed"
  [numbering_mtime]="Modification date (oldest %s newest)"
  [numbering_exif]="Photo EXIF date (oldest %s newest)"
  [numbering_size]="Size (smallest %s largest)"
  [numbering_start_hint]="Choose the starting number for the series; subsequent files continue from there."
  [numbering_start]="Starting number [1]: "
  [numbering_digits_hint]="Leading zeros to keep all numbers the same length (e.g. with %s, «%s» is written as «%s»)."
  [numbering_digits]="Zero-padding digits [%s]: "
  [exif_fallback_short]="Neither 'exiftool' nor 'identify' was found. The file modification date will be used as a fallback."
  [exif_fallback_long]="Neither 'exiftool' nor 'identify' (ImageMagick) was found. The file modification date will be used as a fallback."
  [exif_install]="Install 'libimage-exiftool-perl' to read the photo's actual capture date from EXIF metadata."
  [prefix]="Prefix to add: "
  [suffix]="Suffix to add (before the extension): "
  [replace_literal]="Literal text"
  [replace_regex]="Regular expression (ERE)"
  [search]="Text to find: "
  [replace]="Replace with: "
  [empty_search]="Empty search text, cancelled."
  [capture_hint]="You can use capture groups \\1, \\2... in the replacement."
  [invalid_regex]="Invalid regular expression: %s"
  [case_lower]="lowercase"
  [case_upper]="UPPERCASE"
  [case_title]="Title Case"
  [case_sentence]="Sentence case"
  [invalid_option_no_change]="Invalid option; no changes applied."
  [date_current]="Current date"
  [date_modified]="File modification date"
  [date_exif]="Photo EXIF date"
  [position_start]="At the beginning"
  [position_end]="At the end"
  [clean_spaces]="Spaces"
  [clean_underscore]="underscore"
  [clean_dash]="dash"
  [clean_remove]="Remove spaces"
  [method_title]="Renaming method"
  [method_selected]="%s file(s) selected"
  [steps_pending]=" · %s step(s) queued but not applied"
  [method_numbering]="Sequential numbering"
  [method_prefix]="Add prefix"
  [method_suffix]="Add suffix"
  [method_replace]="Find and replace (text or regex)"
  [method_case]="Change case"
  [method_date]="Insert date"
  [method_clean]="Clean name (spaces and special characters)"
  [method_type]="Automatic template by file type"
  [method_template]="Use saved custom template"
  [method_new_template]="Create and apply new template"
  [method_pattern]="Apply one-off pattern (do not save)"
  [preview_queue]="View queued changes"
  [undo_step]="Undo last queued step"
  [apply_all]="Apply all changes"
  [back]="Back"
  [discard_pending]="There are %s unapplied step(s). Discard them and go back? (y/n) [n]: "
  [template_hint]="Placeholders: {name} {ext} {n} {date} {parent} {filedate} {filetime}\\n     {date} is today; {filedate}/{filetime} are each file's own date and time (EXIF for photos)\\n     {ext} does not include the dot · if the pattern does not use {ext}, the original extension is added automatically at the end"
  [pattern_n_hint]="This pattern uses {n}. Choose its starting number; subsequent files continue from there."
  [pattern_n_start]="Starting number for {n} [1]: "
  [pattern_n_digits]="Leading zeros for {n} (e.g. with %s, «%s» is written as «%s»). Empty = no padding."
  [pattern_n_digits_prompt]="Padding digits for {n} [no padding]: "
  [ambiguous_pattern]="This pattern does not use {name}, {n}, {date}, {parent}, {filedate}, or {filetime}. All files would initially resolve to the same name, so they will be numbered automatically."
  [template_name]="Template name: "
  [template_default_name]="Template_%s"
  [base_text]="Base text (e.g. Holidays): "
  [pattern_prompt]="Pattern (e.g. {date}_{name}_{n}): "
  [empty_pattern]="Empty pattern, cancelled."
  [template_saved]="Template «%s» saved."
  [no_templates]="No saved templates."
  [load_templates_prompt]="Load templates from a saved file? (y/n) [n]: "
  [import_not_text]="The file does not look like text or is too large: it is not a templates file."
  [select_template]="Select a template: "
  [applying_template]="Applying «%s»..."
  [delete_template_number]="Template number to delete: "
  [delete_template_confirm]="Delete «%s»? (y/n) [n]: "
  [template_deleted]="Template «%s» deleted."
  [templates_changed]="The template list changed in the meantime; nothing was deleted."
  [export_default]="templates_renombrador.txt"
  [export_title]="Export templates"
  [import_title]="Import templates"
  [no_templates_export]="There are no templates to export."
  [exported]="Templates exported to '%s'."
  [export_failed]="Could not export."
  [file_not_found]="The file does not exist."
  [file_unreadable]="The file cannot be read (no read permission)."
  [imported]="%s template(s) imported (%s duplicate(s) skipped, %s invalid line(s))."
  [import_none]="No templates imported: the file has no valid lines in the «Name|Pattern» format (%s invalid line(s))."
  [templates_title]="Custom templates"
  [templates_subtitle]="Create, use, or delete your rename patterns"
  [templates_list]="List templates"
  [templates_create]="Create new template"
  [templates_delete]="Delete template"
  [templates_export]="Export templates to file"
  [templates_import]="Import templates from file"
  [received]="%s item(s) received from Nemo"
  [ready]="Ready to rename."
  [main_subtitle]="Batch file renaming"
  [main_folder]="Rename an entire folder"
  [main_files]="Rename selected files"
  [main_templates]="Manage custom templates"
  [main_undo]="Undo rename (history)"
  [main_nemo_add]="Integrate with Nemo (right-click)"
  [main_nemo_remove]="Remove Nemo integration"
  [main_exit]="Exit"
  [option_prompt]="➤ Option: "
  [choice_default]="Option [1]: "
  [position_prompt]="Position [2]: "
  [switch_to_en]="Switch to English"
  [switch_to_es]="Switch to Spanish"
  [language_changed]="Language changed to English."
  [language_save_error]="Could not save the language: it will revert to the default on next launch."
  [goodbye]="See you soon!"
  [step_numbering]="Numbering"
  [step_prefix]="Prefix"
  [step_suffix]="Suffix"
  [step_regex]="Regex"
  [step_replace]="Find/replace"
  [step_case]="Uppercase/lowercase"
  [step_date_current]="Insert date (current)"
  [step_date_modified]="Insert date (modification time)"
  [step_date_exif]="Insert date (EXIF)"
  [step_clean]="Clean name"
  [step_type]="File type"
  [step_template]="Template"
  [cli_need_value]="Option '%s' requires a value."
  [cli_unknown_arg]="Unknown argument: '%s' (use --help to see the options)"
  [cli_digits_invalid]="Invalid --digitos value: '%s'"
  [cli_both_source]="Use --carpeta or --archivo, not both at the same time."
  [cli_folder_missing]="Folder does not exist: '%s'"
  [cli_unsafe_source]="This path cannot be processed safely: '%s'."
  [cli_start_invalid]="Invalid --inicio value: '%s'"
  [cli_item_missing]="Item does not exist: '%s'"
  [cli_no_source]="Missing source: use --carpeta PATH or --archivo PATH (repeatable)."
  [cli_none]="No items were found to rename."
  [cli_large]="%s items were found; this is a very large batch."
  [cli_found]="%s item(s) found."
  [cli_numbering_need_base]="The 'numeracion' method requires --base TEXT (or --mantener-nombre)."
  [cli_order_invalid]="Invalid --orden value: '%s' (use: actual, fecha, exif, tamano)"
  [cli_replace_need_search]="The 'buscar-reemplazar' method requires --buscar TEXT."
  [cli_regex_invalid]="Invalid regular expression: %s"
  [cli_case_invalid]="Invalid --caso value: '%s' (use: minusculas, mayusculas, capitalizar, frase)"
  [cli_date_source_invalid]="Invalid --fecha-origen value: '%s' (use: actual, modificacion, exif)"
  [cli_date_pos_invalid]="Invalid --fecha-pos value: '%s' (use: inicio, final)"
  [cli_spaces_invalid]="Invalid --espacios value: '%s' (use: guion_bajo, guion, eliminar)"
  [cli_template_need]="The 'plantilla' method requires --plantilla NAME."
  [cli_template_missing]="The template «%s» does not exist."
  [cli_pattern_need]="The 'patron' method requires --patron 'TEXT'."
  [cli_method_need]="Missing --metodo (use --help to see the list of methods)."
  [cli_method_unknown]="Unknown method: '%s' (use --help to see the list of methods)."
  [cli_lang_invalid]="Invalid --lang value: '%s' (use: es, en)"
  [cli_mode_invalid]="Invalid --modo value: '%s' (use: mover, copiar)"
  [cli_conflict_invalid]="Invalid --conflicto value: '%s' (use: sufijo, sobrescribir, omitir)"
  [internal_error]="Internal error: name lists do not match."
  [storage_error]="Could not initialize the configuration storage."
  [history_write_error]="Could not save the history safely."
  [history_changed]="The item changed after the batch was applied; it was not reverted."
  [history_legacy]="This old history cannot be safely undone because it has no state verification."
  [rollback_error]="The batch could not be fully restored after the history error."
  [backup_kept]="The overwritten original could not be put back under its name; it was kept as '%s'."
  [restored_as]="Its original name was already taken: the item is kept as '%s'."
  [orphans_kept]="%s item(s) left by an interrupted run in '%s' (.renombrador_tmp_*, .renombrador_undo_tmp_*, .renombrador_backup_*). They may be your files: they are not deleted; check them and rename them by hand."
  [interrupted]="Interrupted. The batch was left in a consistent state; stopping now."
  [invalid_option]="Invalid option."
  [numbering_order_mtime_label]=", by modification date"
  [numbering_order_exif_label]=", by EXIF date"
  [numbering_order_size_label]=", by size"
)

t() {
  local key="$1" text
  shift
  if [[ "$APP_LANG" == "en" ]]; then
    text="${TXT_EN[$key]}"
  else
    text="${TXT_ES[$key]}"
  fi
  if (( $# )); then
    printf "$text" "$@"
  else
    printf '%s' "$text"
  fi
}

t_lang() {
  local lang="$1" key="$2" text
  shift 2
  if [[ "$lang" == "en" ]]; then
    text="${TXT_EN[$key]}"
  else
    text="${TXT_ES[$key]}"
  fi
  if (( $# )); then
    printf "$text" "$@"
  else
    printf '%s' "$text"
  fi
}

crear_tmp_mismo_dir() {
  local destino="$1" dir="${1%/*}" nombre="${1##*/}" tmp
  [[ "$dir" == "$destino" ]] && dir='.'
  # Bound the embedded name so ".<nombre>.tmp.XXXXXX" fits in one filename
  # component (255 bytes) and mktemp does not fail.
  tmp=$(mktemp -- "$dir/.${nombre:0:200}.tmp.XXXXXX" 2>/dev/null) && { printf '%s' "$tmp"; return 0; }
  mktemp -- "$dir/.renombrador_tmp.XXXXXX"
}

sincronizar_temporal() {
  local ruta="$1"
  [[ -L "$ruta" ]] && return 0
  if [[ -d "$ruta" ]]; then
    find "$ruta" -type f -exec sync -- {} + 2>/dev/null || return 1
    # -depth: children first, so every entry is persisted before the mv -T.
    find "$ruta" -depth -type d -exec sync -- {} + 2>/dev/null
    return 0
  fi
  [[ -f "$ruta" ]] || return 0
  sync -- "$ruta" 2>/dev/null
}

sincronizar_directorio() {
  sync -- "$1" >/dev/null 2>&1
}

escritura_atomica() {
  local destino="$1" tmp modo dir
  if [[ -e "$destino" || -L "$destino" ]] && [[ ! -f "$destino" || -L "$destino" ]]; then
    return 1
  fi
  dir="${destino%/*}"
  [[ "$dir" == "$destino" ]] && dir='.'
  tmp=$(crear_tmp_mismo_dir "$destino") || return 1
  if [[ -f "$destino" ]]; then
    modo=$(stat -c '%a' -- "$destino") || { rm -f -- "$tmp"; return 1; }
    chmod "$modo" -- "$tmp" || { rm -f -- "$tmp"; return 1; }
  fi
  if ! cat > "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  if ! sincronizar_temporal "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  if ! mv -fT -- "$tmp" "$destino"; then
    rm -f -- "$tmp"
    return 1
  fi
  sincronizar_directorio "$dir" || true
}

# $3 (optional): mode for a NEW destination; an existing one keeps its own.
copia_atomica() {
  local origen="$1" destino="$2" modo_nuevo="${3:-}" tmp modo dir
  if [[ -e "$destino" || -L "$destino" ]] && [[ ! -f "$destino" || -L "$destino" ]]; then
    return 1
  fi
  dir="${destino%/*}"
  [[ "$dir" == "$destino" ]] && dir='.'
  tmp=$(crear_tmp_mismo_dir "$destino") || return 1
  if ! cp -p -- "$origen" "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  if [[ -f "$destino" ]]; then
    modo=$(stat -c '%a' -- "$destino") || { rm -f -- "$tmp"; return 1; }
    chmod "$modo" -- "$tmp" || { rm -f -- "$tmp"; return 1; }
  elif [[ -n "$modo_nuevo" ]]; then
    chmod "$modo_nuevo" -- "$tmp" || { rm -f -- "$tmp"; return 1; }
  fi
  if [[ "$destino" == "$APP_SCRIPT" ]]; then
    chmod +x -- "$tmp" || { rm -f -- "$tmp"; return 1; }
  fi
  if ! sincronizar_temporal "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  if ! mv -fT -- "$tmp" "$destino"; then
    rm -f -- "$tmp"
    return 1
  fi
  sincronizar_directorio "$dir" || true
}

copia_item_atomica() {
  local origen="$1" destino="$2" out_var="${3:-}" dir stage tmp alterno
  [[ -e "$destino" || -L "$destino" ]] && return 1
  dir="${destino%/*}"
  [[ "$dir" == "$destino" ]] && dir='.'
  stage=$(mktemp -d -- "$dir/.renombrador_stage.$$.XXXXXX") || return 1
  tmp="$stage/item"
  if ! cp -a -- "$origen" "$tmp"; then
    rm -rf -- "$stage"
    return 1
  fi
  if ! sincronizar_temporal "$tmp"; then
    rm -rf -- "$stage"
    return 1
  fi
  if ! mv -nT -- "$tmp" "$destino"; then
    alterno=$(sustituir_caracteres_incompatibles "$destino")
    if [[ "$alterno" == "$destino" ]] || ! mv -nT -- "$tmp" "$alterno"; then
      rm -rf -- "$stage"
      return 1
    fi
    destino="$alterno"
  fi
  if [[ -e "$tmp" || -L "$tmp" ]]; then
    rm -rf -- "$stage"
    return 1
  fi
  rmdir -- "$stage" 2>/dev/null || { rm -rf -- "$stage"; return 1; }
  sincronizar_directorio "$dir" || true
  [[ -n "$out_var" ]] && printf -v "$out_var" '%s' "$destino"
  return 0
}

# ---- Signal-safe batches ----
# Move mode is two-phase (temp name, then final), so swaps A->B + B->A never
# collide; history is written after both phases. INT/TERM/HUP between phases
# would strand items under .renombrador_tmp_*, so iniciar_seccion_critica
# defers them until the batch is consistent. Copies are atomic per item: loops
# just poll _LOTE_SENAL and stop early.
_LOTE_SENAL=""
_marcar_senal_lote() { _LOTE_SENAL="$1"; }
iniciar_seccion_critica() {
  _LOTE_SENAL=""
  trap '_marcar_senal_lote INT' INT
  trap '_marcar_senal_lote TERM' TERM
  trap '_marcar_senal_lote HUP' HUP
}
finalizar_seccion_critica() { trap - INT TERM HUP; }
salir_por_senal() {
  local codigo=130
  case "$1" in TERM) codigo=143 ;; HUP) codigo=129 ;; esac
  echo -e "${C_WARN}${I_WARN} $(t interrupted)${C_RESET}" >&2
  exit "$codigo"
}
# Common exit for every critical section: stop deferring, honor pending signal.
finalizar_seccion_critica_o_salir() {
  finalizar_seccion_critica
  [[ -n "$_LOTE_SENAL" ]] && salir_por_senal "$_LOTE_SENAL"
}

# Deletes leftover ".renombrador_stage.*" copies (original still exists).
# tmp/undo_tmp/backup entries from a crash may be the ONLY copy of an item:
# reported, never deleted. Entries of another live PID are skipped.
barrer_huerfanos() {
  local dir ruta nombre pid restos
  for dir in "$@"; do
    [[ -d "$dir" ]] || continue
    restos=0
    while IFS= read -r -d '' ruta; do
      nombre="${ruta##*/}"
      if [[ "$nombre" =~ ^\.renombrador_(undo_tmp_|tmp_|backup_|stage\.)([0-9]+)[_.] ]]; then
        pid="${BASH_REMATCH[2]}"
        [[ "$pid" != "$$" ]] && kill -0 "$pid" 2>/dev/null && continue
      fi
      if [[ "$nombre" == .renombrador_stage.* ]]; then rm -rf -- "$ruta"; else ((restos++)); fi
    done < <(find "$dir" -maxdepth 1 \( -name '.renombrador_tmp_*' -o -name '.renombrador_undo_tmp_*' \
      -o -name '.renombrador_stage.*' -o -name '.renombrador_backup_*' \) -print0 2>/dev/null)
    if (( restos )); then
      printf '%s%s %s%s\n' "$C_WARN" "$I_WARN" "$(t orphans_kept "$restos" "$(sanear_salida "$dir")")" "$C_RESET" >&2
    fi
  done
}

# Above this size a file is fingerprinted by size+mtime instead of by content.
HUELLA_MAX_BYTES=$((8 * 1024 * 1024))
_HUELLA_TAR=(--format=posix --numeric-owner --mtime=1970-01-01 --atime-preserve=system '--pax-option=delete=atime,delete=ctime')

# Fingerprint of a path (whole tree for a directory), independent of its own name
# and of directory mtimes. Files above HUELLA_MAX_BYTES contribute size+mtime
# instead of their content, so big videos are not re-read.
huella_ruta() {
  local ruta="$1" raiz base expr tam solo_meta=0 hash
  [[ -e "$ruta" || -L "$ruta" ]] || return 1
  [[ "$ruta" != "/" ]] || return 1
  if [[ -d "$ruta" && ! -L "$ruta" ]]; then
    raiz="$ruta"; base='.'; expr='s#^\./#ROOT/#'
  else
    raiz="${ruta%/*}"; base="./${ruta##*/}"; expr='s#^\./[^/]*$#ROOT#'
    [[ "$raiz" == "$ruta" ]] && raiz='.'
    raiz="${raiz:-/}"
    if [[ -f "$ruta" && ! -L "$ruta" ]]; then
      tam=$(stat -c %s -- "$ruta") || return 1
      (( tam > HUELLA_MAX_BYTES )) && solo_meta=1
    fi
  fi
  hash=$( (
    set -o pipefail; export LC_ALL=C
    cd -- "$raiz" 2>/dev/null || exit 1
    {
      (( solo_meta )) || find "$base" ! \( -type f -size "+${HUELLA_MAX_BYTES}c" \) -print0 2>/dev/null | sort -z |
        tar --null --no-recursion "${_HUELLA_TAR[@]}" --transform="$expr" -cf - -T - 2>/dev/null || exit 1
      find "$base" -type f -size "+${HUELLA_MAX_BYTES}c" -printf '%P %m %U %G %s %T@\0' 2>/dev/null | sort -z || exit 1
    } | sha256sum | awk '{print $1}'
  ) ) || return 1
  printf '%s\n' "$hash"
}

# Full-content fingerprint (the only kind older history files contain).
huella_completa() {
  local ruta="$1" padre base hash
  [[ -e "$ruta" || -L "$ruta" ]] || return 1
  [[ "$ruta" != "/" ]] || return 1
  if [[ -d "$ruta" && ! -L "$ruta" ]]; then
    hash=$( ( set -o pipefail; LC_ALL=C tar --sort=name "${_HUELLA_TAR[@]}" --transform='s#^\./#ROOT/#' -C "$ruta" -cf - -- . 2>/dev/null | sha256sum | awk '{print $1}' ) ) || return 1
  else
    padre="${ruta%/*}"; base="${ruta##*/}"
    [[ "$padre" == "$ruta" ]] && padre='.'
    hash=$( ( set -o pipefail; LC_ALL=C tar --sort=name "${_HUELLA_TAR[@]}" --transform='s#^\./[^/]*$#ROOT#' -C "$padre" -cf - -- "./$base" 2>/dev/null | sha256sum | awk '{print $1}' ) ) || return 1
  fi
  printf '%s\n' "$hash"
}

# True when $1 still matches fingerprint $2 (current kind, or the full-content kind).
huella_coincide() {
  [[ "$(huella_ruta "$1")" == "$2" || "$(huella_completa "$1")" == "$2" ]]
}

# Removes scratch files of atomic writes (".<name>.tmp.XXXXXX", or the long-name
# fallback ".renombrador_tmp.XXXXXX") that a killed writer left in $1. They carry
# no PID, so only files older than an hour go: a live writer holds one for
# milliseconds. $2 narrows the name pattern (use it in shared directories).
barrer_temporales() {
  [[ -d "$1" && ! -L "$1" ]] || return 0
  find "$1" -maxdepth 1 -type f \( -name "${2:-.*.tmp.??????}" -o -name '.renombrador_tmp.??????' \) \
    -mmin +60 -delete 2>/dev/null || true
}

inicializar_almacenamiento() {
  if [[ -L "$CONFIG_DIR" || -L "$HISTORY_DIR" || -L "$TEMPLATES_FILE" || -L "$PLANTILLAS_LOCK_FILE" ]]; then
    echo -e "${C_ERR}${I_ERR} $(t storage_error)${C_RESET}" >&2
    return 1
  fi
  # chmod also on pre-existing dirs: "mkdir -p -m" only sets the mode on new ones.
  if ! mkdir -p "$CONFIG_DIR" "$HISTORY_DIR" || ! chmod 700 "$CONFIG_DIR" "$HISTORY_DIR"; then
    echo -e "${C_ERR}${I_ERR} $(t storage_error)${C_RESET}" >&2
    return 1
  fi
  if [[ -L "$TEMPLATES_FILE" || -L "$PLANTILLAS_LOCK_FILE" ]]; then
    echo -e "${C_ERR}${I_ERR} $(t storage_error)${C_RESET}" >&2
    return 1
  fi
  if [[ -e "$TEMPLATES_FILE" && ! -f "$TEMPLATES_FILE" ]]; then
    echo -e "${C_ERR}${I_ERR} $(t storage_error)${C_RESET}" >&2
    return 1
  fi
  if [[ -e "$PLANTILLAS_LOCK_FILE" && ! -f "$PLANTILLAS_LOCK_FILE" ]]; then
    echo -e "${C_ERR}${I_ERR} $(t storage_error)${C_RESET}" >&2
    return 1
  fi
  if [[ ! -e "$TEMPLATES_FILE" ]] && ! printf '' | escritura_atomica "$TEMPLATES_FILE"; then
    echo -e "${C_ERR}${I_ERR} $(t storage_error)${C_RESET}" >&2
    return 1
  fi
  if [[ ! -e "$PLANTILLAS_LOCK_FILE" ]] && ! printf '' | escritura_atomica "$PLANTILLAS_LOCK_FILE"; then
    echo -e "${C_ERR}${I_ERR} $(t storage_error)${C_RESET}" >&2
    return 1
  fi
  barrer_temporales "$CONFIG_DIR"
  barrer_temporales "$HISTORY_DIR"
}

# Options that take a value (shared by the argument scanners).
OPCIONES_CON_VALOR=" --carpeta --archivo --filtro --metodo --base --inicio --digitos --orden --prefijo --sufijo --buscar --reemplazar --caso --fecha-origen --fecha-pos --espacios --plantilla --patron --modo --conflicto --lang "

# True when the run only prints help/version (only "--*" invocations are CLI
# mode): no config dir is created, so a read-only HOME does not break --help.
solo_ayuda_o_version() {
  case "${1:-}" in
    --ayuda|--help|-h|--version|-v) return 0 ;;
    --*) ;;
    *) return 1 ;;
  esac
  while (( $# )); do
    case "$1" in --ayuda|--help|-h|--version|-v) return 0 ;; esac
    if [[ "$OPCIONES_CON_VALOR" == *" $1 "* ]]; then shift 2 2>/dev/null || return 1; else shift; fi
  done
  return 1
}

# Sourced (tests) or a real run: storage is always prepared.
if [[ "${BASH_SOURCE[0]}" != "${0}" ]] || ! solo_ayuda_o_version "$@"; then
  inicializar_almacenamiento || exit 1
fi

codificar_texto() { printf '%s.' "$1" | base64 | tr -d '\n'; }
decodificar_texto_en() {
  local __var="$1" token="$2" valor
  printf '%s' "$token" | base64 -d >/dev/null 2>&1 || return 1
  IFS= read -r -d '' valor < <(printf '%s' "$token" | base64 -d 2>/dev/null) || true
  [[ "$valor" == *. ]] || return 1
  valor="${valor%.}"
  printf -v "$__var" '%s' "$valor"
}

# "sÍ" is listed too: outside UTF-8 locales ${r,,} leaves "Í" as it is.
respuesta_si() { local r=${1-}; case "${r,,}" in s|si|sí|sÍ|y|yes) return 0 ;; *) return 1 ;; esac; }
normalizar_sn() { respuesta_si "$1" && printf 's' || printf 'n'; }

# Replaces C0/C1 controls (incl. DEL and 8-bit CSI \xC2\x9B) with '?' in names
# read from disk or imported files, so they cannot inject escape sequences.
sanear_salida() {
  local LC_ALL=C s="$1"
  s=${s//[$'\001'-$'\037\177']/?}
  printf '%s' "${s//$'\xc2'[$'\x80'-$'\x9f']/?}"
}

# Strips leading zeros so a digit string is never read as octal ("010" ->
# "10"). Input must match ^[0-9]+$.
normalizar_decimal() {
  [[ "$1" =~ ^0*([1-9][0-9]*|0)$ ]] && printf '%s' "${BASH_REMATCH[1]}"
}
# True if decimal string $1 <= $2 (length first, then lexicographic), so long
# input never reaches integer arithmetic.
en_rango_decimal() {
  local v="$1" max="$2"
  (( ${#v} < ${#max} )) && return 0
  (( ${#v} > ${#max} )) && return 1
  [[ "$v" > "$max" ]] && return 1
  return 0
}
# Menu number 1..$2 typed by the user, printed without leading zeros; fails
# otherwise. No arithmetic on the raw input.
numero_en_rango() {
  local v
  [[ "$1" =~ ^[0-9]+$ ]] || return 1
  v=$(normalizar_decimal "$1")
  [[ "$v" != 0 ]] && en_rango_decimal "$v" "$2" && printf '%s' "$v"
}

etiqueta_cambio_idioma() { [[ "$APP_LANG" == "es" ]] && t switch_to_en || t switch_to_es; }

guardar_idioma() { printf '%s\n' "$APP_LANG" | escritura_atomica "$IDIOMA_FILE"; }

aviso_idioma_no_guardado() {
  echo -e "${C_WARN}${I_WARN} $(t language_save_error)${C_RESET}" >&2
}

cambiar_idioma() {
  [[ "$APP_LANG" == "es" ]] && APP_LANG="en" || APP_LANG="es"
  actualizar_icono_aviso
  echo -e "${C_OK}${I_OK} $(t language_changed)${C_RESET}"
  guardar_idioma || { aviso_idioma_no_guardado; pausa; }
  if [[ -f "$NEMO_ACTION" ]] && ! refrescar_accion_nemo; then pausa; fi
}

establecer_idioma() {
  case "$1" in
    es|en) APP_LANG="$1"; actualizar_icono_aviso ;;
    *) printf '%s%s %s%s\n' "$C_ERR" "$I_ERR" "$(t cli_lang_invalid "$(sanear_salida "$1")")" "$C_RESET" >&2; return 1 ;;
  esac
}

FILES=()
NUEVOS=()
HISTORIA_RUTAS=()
HISTORIA_ORIGENES=()
BACKUP_PATHS=()
BACKUP_TARGETS=()
SELECTOR=""
NOMBRES_COLA=()
PASOS_COLA=()
HISTORIAL_COLA=()
EXIFTOOL_DISPONIBLE=""
IDENTIFY_DISPONIBLE=""
EXIF_CHEQUEADO=""
EXIF_LOTE=200
declare -A EXIF_CACHE=()
CLI_MODE=0
CLI_MODO=""
CLI_CONFLICTO=""
CLI_DRY_RUN=0
CLI_SIN_CONFIRMAR=0

pausa() { (( CLI_MODE )) && return; echo; read -rp "${C_DIM}$(t pause)${C_RESET}" _; }

# Never write control sequences into redirected output.
limpiar_pantalla() { [[ -t 1 ]] && clear 2>/dev/null; return 0; }

repetir_char() { local s=""; local i; for ((i=0;i<$2;i++)); do s+="$1"; done; printf '%s' "$s"; }

titulo() {
  local texto="$1" sub="${2:-}" ancho borde
  ancho=${#texto}
  (( ${#sub} > ancho )) && ancho=${#sub}
  borde=$(repetir_char "─" $(( ancho + 4 )))
  echo -e "${C_BORDER}╭${borde}╮${C_RESET}"
  printf "${C_BORDER}│${C_RESET}  ${C_TITLE}%-${ancho}s${C_RESET}  ${C_BORDER}│${C_RESET}\n" "$texto"
  [[ -n "$sub" ]] && printf "${C_BORDER}│${C_RESET}  ${C_DIM}%-${ancho}s${C_RESET}  ${C_BORDER}│${C_RESET}\n" "$sub"
  echo -e "${C_BORDER}╰${borde}╯${C_RESET}"
}

opt() {
  local icono="$2"
  (( SIN_EMOJI )) && icono="•"
  echo -e "  ${C_ACCENT}$1)${C_RESET} ${icono} $3"
}

barra_progreso() {
  local actual="$1" total="$2" ancho=24 llenos vacios
  llenos=$(( actual * ancho / total )); vacios=$(( ancho - llenos ))
  printf "\r${C_ACCENT}[${C_OK}%s${C_DIM}%s${C_ACCENT}]${C_RESET} ${C_DIM}%3d%%  %d/%d${C_RESET}" \
    "$(repetir_char '█' "$llenos")" "$(repetir_char '░' "$vacios")" $(( actual * 100 / total )) "$actual" "$total"
}

# Application icon: 64x64 indexed PNG (miniature of assets/icons/renombrador.png),
# embedded so the script needs no file from the repository.
ICONO_B64="iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAMAAACdt4HsAAAB/lBMVEXw3ZEeLFcaLF8qQXs6T4orRYKgajnjii7DnWEKCiocID0gLWMAAP8Af38oQX9DLS5fQDNCWJCKYUS1oX6LipuftfK+0f/CvsLp498OFDUOGkcWI1McNHIKDCr19/sWK2Xl6fQlN28mKEwAAADO1/A1NFG3xuzb4vUhPYImQ4qruuVEPFYrJDqrtdi7w9gbOoZPV3bCzepBPmKRl64hHTb/pyaapsj/lxn/tzO1mm/+5402QnFHS2q1h0/Dlk9YY4jAeS3/2msAAFWyekP/ykrChjnCo212hK1IR1z/wzwNCyULFDRpZXNwe6OYoby4klugq874ihf/0lpyeI+1o4P/4XoPDScOCyUNCyQNDCYAAH8iOnWqqLXW1NoQGjsMFTcMFDYMFjkRHEIOGkEZJU4WJFEAVVUkO3YxSYNQOTViQjFiXWxmbYqQncTEjkHFytn///8PDCUTGDENFjgSHkQQHEMXJUcaKlMZKFMXJFEcM2olPHQ7VI9VVVWTg2+bruYAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAADL5JgHAAAAgHRSTlP/H7hjGmT///8Y//8BApj//xf//////////v7+/v7//v/+/wD///////////////////////////////////////8D/////////9PS/////////////yVJj64Czf//LX2dsnzRK9ADnDP/////////AXwaSFCdGkd7m9V7IgP//zinRn8AAASrSURBVHjaldfpW9NIAAbwAV3d+75mpkOT5oKSYEsrBVqXFdwFoXaLLPcpKsi14K3rrv7rzp2zFN4PefqEvL/MTNOEAIvlyz26+e+TK/u96+umaeZ48iI4lsePe9++ed1DD5/kTQuwzR5rr6uiTqYgnTc9kmDA/9Z3XyfL5xKI5W0PFwDrP1F1k6c7wQX0mgnA+kr3zTApQRoFmlB4ZK1ZYG3tatjvl4kPQxO07TgON4RAFwLsWfthfUCGGynCNBulo2bzqDSjhJfWJLCeyPOHdUn0JxaDngKAcRoAHAFAOglgvcvqayMyEPr5/RgVwNh7RwwBol0LnK1r4EY8cuxRwDT/Hh//c5D1BfDwDFxVMxjoPxlKJRgK6nlT9+sNBjQ0AOEjcEUAdLgDfVkxApML4uutM2A4ArwA70LAyAJsWwjyAkkCu2BfATc6AK7LBTWCxcUY8AD0dgfctpmXA6j/kAL+zXcFiu6IEobHFm8zoKCAOQrkJVDPBoosShgeu50EcgIwQ+C0otPq6yuz/oefToSQAqACciFQIkiFLHBgZGTkQ8X5QgKfxoG8vNj6c6YEJnB4T0MLhk2zubn5awkrYFACMAaYIZCP/ILQAr2WeBoK+C0OYH25h4AZF2LA/ftJQAumlwZyeWyKvjGD6c3k8kAO17sCShCAEV0Dto4J4M4dBcDOQGQEJprouwhAhbwGUOROjMxT0d8sYHpHHcwEsAYMBpy2RnRabU8OYAMWokAhCeQFwJK4ofDYRlMAfylA9gWAY0AknufxjW388jkWwN27HQB627ZTACuzvm3MQPZQ6gjgLMDzVN0zmgRfAvCioT8lwy4RrIHRfzgAzwHE4sm27dmVAsEaGBUATgCYA/zsxlCl1WpV2rxN+xVMINbArRSAUARgZzVKBBKaiiEBgnEM+IMBagkIBaSAc7YnAL4DObZMA2khBGAUQALIc8CWACbTchIbKaCQBdDQ9WLfmQQQLvN+2ZY7sgAiAKQBOwQwOfbKHAgwUoAjAf8iAEKBXaZx7WOoh3Br9CYDYAJAkSFrAJOS7TKgHBT0EG7dZICfAlAIqCmz+/4IezK6rr1A2CzSAOkEqOdKXQDukMMPkYCTBdASduWiQ6yfTBUuFMs/QnaIAH7PBpAA6JLRX47aBR0xguLQDBMU4Pu6nwD4hCPPRkSmXfZwDdyKBKY4UI0ADyNAOQVAzJ/uQeA2SCYwSwGoAbHkjQiAyLEbMKC4QQvVOEA40BsCRSHEAAjbrE+HcEQQ9J2pWi0GrIKX9JhzAERKbsCz4cNqFrDLPoZAsZgAIDwptmm/HTSJBnSfPAUvQkAM4Oc4QK8m/kXQifgwDSyDV2JB2bkmplnuYRg9Pz1wYvoeSxNK4EBMgQNL4GxOCWIPTbStj6SJrwHfNUv/3d+GF47//dT1Wm3+2jVfqSsU6LkEcL02T1Ob18CSBSatnQsDVf/g28PDw4NvqhJY4a99r84t6QUQRNX3q3oFyGcMWLO2spu6Gzci7LJ48Zy0nnc4azqxvy6rV99J69lO924yK8/Cl2/6Bru1PXeZ/uzKkhV5excv4lvPt3cezM11ac6urj5dVm2ajysmOXZUseIkAAAAAElFTkSuQmCC"

instalar_icono() {
  mkdir -p "${APP_ICON%/*}" || return 1
  base64 -d <<<"$ICONO_B64" | escritura_atomica "$APP_ICON" || return 1
  # GTK (Nemo) only notices a new icon, and drops a stale icon-theme.cache, when the theme root changes.
  touch -- "$APP_ICON_THEME" 2>/dev/null
  return 0
}

instalar_nemo() {
  mkdir -p "$NEMO_DIR" "$APP_DIR" || return 1
  barrer_temporales "$APP_DIR"
  barrer_temporales "$NEMO_DIR" ".${NEMO_ACTION##*/}.tmp.??????"
  barrer_temporales "${APP_ICON%/*}" ".${APP_ICON##*/}.tmp.??????"
  if ! instalar_icono; then
    echo -e "${C_ERR}${I_ERR} $(t icon_install_error)${C_RESET}" >&2
    return 1
  fi
  local origen; origen="$(readlink -f "${BASH_SOURCE[0]}")"
  if [[ "$origen" != "$APP_SCRIPT" ]]; then
    copia_atomica "$origen" "$APP_SCRIPT" || return 1
  fi
  if ! escribir_accion_nemo true; then
    echo -e "${C_ERR}${I_ERR} $(t nemo_action_error)${C_RESET}" >&2
    return 1
  fi
  rm -f -- "$APP_DIR/renombrador.png" "$APP_DIR/icono.svg"  # icons of earlier versions (1.0.0: icono.svg)
  guardar_idioma || aviso_idioma_no_guardado
  echo -e "${C_OK}${I_OK} $(t nemo_integrated)${C_RESET} ${I_ARROW} $(t nemo_name)"
  echo -e "${C_DIM}$(t nemo_refresh)${C_RESET}"
}

# Written in the app language only (no Name[es]): Nemo would otherwise pick
# the desktop locale and ignore the language chosen in the app.
escribir_accion_nemo() {
  escritura_atomica "$NEMO_ACTION" <<EOF
[Nemo Action]
Active=$1
Name=$(t nemo_name)
Comment=$(t nemo_comment)
Exec=/bin/bash "$APP_SCRIPT" %F
Icon-Name=$APP_ICON_NAME
Selection=notnone
Extensions=any;
Terminal=true
EOF
}

refrescar_accion_nemo() {
  local activo=true
  nemo_activo || activo=false
  instalar_icono && escribir_accion_nemo "$activo" && return 0
  echo -e "${C_ERR}${I_ERR} $(t nemo_toggle_error)${C_RESET}" >&2
  return 1
}

desinstalar_nemo() {
  if ! rm -f -- "$NEMO_ACTION"; then
    echo -e "${C_ERR}${I_ERR} $(t nemo_remove_error)${C_RESET}" >&2
    return 1
  fi
  rm -f -- "$APP_ICON"
  echo -e "${C_OK}${I_OK} $(t nemo_removed)${C_RESET}"
  echo -e "${C_DIM}$(t nemo_reload_hint)${C_RESET}"
}

nemo_activo() {
  [[ -f "$NEMO_ACTION" ]] || return 1
  ! grep -Fqx 'Active=false' "$NEMO_ACTION"
}

establecer_estado_nemo() {
  local valor="$1" contenido
  if [[ ! -f "$NEMO_ACTION" ]]; then
    echo -e "${C_ERR}${I_ERR} $(t nemo_not_installed)${C_RESET}" >&2
    return 1
  fi
  if ! contenido=$(sed "s/^Active=.*/Active=$valor/" "$NEMO_ACTION"); then
    echo -e "${C_ERR}${I_ERR} $(t nemo_toggle_error)${C_RESET}" >&2
    return 1
  fi
  if ! printf '%s\n' "$contenido" | escritura_atomica "$NEMO_ACTION"; then
    echo -e "${C_ERR}${I_ERR} $(t nemo_toggle_error)${C_RESET}" >&2
    return 1
  fi
}

activar_nemo() {
  establecer_estado_nemo true || return 1
  echo -e "${C_OK}${I_OK} $(t nemo_activated)${C_RESET}"
  echo -e "${C_DIM}$(t nemo_reload_hint)${C_RESET}"
}

desactivar_nemo() {
  establecer_estado_nemo false || return 1
  echo -e "${C_OK}${I_OK} $(t nemo_deactivated)${C_RESET}"
  echo -e "${C_DIM}$(t nemo_reload_hint)${C_RESET}"
}

gestionar_nemo() {
  local estado op_nemo conf
  estado=$(t nemo_state_inactive)
  nemo_activo && estado=$(t nemo_state_active)
  read -rp "${C_PROMPT}$(t nemo_manage_prompt "$estado")${C_RESET}" op_nemo
  case "$op_nemo" in
    a|A) if nemo_activo; then desactivar_nemo; else activar_nemo; fi ;;
    q|Q)
      read -rp "${C_PROMPT}$(t nemo_remove_confirm)${C_RESET}" conf
      if respuesta_si "$conf"; then
        desinstalar_nemo
      else
        echo -e "${C_DIM}$(t cancelled)${C_RESET}"
      fi
      ;;
    "") : ;;
    *) echo -e "${C_WARN}${I_WARN} $(t invalid_option)${C_RESET}" ;;
  esac
}

comprobar_dependencias() {
  if command -v zenity &>/dev/null; then
    SELECTOR="zenity"; return
  elif command -v kdialog &>/dev/null; then
    SELECTOR="kdialog"; return
  fi
  echo -e "${C_WARN}${I_WARN} $(t selector_missing)${C_RESET}"
  read -rp "${C_PROMPT}$(t install_selector)${C_RESET}" r
  if ! respuesta_si "$r"; then
    echo -e "${C_ERR}${I_ERR} $(t selector_required)${C_RESET}"; exit 1
  fi
  if command -v apt &>/dev/null; then sudo apt update && sudo apt install -y zenity
  elif command -v dnf &>/dev/null; then sudo dnf install -y zenity
  elif command -v pacman &>/dev/null; then sudo pacman -S --noconfirm zenity
  elif command -v zypper &>/dev/null; then sudo zypper install -y zenity
  else
    echo -e "${C_ERR}${I_ERR} $(t unknown_package)${C_RESET}"; exit 1
  fi
  if command -v zenity &>/dev/null; then
    SELECTOR="zenity"
  else
    echo -e "${C_ERR}${I_ERR} $(t install_failed)${C_RESET}"; exit 1
  fi
}

# Ensure a directory component ("/") so "${ruta%/*}" never returns the path itself.
normalizar_ruta() {
  local r="$1" __var="${2:-}"
  if [[ "$r" != "/" ]]; then
    while [[ "$r" == */ ]]; do r="${r%/}"; done
  fi
  [[ "$r" == */* ]] || r="./$r"
  if [[ -n "$__var" ]]; then printf -v "$__var" '%s' "$r"; else printf '%s' "$r"; fi
}

separar_nombre_ext() {
  local nombre="$1"
  if [[ "$nombre" == .* && "$nombre" != *.*.* ]]; then
    SEPARAR_BASE="$nombre"
    SEPARAR_EXT=""
  elif [[ "$nombre" == *.* ]]; then
    SEPARAR_BASE="${nombre%.*}"
    SEPARAR_EXT="${nombre##*.}"
  else
    SEPARAR_BASE="$nombre"
    SEPARAR_EXT=""
  fi
}

# ---- Actual EXIF date (photos) ----

comprobar_herramientas_exif() {
  [[ -n "$EXIF_CHEQUEADO" ]] && return
  command -v exiftool &>/dev/null && EXIFTOOL_DISPONIBLE=1
  command -v identify &>/dev/null && IDENTIFY_DISPONIBLE=1
  EXIF_CHEQUEADO=1
}

# First "YYYY:MM:DD HH:MM:SS" among $2.. into $1 as "YYYY-MM-DD HH:MM:SS" (empty if none).
exif_normalizar() {
  local __var="$1" f; shift
  printf -v "$__var" ''
  for f in "$@"; do
    [[ "$f" =~ ^([0-9]{4}):([0-9]{2}):([0-9]{2})[\ T]([0-9]{2}:[0-9]{2}:[0-9]{2}) ]] || continue
    printf -v "$__var" '%s-%s-%s %s' "${BASH_REMATCH[@]:1:4}"; return
  done
}

# EXIF_CACHE key = path as exiftool prints it ("//" collapsed, "./" for bare names).
exif_clave() {
  local __var="$1" r="$2"
  while [[ "$r" == *//* ]]; do r="${r//\/\//\/}"; done
  [[ "$r" == */* ]] || r="./$r"
  printf -v "$__var" '%s' "$r"
}

# Original EXIF date/time as "YYYY-MM-DD HH:MM:SS" (empty when unavailable).
# Uses EXIF_CACHE (see precargar_exif) before spawning exiftool for one file.
fecha_exif_raw() {
  local archivo="$1" r='' k
  local -a f=()
  comprobar_herramientas_exif
  if [[ -n "$EXIFTOOL_DISPONIBLE" ]]; then
    exif_clave k "$archivo"
    if [[ -n "${EXIF_CACHE[$k]+x}" ]]; then
      r="${EXIF_CACHE[$k]}"
    else
      mapfile -t f < <(exiftool -DateTimeOriginal -CreateDate -s3 -- "$archivo" 2>/dev/null)
      exif_normalizar r "${f[@]}"
    fi
  fi
  if [[ -z "$r" && -n "$IDENTIFY_DISPONIBLE" ]]; then
    mapfile -t f < <(identify -format '%[EXIF:DateTimeOriginal]\n' -- "$archivo" 2>/dev/null)
    exif_normalizar r "${f[@]}"
  fi
  [[ -z "$r" ]] || printf '%s' "$r"
}

# One exiftool call for a batch of photos. The path is the last field so tabs in
# names survive; files exiftool skips stay uncached and fall back to one call each.
exif_leer_lote() {
  local d1 d2 ruta r k fmt=$'$DateTimeOriginal\t$CreateDate\t$Directory/$FileName'
  while IFS=$'\t' read -r d1 d2 ruta; do
    [[ -n "$ruta" ]] || continue
    exif_normalizar r "$d1" "$d2"
    exif_clave k "$ruta"
    EXIF_CACHE["$k"]="$r"
  done < <(exiftool -m -q -f -p "$fmt" -- "$@" 2>/dev/null)
}

# Fill EXIF_CACHE for the photos in FILES: one exiftool call per EXIF_LOTE files
# instead of one per file. Rebuilt on every call, so renames never leave stale dates.
precargar_exif() {
  local i ruta
  local -a lote=()
  EXIF_CACHE=()
  comprobar_herramientas_exif
  [[ -n "$EXIFTOOL_DISPONIBLE" ]] || return 0
  for i in "${!FILES[@]}"; do
    ruta="${FILES[$i]}"
    [[ "$ruta" != *$'\n'* && -f "$ruta" ]] || continue
    separar_nombre_ext "${ruta##*/}"
    [[ "$(detectar_tipo "$SEPARAR_EXT")" == "Foto" ]] || continue
    lote+=("$ruta")
    if (( ${#lote[@]} >= EXIF_LOTE )); then exif_leer_lote "${lote[@]}"; lote=(); fi
  done
  (( ${#lote[@]} == 0 )) || exif_leer_lote "${lote[@]}"
  return 0
}

# Photo date (YYYY-MM-DD) from EXIF; for non-photos, missing or invalid EXIF
# (e.g. "0000:00:00"), the modification date.
fecha_foto() {
  local archivo="$1" tipo="$2" raw out
  if [[ "$tipo" == "Foto" ]]; then
    raw=$(fecha_exif_raw "$archivo")
    if [[ -n "$raw" ]] && out=$(date -d "$raw" +%Y-%m-%d 2>/dev/null); then
      printf '%s' "$out"; return
    fi
  fi
  date -r "$archivo" +%Y-%m-%d 2>/dev/null
}

# Same as fecha_foto, but as epoch seconds for chronological sorting.
epoch_foto() {
  local archivo="$1" tipo="$2" raw out
  if [[ "$tipo" == "Foto" ]]; then
    raw=$(fecha_exif_raw "$archivo")
    if [[ -n "$raw" ]] && out=$(date -d "$raw" +%s 2>/dev/null); then
      printf '%s' "$out"; return
    fi
  fi
  date -r "$archivo" +%s 2>/dev/null
}

# Own date and time as "YYYY-MM-DD HH-MM-SS": EXIF for photos, else modification time.
sello_archivo() {
  local archivo="$1" raw
  separar_nombre_ext "${archivo##*/}"
  if [[ "$(detectar_tipo "$SEPARAR_EXT")" == "Foto" ]]; then
    raw=$(fecha_exif_raw "$archivo")
    if [[ -n "$raw" ]] && date -d "$raw" >/dev/null 2>&1; then
      printf '%s' "${raw//:/-}"; return
    fi
  fi
  date -r "$archivo" '+%Y-%m-%d %H-%M-%S' 2>/dev/null
}

# ---- File selection ----

# Both dialogs end their output with "\n", which is not part of the path.
seleccionar_carpeta() {
  SELECCION_CARPETA=''
  if [[ "$SELECTOR" == "zenity" ]]; then
    IFS= read -r -d '' SELECCION_CARPETA < <(zenity --file-selection --directory --title="$(t select_folder)" 2>/dev/null; printf '\0') || true
  else
    IFS= read -r -d '' SELECCION_CARPETA < <(kdialog --getexistingdirectory "$HOME" --title "$(t select_folder)" 2>/dev/null; printf '\0') || true
  fi
  SELECCION_CARPETA=${SELECCION_CARPETA%$'\n'}
}

seleccionar_archivos() {
  local sep=$'\x1f'
  SELECCION_ARCHIVOS=''
  if [[ "$SELECTOR" == "zenity" ]]; then
    IFS= read -r -d '' SELECCION_ARCHIVOS < <(zenity --file-selection --multiple --separator="$sep" --title="$(t select_files)" 2>/dev/null; printf '\0') || true
  else
    IFS= read -r -d '' SELECCION_ARCHIVOS < <(kdialog --getopenfilename "$HOME" --multiple --separate-output 2>/dev/null | paste -sd"$sep" -; printf '\0') || true
  fi
  SELECCION_ARCHIVOS=${SELECCION_ARCHIVOS%$'\n'}
}

construir_lista_desde_carpeta() {
  local carpeta="$1" recursivo="$2" filtro="$3" ocultos="$4" incluir_carpetas="${5:-n}" seguir_enlaces="${6:-n}"
  FILES=()
  local prof=(-maxdepth 1)
  [[ "$recursivo" == "s" ]] && prof=()
  local flags=()
  [[ "$seguir_enlaces" == "s" ]] && flags=(-L)
  # Always request type "l": without following links the symlink itself is kept;
  # with links followed this also covers broken links, which -L cannot resolve.
  local tipos="f,l"
  [[ "$incluir_carpetas" == "s" ]] && tipos+=",d"
  local relpath archivo ext real raiz_real
  realpath_en_var raiz_real "$carpeta" -e || return 1
  [[ "$raiz_real" != "/" ]] || return 1
  local -A vistos_real=()
  while IFS= read -r -d '' relpath; do
    relpath="${relpath#./}"
    if [[ "$ocultos" != "s" ]] && [[ "$relpath" == .* || "$relpath" == */.* ]]; then
      continue
    fi
    archivo="$carpeta/$relpath"
    if [[ "$seguir_enlaces" == "s" ]]; then
      # A symlink to a directory in the same tree would list its files twice: discard
      # duplicates by canonical path (broken links have none and stay).
      real=''
      realpath_en_var real "$archivo" -e || true
      if [[ -n "$real" ]]; then
        case "$real" in
          "$raiz_real"|"$raiz_real"/*) ;;
          *) continue ;;
        esac
        [[ -n "${vistos_real[$real]:-}" ]] && continue
        vistos_real[$real]=1
      fi
    fi
    if [[ -n "$filtro" && ! -d "$archivo" ]]; then
      separar_nombre_ext "${archivo##*/}"; ext="$SEPARAR_EXT"
      ext="${ext,,}"
      [[ ",${filtro,,}," == *",${ext},"* ]] && FILES+=("$archivo")
    else
      FILES+=("$archivo")
    fi
  done < <(cd "$carpeta" && find "${flags[@]}" . -mindepth 1 "${prof[@]}" -type "$tipos" -print0 | sort -z -V)
}

opcion_carpeta() {
  local carpeta recursivo filtro ocultos incluir_carpetas seguir_enlaces seguir
  seleccionar_carpeta
  carpeta="$SELECCION_CARPETA"
  [[ -z "$carpeta" ]] && { echo -e "${C_WARN}${I_WARN} $(t cancelled)${C_RESET}"; pausa; return; }
  read -rp "${C_PROMPT}$(t include_subdirs)${C_RESET}" recursivo; recursivo=$(normalizar_sn "$recursivo")
  read -rp "${C_PROMPT}$(t include_hidden)${C_RESET}" ocultos; ocultos=$(normalizar_sn "$ocultos")
  read -rp "${C_PROMPT}$(t include_folders)${C_RESET}" incluir_carpetas; incluir_carpetas=$(normalizar_sn "$incluir_carpetas")
  read -rp "${C_PROMPT}$(t follow_links)${C_RESET}" seguir_enlaces; seguir_enlaces=$(normalizar_sn "$seguir_enlaces")
  read -rp "${C_PROMPT}$(t filter_ext)${C_RESET}" filtro
  filtro="${filtro// /}"; filtro="${filtro//./}"
  filtro=$(sed -E 's/,+/,/g; s/^,//; s/,$//' <<< "$filtro")
  construir_lista_desde_carpeta "$carpeta" "$recursivo" "$filtro" "$ocultos" "$incluir_carpetas" "$seguir_enlaces"
  if [[ ${#FILES[@]} -eq 0 ]]; then
    echo -e "${C_WARN}${I_WARN} $(t none_found)${C_RESET}"; pausa; return
  fi
  echo -e "${C_OK}${I_OK} $(t found "${#FILES[@]}")${C_RESET}"
  if (( ${#FILES[@]} > 2000 )); then
    read -rp "${C_PROMPT}$(t large_batch)${C_RESET}" seguir
    respuesta_si "$seguir" || { echo -e "${C_WARN}${I_WARN} $(t cancelled)${C_RESET}"; pausa; return; }
  fi
  menu_metodos
}

opcion_archivos() {
  local seleccion
  seleccionar_archivos
  seleccion="$SELECCION_ARCHIVOS"
  [[ -z "$seleccion" ]] && { echo -e "${C_WARN}${I_WARN} $(t cancelled)${C_RESET}"; pausa; return; }
  IFS=$'\x1f' read -r -d '' -a FILES < <(printf '%s\0' "$seleccion")
  echo -e "${C_OK}${I_OK} $(t selected "${#FILES[@]}")${C_RESET}"
  menu_metodos
}

# ---- Chained transformation queue ----

guardar_snapshot_cola() {
  local i snapshot='' sep=''
  for i in "${!NOMBRES_COLA[@]}"; do
    snapshot+="$sep$(codificar_texto "${NOMBRES_COLA[$i]}")"
    sep=$'\t'
  done
  HISTORIAL_COLA+=("$snapshot")
}

registrar_paso() { PASOS_COLA+=("$1$LOG_SEP$2"); }

paso_texto() {
  local es en
  IFS="$LOG_SEP" read -r es en <<< "$1"
  [[ "$APP_LANG" == "en" ]] && printf '%s' "$en" || printf '%s' "$es"
}

deshacer_paso_cola() {
  local total=${#HISTORIAL_COLA[@]} idx token
  if (( total == 0 )); then
    echo -e "${C_WARN}${I_WARN} $(t no_undo_steps)${C_RESET}"; pausa; return
  fi
  idx=$(( total - 1 ))
  NOMBRES_COLA=()
  IFS=$'\t' read -ra _snapshot_parts <<< "${HISTORIAL_COLA[$idx]}"
  for token in "${_snapshot_parts[@]}"; do
    [[ -z "$token" ]] && NOMBRES_COLA+=("") && continue
    local _valor
    decodificar_texto_en _valor "$token" || return 1
    NOMBRES_COLA+=("$_valor")
  done
  unset "HISTORIAL_COLA[$idx]"; HISTORIAL_COLA=("${HISTORIAL_COLA[@]}")
  idx=$(( ${#PASOS_COLA[@]} - 1 ))
  if (( idx >= 0 )); then unset "PASOS_COLA[$idx]"; PASOS_COLA=("${PASOS_COLA[@]}"); fi
}

vista_previa_cola() {
  limpiar_pantalla
  titulo "$(t preview_queue_title)" "$(t queue_steps "${#PASOS_COLA[@]}")"
  echo
  local i n=${#FILES[@]} ancho=0 nombre_i cabeza=15 cola=5
  for i in "${!FILES[@]}"; do
    nombre_i="${FILES[$i]##*/}"
    (( ${#nombre_i} > ancho )) && ancho=${#nombre_i}
  done
  (( ancho > 42 )) && ancho=42
  for i in "${!FILES[@]}"; do
    if (( n > 30 )); then
      (( i == cabeza )) && echo -e "  ${C_DIM}$(t more_files "$(( n - cabeza - cola ))")${C_RESET}"
      (( i >= cabeza && i < n - cola )) && continue
    fi
    printf "  ${C_DIM}%-${ancho}s${C_RESET} ${C_ACCENT}${I_ARROW}${C_RESET} ${C_OK}%s${C_RESET}\n" "$(sanear_salida "${FILES[$i]##*/}")" "$(sanear_salida "${NOMBRES_COLA[$i]}")"
  done
}

# ---- Renaming engine ----

# Byte length of $1 into $2, without a subprocess.
longitud_bytes() { local LC_ALL=C; printf -v "$2" '%d' "${#1}"; }

# $1 cut to at most $2 bytes at a UTF-8 boundary (invalid bytes dropped), into $3.
recortar_utf8() {
  local __r=''
  (( $2 > 0 )) && { IFS= read -r -d '' __r < <(printf '%s' "$1" | head -c "$2" | iconv -f UTF-8 -t UTF-8 -c 2>/dev/null) || true; }
  printf -v "$3" '%s' "$__r"
}

nombre_alternativo() {
  local ruta="$1" __var="${2:-}" dir base nombre ext n=1 nuevo corto nb eb dig=0
  dir="${ruta%/*}"; base="${ruta##*/}"
  separar_nombre_ext "$base"; nombre="$SEPARAR_BASE"; ext="$SEPARAR_EXT"
  [[ -n "$ext" ]] && ext=".$ext"
  longitud_bytes "$nombre" nb; longitud_bytes "$ext" eb
  while :; do
    # "(n)" grows with n: re-fit the base so the whole name stays within 255 bytes.
    if (( ${#n} != dig )); then
      dig=${#n}; corto="$nombre"
      (( nb + eb + dig + 2 > 255 )) && recortar_utf8 "$nombre" "$(( 253 - eb - dig ))" corto
    fi
    nuevo="$dir/$corto($n)$ext"
    [[ -e "$nuevo" || -L "$nuevo" ]] || break
    ((n++))
  done
  if [[ -n "$__var" ]]; then printf -v "$__var" '%s' "$nuevo"; else printf '%s' "$nuevo"; fi
}

sanear_nuevo() {
  local n="${1//\//-}" __var="${2:-}" nb ext=''
  n="${n#"${n%%[!$'\t ']*}"}"
  n="${n%"${n##*[!$'\t ']}"}"
  longitud_bytes "$n" nb
  if (( nb > 255 )); then
    [[ "$n" =~ (\.[[:alnum:]_~-]{1,16})$ ]] && ext="${BASH_REMATCH[1]}"
    longitud_bytes "$ext" nb
    recortar_utf8 "$n" "$((255 - nb))" n
    n="${n%"${n##*[!$'\t ']}"}"
  fi
  [[ -z "$n" || "$n" == "." || "$n" == ".." ]] && n="sin_nombre_${RANDOM}"
  n+="$ext"
  if [[ -n "$__var" ]]; then printf -v "$__var" '%s' "$n"; else printf '%s' "$n"; fi
}

# \ : * ? " < > | are valid on ext4 but rejected by FAT/exFAT ("/" is already
# replaced by sanear_nuevo). Only used to retry after a failed mv/cp.
sustituir_caracteres_incompatibles() {
  printf '%s' "${1//[\\:*?\"<>|]/_}"
}

# Probes whether "$1" is really writable now (a read-only mount fails despite
# "rw" permissions).
directorio_solo_lectura() {
  local prueba
  prueba=$(mktemp -- "$1/.renombrador_rw_test.XXXXXX" 2>/dev/null) || return 0
  rm -f -- "$prueba" 2>/dev/null
  return 1
}

# Move LIVE[idx] to new_path. For a directory, repair the LIVE[] paths of
# batch items nested below it.
mover_item() {
  local idx="$1" nuevo_path="$2" out_var="${3:-}" viejo_path="${LIVE[$1]}" j alterno
  if ! mv -nT -- "$viejo_path" "$nuevo_path" 2>/dev/null; then
    alterno=$(sustituir_caracteres_incompatibles "$nuevo_path")
    [[ "$alterno" != "$nuevo_path" ]] && mv -nT -- "$viejo_path" "$alterno" 2>/dev/null || return 1
    nuevo_path="$alterno"
  fi
  [[ ! -e "$viejo_path" && ! -L "$viejo_path" ]] || return 1
  LIVE[$idx]="$nuevo_path"
  if [[ -d "$nuevo_path" ]]; then
    for j in "${!LIVE[@]}"; do
      [[ "$j" == "$idx" ]] && continue
      case "${LIVE[$j]}" in
        "$viejo_path"/*) LIVE[$j]="$nuevo_path/${LIVE[$j]#"$viejo_path"/}" ;;
      esac
    done
  fi
  [[ -n "$out_var" ]] && printf -v "$out_var" '%s' "$nuevo_path"
  return 0
}

# Gives an item back its name ($3); if taken meanwhile, keeps a visible "(n)"
# name, never hidden as .renombrador_*_tmp_*. $1 mover_item|mover_actual,
# $2 index, $4 current path.
devolver_visible() {
  local mover="$1" idx="$2" destino="$3" actual="$4" alterno
  "$mover" "$idx" "$destino" && return 0
  nombre_alternativo "$destino" alterno
  if "$mover" "$idx" "$alterno"; then actual="$alterno"; fi
  printf '%s%s %s%s\n' "$C_WARN" "$I_WARN" "$(t restored_as "$(sanear_salida "$actual")")" "$C_RESET" >&2
  [[ "$actual" == "$alterno" ]]
}

preguntar_politica_conflicto() {
  local n_existentes="$1"
  if (( n_existentes == 0 )); then echo 1; return; fi
  echo -e "${C_WARN}${I_WARN} $(t conflict_found "$n_existentes")${C_RESET}" >&2
  echo -e "  ${C_ACCENT}1)${C_RESET} $(t conflict_suffix)" >&2
  echo -e "  ${C_ACCENT}2)${C_RESET} $(t conflict_overwrite)" >&2
  echo -e "  ${C_ACCENT}3)${C_RESET} $(t conflict_skip)" >&2
  local politica_conflicto
  read -rp "${C_PROMPT}$(t conflict_prompt)${C_RESET}" politica_conflicto
  politica_conflicto=${politica_conflicto:-1}
  [[ "$politica_conflicto" =~ ^[123]$ ]] || politica_conflicto=1
  echo "$politica_conflicto"
}

mostrar_cancelado() { echo -e "${C_DIM}$(t cancelled)${C_RESET}"; pausa; }

mostrar_error() { printf '%s%s %s%s\n' "$C_ERR" "$I_ERR" "$1" "$C_RESET"; pausa; }

mostrar_resumen() {
  local ok="$1" fallos="$2" sin_cambios="$3" omitidos="$4" modo="${5:-mover}" etiqueta_ok
  etiqueta_ok="$(t summary_move)"
  [[ "$modo" == "copiar" ]] && etiqueta_ok="$(t summary_copy)"
  echo -e "${C_OK}${I_OK} ${etiqueta_ok}: $ok${C_RESET}  ${C_WARN}• $(t omitted "$omitidos")${C_RESET}  ${C_ERR}${I_ERR} $(t errors "$fallos")${C_RESET}  ${C_DIM}• $(t unchanged "$sin_cambios")${C_RESET}"
  pausa
}

# Restores an overwritten original after a failed step; never deletes. If the
# name was taken, keeps a visible "(n)" name (not .renombrador_backup_*).
restaurar_respaldo() {
  local respaldo="$1" destino="$2" alterno
  mv -nT -- "$respaldo" "$destino" 2>/dev/null
  [[ ! -e "$respaldo" && ! -L "$respaldo" ]] && return 0
  nombre_alternativo "$destino" alterno
  mv -nT -- "$respaldo" "$alterno" 2>/dev/null
  [[ ! -e "$respaldo" && ! -L "$respaldo" ]] || return 1
  printf '%s%s %s%s\n' "$C_WARN" "$I_WARN" "$(t backup_kept "$(sanear_salida "$alterno")")" "$C_RESET" >&2
}

revertir_aplicacion() {
  local modo="$1" j ruta original destino respaldo fallo=0
  if [[ "$modo" == "copiar" ]]; then
    for ((j=${#HISTORIA_RUTAS[@]}-1; j>=0; j--)); do
      ruta="${HISTORIA_RUTAS[$j]}"
      [[ -e "$ruta" || -L "$ruta" ]] || continue
      rm -rf -- "$ruta" || fallo=1
    done
  else
    for ((j=${#HISTORIA_RUTAS[@]}-1; j>=0; j--)); do
      ruta="${HISTORIA_RUTAS[$j]}"
      original="${HISTORIA_ORIGENES[$j]}"
      [[ -e "$ruta" || -L "$ruta" ]] || continue
      if [[ -e "$original" || -L "$original" ]]; then
        fallo=1
      elif ! mv -T -- "$ruta" "$original"; then
        fallo=1
      fi
    done
  fi
  for ((j=${#BACKUP_PATHS[@]}-1; j>=0; j--)); do
    respaldo="${BACKUP_PATHS[$j]}"
    destino="${BACKUP_TARGETS[$j]}"
    [[ -e "$respaldo" || -L "$respaldo" ]] || continue
    restaurar_respaldo "$respaldo" "$destino" || fallo=1
  done
  return "$fallo"
}

aplicar_renombrado() {
  local i n=${#FILES[@]} saneado destino_alt sel_modo conf respaldo _v
  local -a _viejos=()
  if (( ${#NUEVOS[@]} != n )); then
    mostrar_error "$(t internal_error)"; return 1
  fi
  for i in "${!NUEVOS[@]}"; do sanear_nuevo "${NUEVOS[$i]}" saneado; NUEVOS[$i]="$saneado"; done

  # Preflight analysis: collisions among new names and matches with items outside the batch.
  local dir destino n_colisiones=0 n_existentes=0
  declare -A origen_set=() vistos=() estado=()
  for i in "${!FILES[@]}"; do origen_set["${FILES[$i]}"]=1; done
  for i in "${!FILES[@]}"; do
    dir="${FILES[$i]%/*}"; destino="$dir/${NUEVOS[$i]}"
    estado[$i]="ok"
    if [[ -n "${vistos[$destino]:-}" ]]; then
      estado[$i]="colision"; ((n_colisiones++))
    fi
    vistos[$destino]=1
    if [[ "${estado[$i]}" == "ok" && ( -e "$destino" || -L "$destino" ) && "$destino" != "${FILES[$i]}" && -z "${origen_set[$destino]:-}" ]]; then
      estado[$i]="existe"; ((n_existentes++))
    fi
  done

  echo -e "${C_TITLE}$(t preview)${C_RESET} ${C_DIM}$(t preview_count "$n")${C_RESET}"
  local ancho=0 nombre_i color cabeza=15 cola=5
  for i in "${!FILES[@]}"; do
    nombre_i="${FILES[$i]##*/}"
    (( ${#nombre_i} > ancho )) && ancho=${#nombre_i}
  done
  (( ancho > 42 )) && ancho=42
  for i in "${!FILES[@]}"; do
    if (( n > 30 )); then
      (( i == cabeza )) && echo -e "  ${C_DIM}$(t more_elements "$(( n - cabeza - cola ))")${C_RESET}"
      (( i >= cabeza && i < n - cola )) && continue
    fi
    case "${estado[$i]}" in
      colision) color="$C_ERR" ;;
      existe) color="$C_WARN" ;;
      *) color="$C_OK" ;;
    esac
    printf "  ${C_DIM}%-${ancho}s${C_RESET} ${C_ACCENT}${I_ARROW}${C_RESET} ${color}%s${C_RESET}\n" "$(sanear_salida "${FILES[$i]##*/}")" "$(sanear_salida "${NUEVOS[$i]}")"
  done
  (( n_colisiones > 0 )) && echo -e "${C_ERR}${I_ERR} $(t collision "$n_colisiones")${C_RESET}"

  local modo_aplicacion="${CLI_MODO:-mover}"
  if [[ -z "$CLI_MODO" ]]; then
    echo -e "  ${C_ACCENT}1)${C_RESET} $(t apply_move)   ${C_ACCENT}2)${C_RESET} $(t apply_copy)"
    read -rp "${C_PROMPT}$(t apply_prompt)${C_RESET}" sel_modo
    [[ "$sel_modo" == "2" ]] && modo_aplicacion="copiar"
  fi
  if [[ "$modo_aplicacion" == "copiar" ]]; then
    local hay_anidados=0 j
    for i in "${!FILES[@]}"; do
      [[ -d "${FILES[$i]}" ]] || continue
      for j in "${!FILES[@]}"; do
        [[ "$j" == "$i" ]] && continue
        case "${FILES[$j]}" in "${FILES[$i]}"/*) hay_anidados=1; break 2 ;; esac
      done
    done
    (( hay_anidados )) && echo -e "${C_WARN}${I_WARN} $(t nested_copy_warn)${C_RESET}"
  fi

  local politica_conflicto="${CLI_CONFLICTO:-}"
  if [[ -z "$politica_conflicto" ]]; then
    politica_conflicto=$(preguntar_politica_conflicto "$n_existentes")
    [[ -z "$politica_conflicto" ]] && { mostrar_cancelado; return; }
  fi

  if (( CLI_DRY_RUN )); then
    echo -e "${C_DIM}$(t dry_run)${C_RESET}"
    return 0
  fi

  if (( ! CLI_SIN_CONFIRMAR )); then
    echo -e "  ${C_DIM}$(repetir_char '─' 40)${C_RESET}"
    read -rp "${C_PROMPT}$(t confirm_apply)${C_RESET}" conf
    respuesta_si "$conf" || { mostrar_cancelado; return; }
  fi

  local lote_file
  lote_file="$HISTORY_DIR/$(date +%Y%m%d_%H%M%S)_$$.log"
  while [[ -e "$lote_file" ]]; do lote_file="${lote_file%.log}_x.log"; done
  local origen ok=0 fallos=0 sin_cambios=0 omitidos=0 ts TEMP=()
  local -a HISTORIA_LINEAS=() HISTORIA_TIPOS=()
  HISTORIA_RUTAS=(); HISTORIA_ORIGENES=(); BACKUP_PATHS=(); BACKUP_TARGETS=()
  ts="$$_${RANDOM}"
  local mostrar_progreso=0 hechos=0
  (( n > 200 )) && mostrar_progreso=1

  local -A _dirs_lote=()
  for i in "${!FILES[@]}"; do _dirs_lote["${FILES[$i]%/*}"]=1; done
  for dir in "${!_dirs_lote[@]}"; do
    if directorio_solo_lectura "$dir"; then
      mostrar_error "$(t readonly_target "$(sanear_salida "$dir")")"
      return 1
    fi
  done
  LOTE_APLICADO=1
  barrer_huerfanos "${!_dirs_lote[@]}"
  iniciar_seccion_critica

  if [[ "$modo_aplicacion" == "copiar" ]]; then
    # Each copy starts from the untouched original: no path tracking needed.

    declare -A COLOCADOS=()
    for i in "${!FILES[@]}"; do
      COLOCADOS["${FILES[$i]}"]=1
    done
    for i in "${!FILES[@]}"; do
      origen="${FILES[$i]}"
      dir="${origen%/*}"; destino="$dir/${NUEVOS[$i]}"
      if [[ "$origen" == "$destino" ]]; then ((sin_cambios++)); continue; fi
      local copia_backup=''
      if [[ -e "$destino" || -L "$destino" ]]; then
        if [[ -n "${COLOCADOS[$destino]:-}" ]]; then
          nombre_alternativo "$destino" destino_alt; destino="$destino_alt"
        else
          case "$politica_conflicto" in
            2)
              copia_backup="$dir/.renombrador_backup_${ts}_${i}"
              while [[ -e "$copia_backup" || -L "$copia_backup" ]]; do copia_backup="${copia_backup}_x"; done
              if ! mv -- "$destino" "$copia_backup"; then
                printf '%s%s %s%s\n' "$C_ERR" "$I_ERR" "$(t copy_error "$(sanear_salida "$origen")")" "$C_RESET"
                ((fallos++)); continue
              fi
              ;;
            3) ((omitidos++)); continue ;;
            *) nombre_alternativo "$destino" destino_alt; destino="$destino_alt" ;;
          esac
        fi
      fi
      local destino_usado=''
      if copia_item_atomica "$origen" "$destino" destino_usado; then
        destino="$destino_usado"
        if [[ -n "$copia_backup" ]]; then
          BACKUP_PATHS+=("$copia_backup"); BACKUP_TARGETS+=("$destino")
        fi
        HISTORIA_TIPOS+=("C"); HISTORIA_RUTAS+=("$destino"); HISTORIA_ORIGENES+=("")
        COLOCADOS[$destino]=1; ((ok++))
      else
        printf '%s%s %s%s\n' "$C_ERR" "$I_ERR" "$(t copy_error "$(sanear_salida "$origen")")" "$C_RESET"
        [[ -n "$copia_backup" ]] && restaurar_respaldo "$copia_backup" "$destino"
        ((fallos++))
      fi
      if (( mostrar_progreso )); then
        ((hechos++))
        (( hechos % 25 == 0 || hechos == n )) && barra_progreso "$hechos" "$n"
      fi
      # Each copy is atomic: a pending signal just stops the loop.
      [[ -n "$_LOTE_SENAL" ]] && break
    done
  else
    declare -A LIVE=()
    for i in "${!FILES[@]}"; do LIVE[$i]="${FILES[$i]}"; done

    # Phase 1: move to unique temp names (avoids A->B / B->A collisions). Uses
    # LIVE[] because a moved directory carries its children.
    for i in "${!FILES[@]}"; do
      origen="${LIVE[$i]}"
      dir="${origen%/*}"; destino="$dir/${NUEVOS[$i]}"
      if [[ "$origen" == "$destino" ]]; then TEMP[$i]=""; ((sin_cambios++)); continue; fi
      TEMP[$i]="$dir/.renombrador_tmp_${ts}_${i}"
      if ! mover_item "$i" "${TEMP[$i]}"; then
        printf '%s%s %s%s\n' "$C_ERR" "$I_ERR" "$(t prepare_error "$(sanear_salida "$origen")")" "$C_RESET"
        TEMP[$i]="!"; ((fallos++))
      fi
    done

    # Phase 2: temp name -> final name, applying the policy (suffix / overwrite /
    # skip) for names that already existed outside the batch.
    declare -A COLOCADOS=()
    for i in "${!FILES[@]}"; do
      [[ -z "${TEMP[$i]:-}" || "${TEMP[$i]}" == "!" ]] && COLOCADOS["${LIVE[$i]}"]=1
    done
    for i in "${!FILES[@]}"; do
      [[ -z "${TEMP[$i]:-}" || "${TEMP[$i]}" == "!" ]] && continue
      origen="${FILES[$i]}"
      dir="${LIVE[$i]%/*}"; destino="$dir/${NUEVOS[$i]}"
      local mover_backup=''
      if [[ -e "$destino" || -L "$destino" ]]; then
        if [[ -n "${COLOCADOS[$destino]:-}" ]]; then
          nombre_alternativo "$destino" destino_alt; destino="$destino_alt"
        else
          case "$politica_conflicto" in
            2)
              mover_backup="$dir/.renombrador_backup_${ts}_${i}"
              while [[ -e "$mover_backup" || -L "$mover_backup" ]]; do mover_backup="${mover_backup}_x"; done
              if ! mv -- "$destino" "$mover_backup"; then
                printf '%s%s %s%s\n' "$C_ERR" "$I_ERR" "$(t move_error "$(sanear_salida "$origen")")" "$C_RESET"
                devolver_visible mover_item "$i" "$dir/${origen##*/}" "${LIVE[$i]}"
                ((fallos++)); continue
              fi
              ;;
            3) if devolver_visible mover_item "$i" "$dir/${origen##*/}" "${LIVE[$i]}"; then ((omitidos++)); else ((fallos++)); fi
               continue ;;
            *) nombre_alternativo "$destino" destino_alt; destino="$destino_alt" ;;
          esac
        fi
      fi
      local destino_usado=''
      if mover_item "$i" "$destino" destino_usado; then
        destino="$destino_usado"
        if [[ -n "$mover_backup" ]]; then
          BACKUP_PATHS+=("$mover_backup"); BACKUP_TARGETS+=("$destino")
        fi
        HISTORIA_TIPOS+=("M"); HISTORIA_RUTAS+=("$destino"); HISTORIA_ORIGENES+=("$origen")
        FILES[$i]="$destino"; COLOCADOS[$destino]=1; ((ok++))
      else
        printf '%s%s %s%s\n' "$C_ERR" "$I_ERR" "$(t move_error "$(sanear_salida "$origen")")" "$C_RESET"
        [[ -n "$mover_backup" ]] && restaurar_respaldo "$mover_backup" "$destino"
        devolver_visible mover_item "$i" "$dir/${origen##*/}" "${LIVE[$i]}"
        ((fallos++))
      fi
      if (( mostrar_progreso )); then
        ((hechos++))
        (( hechos % 25 == 0 || hechos == n )) && barra_progreso "$hechos" "$n"
      fi
    done
  fi
  (( mostrar_progreso )) && printf "\r%*s\r" 60 ""
  if (( ok > 0 )); then
    for i in "${!HISTORIA_TIPOS[@]}"; do
      local historial_huella
      if ! historial_huella=$(huella_ruta "${HISTORIA_RUTAS[$i]}"); then
        echo -e "${C_ERR}${I_ERR} $(t history_write_error)${C_RESET}" >&2
        if ! revertir_aplicacion "$modo_aplicacion"; then
          echo -e "${C_ERR}${I_ERR} $(t rollback_error)${C_RESET}" >&2
        fi
        finalizar_seccion_critica_o_salir
        return 1
      fi
      if [[ "${HISTORIA_TIPOS[$i]}" == C ]]; then
        HISTORIA_LINEAS+=("C"$'\t'"$(codificar_texto "${HISTORIA_RUTAS[$i]}")"$'\t-\t'"$historial_huella")
      else
        HISTORIA_LINEAS+=("M"$'\t'"$(codificar_texto "${HISTORIA_RUTAS[$i]}")"$'\t'"$(codificar_texto "${HISTORIA_ORIGENES[$i]}")"$'\t'"$historial_huella")
      fi
    done
    if ! { printf '%s\n' '#version:3' "#modo:${modo_aplicacion}"; printf '%s\n' "${HISTORIA_LINEAS[@]}"; } | escritura_atomica "$lote_file"; then
      echo -e "${C_ERR}${I_ERR} $(t history_write_error)${C_RESET}" >&2
      if ! revertir_aplicacion "$modo_aplicacion"; then
        echo -e "${C_ERR}${I_ERR} $(t rollback_error)${C_RESET}" >&2
      fi
      finalizar_seccion_critica_o_salir
      return 1
    fi
    for respaldo in "${BACKUP_PATHS[@]:-}"; do [[ -n "$respaldo" ]] && rm -rf -- "$respaldo"; done
  fi
  finalizar_seccion_critica_o_salir
  mapfile -t _viejos < <(nombres_lotes | tail -n "+$((MAX_HISTORIAL+1))")
  for _v in "${_viejos[@]:-}"; do [[ -n "$_v" ]] && rm -f -- "$HISTORY_DIR/$_v"; done

  mostrar_resumen "$ok" "$fallos" "$sin_cambios" "$omitidos" "$modo_aplicacion"
  # Non-zero when any item failed, so scripts and cron jobs can tell.
  (( fallos == 0 ))
}

# Batch files, newest first (names start with the timestamp).
nombres_lotes() { find "$HISTORY_DIR" -maxdepth 1 -type f -name '*.log' -printf '%f\n' 2>/dev/null | sort -r; }

listar_historial() {
  mapfile -t LOTES < <(nombres_lotes)
  if (( ${#LOTES[@]} == 0 )); then echo -e "${C_DIM}$(t no_history)${C_RESET}"; return 1; fi
  local i f n fecha modo etiqueta
  for i in "${!LOTES[@]}"; do
    f="${LOTES[$i]}"
    modo=$(modo_de_lote "$HISTORY_DIR/$f")
    n=$(grep -vc '^#' "$HISTORY_DIR/$f" 2>/dev/null)
    etiqueta="$(t history_moved)"
    [[ "$modo" == "copiar" ]] && etiqueta="$(t history_copy)"
    fecha=$(sanear_salida "${f:0:4}-${f:4:2}-${f:6:2} ${f:9:2}:${f:11:2}:${f:13:2}")
    printf '  %s%d)%s %s  %s·%s %s %s\n' "$C_ACCENT" "$((i+1))" "$C_RESET" "$fecha" "$C_DIM" "$C_RESET" "$n" "$etiqueta"
  done
  return 0
}

# Read the mode (mover|copiar) from a batch header "#modo:"; batches without
# it are assumed "mover".
modo_de_lote() {
  local cabecera
  cabecera=$(grep -m1 '^#modo:' -- "$1" 2>/dev/null)
  if [[ "$cabecera" == "#modo:"* ]]; then
    printf '%s' "${cabecera#"#modo:"}"
  else
    printf 'mover'
  fi
}

historial_es_v3() { grep -Fqx '#version:3' -- "$1" 2>/dev/null; }

# Move ACTUAL[idx] to new_path for undo (like mover_item, using ACTUAL[]); for
# a directory, repair nested paths in ACTUAL[].
mover_actual() {
  local idx="$1" nuevo_path="$2" viejo_path="${ACTUAL[$1]}" j
  mv -nT -- "$viejo_path" "$nuevo_path" 2>/dev/null || return 1
  [[ ! -e "$viejo_path" && ! -L "$viejo_path" ]] || return 1
  ACTUAL[idx]="$nuevo_path"
  if [[ -d "$nuevo_path" ]]; then
    for j in "${!ACTUAL[@]}"; do
      [[ "$j" == "$idx" ]] && continue
      case "${ACTUAL[$j]}" in
        "$viejo_path"/*) ACTUAL[j]="$nuevo_path/${ACTUAL[$j]#"$viejo_path"/}" ;;
      esac
    done
  fi
}

deshacer_ultimo() {
  local sel
  limpiar_pantalla
  titulo "$(t undo_title)" "$(t undo_subtitle)"
  echo
  listar_historial || { pausa; return; }
  echo
  read -rp "${C_PROMPT}$(t undo_prompt)${C_RESET}" sel || return
  sel=${sel:-1}
  [[ "$sel" == "0" ]] && return
  if ! sel=$(numero_en_rango "$sel" "${#LOTES[@]}"); then
    echo -e "${C_WARN}${I_WARN} $(t invalid_option)${C_RESET}"; pausa; return
  fi
  local archivo="$HISTORY_DIR/${LOTES[$((sel-1))]}"
  local modo; modo=$(modo_de_lote "$archivo")
  local nuevo original huella tipo ok=0 fallos=0 token_nuevo token_original token_huella
  local -a VIVOS=() ORIGENES=() HUELLAS=() TIPOS=() pendientes=()
  if ! historial_es_v3 "$archivo"; then
    echo -e "${C_WARN}${I_WARN} $(t history_legacy)${C_RESET}"; pausa; return 1
  else
    while IFS=$'\t' read -r tipo token_nuevo token_original token_huella || [[ -n "${tipo}${token_nuevo}${token_original}${token_huella}" ]]; do
      [[ -z "$tipo" || "$tipo" == "#"* ]] && continue
      [[ "$tipo" == C || "$tipo" == M ]] || { echo -e "${C_ERR}${I_ERR} $(t history_invalid)${C_RESET}"; pausa; return 1; }
      [[ "$tipo" == C && "$modo" != "copiar" ]] && { echo -e "${C_ERR}${I_ERR} $(t history_invalid)${C_RESET}"; pausa; return 1; }
      [[ "$tipo" == M && "$modo" != "mover" ]] && { echo -e "${C_ERR}${I_ERR} $(t history_invalid)${C_RESET}"; pausa; return 1; }
      [[ "$tipo" == C && "$token_original" != "-" ]] && { echo -e "${C_ERR}${I_ERR} $(t history_invalid)${C_RESET}"; pausa; return 1; }
      decodificar_texto_en nuevo "$token_nuevo" || { echo -e "${C_ERR}${I_ERR} $(t history_invalid)${C_RESET}"; pausa; return 1; }
      if [[ "$tipo" == M ]]; then
        decodificar_texto_en original "$token_original" || { echo -e "${C_ERR}${I_ERR} $(t history_invalid)${C_RESET}"; pausa; return 1; }
      else
        original=''
      fi
      [[ "$token_huella" =~ ^[0-9a-f]{64}$ ]] || { echo -e "${C_ERR}${I_ERR} $(t history_invalid)${C_RESET}"; pausa; return 1; }
      VIVOS+=("$nuevo"); ORIGENES+=("$original"); HUELLAS+=("$token_huella"); TIPOS+=("$tipo")
    done < "$archivo"
  fi

  local -A _dirs_lote=()
  for nuevo in "${VIVOS[@]}"; do _dirs_lote["${nuevo%/*}"]=1; done
  for original in "${ORIGENES[@]}"; do [[ -n "$original" ]] && _dirs_lote["${original%/*}"]=1; done
  barrer_huerfanos "${!_dirs_lote[@]}"
  iniciar_seccion_critica

  if [[ "$modo" == "copiar" ]]; then
    local i pend
    for i in "${!VIVOS[@]}"; do
      nuevo="${VIVOS[$i]}"; huella="${HUELLAS[$i]}"; pend=0
      # Each deletion is atomic. Checked before every item: once a signal is pending
      # nothing else is deleted and the rest stays in the batch.
      if [[ -n "$_LOTE_SENAL" ]]; then
        pend=1
      elif [[ ! -e "$nuevo" && ! -L "$nuevo" ]]; then
        ((fallos++)); pend=1
      elif ! huella_coincide "$nuevo" "$huella"; then
        printf '%s%s %s%s %s%s\n' "$C_WARN" "$I_WARN" "$(t history_changed)" "$C_RESET" "$C_DIM$(sanear_salida "$nuevo")" "$C_RESET"
        ((fallos++)); pend=1
      elif rm -rf -- "$nuevo"; then
        ((ok++))
      else
        ((fallos++)); pend=1
      fi
      ((pend)) && pendientes+=("C"$'\t'"$(codificar_texto "$nuevo")"$'\t-\t'"$huella")
    done
    if (( ${#pendientes[@]} > 0 )); then
      if ! { printf '%s\n' '#version:3' '#modo:copiar'; printf '%s\n' "${pendientes[@]}"; } | escritura_atomica "$archivo"; then
        echo -e "${C_ERR}${I_ERR} $(t history_write_error)${C_RESET}" >&2
      fi
    else
      rm -f -- "$archivo"
    fi
    finalizar_seccion_critica_o_salir
    echo -e "${C_OK}${I_OK} $(t copies_deleted "$ok")${C_RESET}  ${C_ERR}${I_ERR} $(t errors "$fallos")${C_RESET}"
    pausa
    return
  fi

  # Move mode: two-phase restore through a temp name, as in aplicar_renombrado,
  # so swaps undo without collisions. ACTUAL[] tracks each item's current path.
  local i dir ts
  ts="$$_${RANDOM}"
  local -a ACTUAL=("${VIVOS[@]}") TEMP=()

  # Phase 1: temporary names.
  for i in "${!VIVOS[@]}"; do
    nuevo="${ACTUAL[$i]}"; huella="${HUELLAS[$i]}"
    if [[ ! -e "$nuevo" && ! -L "$nuevo" ]] || ! huella_coincide "$nuevo" "$huella"; then
      if [[ -e "$nuevo" || -L "$nuevo" ]]; then
        printf '%s%s %s%s %s%s\n' "$C_WARN" "$I_WARN" "$(t history_changed)" "$C_RESET" "$C_DIM$(sanear_salida "$nuevo")" "$C_RESET"
      fi
      ((fallos++)); pendientes+=("M"$'\t'"$(codificar_texto "$nuevo")"$'\t'"$(codificar_texto "${ORIGENES[$i]}")"$'\t'"$huella"); TEMP[i]="!"; continue
    fi
    dir="${nuevo%/*}"
    TEMP[i]="$dir/.renombrador_undo_tmp_${ts}_${i}"
    if ! mover_actual "$i" "${TEMP[$i]}"; then
      ((fallos++)); pendientes+=("M"$'\t'"$(codificar_texto "$nuevo")"$'\t'"$(codificar_texto "${ORIGENES[$i]}")"$'\t'"$huella"); TEMP[i]="!"
    fi
  done

  # Phase 2: from temporary names to original names.
  for i in "${!VIVOS[@]}"; do
    [[ "${TEMP[$i]}" == "!" ]] && continue
    original="${ORIGENES[$i]}"
    if [[ -e "$original" || -L "$original" ]]; then
      printf '%s%s %s%s\n' "$C_WARN" "$I_WARN" "$(t original_exists "$(sanear_salida "$original")" "$(sanear_salida "${VIVOS[$i]}")")" "$C_RESET"
      devolver_visible mover_actual "$i" "${ACTUAL[$i]%/*}/${VIVOS[$i]##*/}" "${ACTUAL[$i]}"
      ((fallos++)); pendientes+=("M"$'\t'"$(codificar_texto "${ACTUAL[$i]}")"$'\t'"$(codificar_texto "$original")"$'\t'"${HUELLAS[$i]}")
      continue
    fi
    if mover_actual "$i" "$original"; then
      ((ok++))
    else
      devolver_visible mover_actual "$i" "${ACTUAL[$i]%/*}/${VIVOS[$i]##*/}" "${ACTUAL[$i]}"
      ((fallos++)); pendientes+=("M"$'\t'"$(codificar_texto "${ACTUAL[$i]}")"$'\t'"$(codificar_texto "$original")"$'\t'"${HUELLAS[$i]}")
    fi
  done
  if (( ${#pendientes[@]} > 0 )); then
    if ! { printf '%s\n' '#version:3' '#modo:mover'; printf '%s\n' "${pendientes[@]}"; } | escritura_atomica "$archivo"; then
      echo -e "${C_ERR}${I_ERR} $(t history_write_error)${C_RESET}" >&2
    fi
  else
    rm -f -- "$archivo"
  fi
  finalizar_seccion_critica_o_salir
  echo -e "${C_OK}${I_OK} $(t undone "$ok")  ${C_ERR}${I_ERR} $(t errors "$fallos")${C_RESET}"
  pausa
}

# ---- Renaming methods ----

# ---- Pure transformations (used by both terminal and graphical modes) ----

# Return FILES[] indices sorted by criterion (one per line); ties keep
# original order.
orden_indices_por_criterio() {
  local criterio="$1" i archivo valor tipo base ext
  local -a pares=()
  [[ "$criterio" == exif ]] && precargar_exif
  for i in "${!FILES[@]}"; do
    archivo="${FILES[$i]}"
    case "$criterio" in
      fecha) valor=$(date -r "$archivo" +%s 2>/dev/null) ;;
      exif)
        separar_nombre_ext "${archivo##*/}"; base="$SEPARAR_BASE"; ext="$SEPARAR_EXT"
        tipo=$(detectar_tipo "$ext")
        valor=$(epoch_foto "$archivo" "$tipo") ;;
      tamano) valor=$(stat -L -c%s -- "$archivo" 2>/dev/null) ;;
    esac
    pares+=("${valor:-0}"$'\t'"$i")
  done
  printf '%s\n' "${pares[@]}" | sort -n -k1,1 -k2,2 | cut -f2
}

transformar_numeracion() {
  local modo="$1" base="$2" inicio="$3" digitos="$4" orden_str="$5"
  local n=$inicio idx nombre orig ext num
  local -a orden=()
  if [[ -n "$orden_str" ]]; then read -ra orden <<< "$orden_str"; else orden=("${!FILES[@]}"); fi
  for idx in "${orden[@]}"; do
    nombre="${NOMBRES_COLA[$idx]}"
    separar_nombre_ext "$nombre"; orig="$SEPARAR_BASE"; ext="$SEPARAR_EXT"
    [[ -n "$ext" ]] && ext=".${ext}"
    printf -v num "%0${digitos}d" "$n"
    [[ "$modo" == "2" ]] && base="$orig"
    NOMBRES_COLA[idx]="${base}_${num}${ext}"
    ((n++))
  done
}

metodo_numeracion() {
  local modo base inicio auto_digitos digitos criterio etiqueta_orden_es="" etiqueta_orden_en=""
  echo -e "  ${C_ACCENT}1)${C_RESET} $(t numbering_custom)   ${C_ACCENT}2)${C_RESET} $(t numbering_keep)"
  read -rp "${C_PROMPT}$(t choice_default)${C_RESET}" modo; modo=${modo:-1}
  [[ "$modo" != "2" ]] && read -rp "${C_PROMPT}$(t base_text)${C_RESET}" base
  echo -e "${C_DIM}$(t numbering_order)${C_RESET}"
  echo -e "  ${C_ACCENT}1)${C_RESET} $(t numbering_current)   ${C_ACCENT}2)${C_RESET} $(t numbering_mtime "$I_ARROW")"
  echo -e "  ${C_ACCENT}3)${C_RESET} $(t numbering_exif "$I_ARROW")   ${C_ACCENT}4)${C_RESET} $(t numbering_size "$I_ARROW")"
  read -rp "${C_PROMPT}$(t choice_default)${C_RESET}" criterio; criterio=${criterio:-1}
  echo -e "${C_DIM}$(t numbering_start_hint)${C_RESET}"
  read -rp "${C_PROMPT}$(t numbering_start)${C_RESET}" inicio
  if [[ "$inicio" =~ ^[0-9]+$ ]]; then
    inicio=$(normalizar_decimal "$inicio")
    en_rango_decimal "$inicio" 9000000000000000000 || inicio=1
  else
    inicio=1
  fi
  auto_digitos=${#FILES[@]}; auto_digitos=${#auto_digitos}
  local ejemplo_num
  printf -v ejemplo_num "%0${auto_digitos}d" "$inicio"
  echo -e "${C_DIM}$(t numbering_digits_hint "$auto_digitos" "$inicio" "$ejemplo_num")${C_RESET}"
  read -rp "${C_PROMPT}$(t numbering_digits "$auto_digitos")${C_RESET}" digitos
  if [[ "$digitos" =~ ^[0-9]+$ ]]; then
    digitos=$(normalizar_decimal "$digitos")
    en_rango_decimal "$digitos" 18 || digitos=$auto_digitos
  else
    digitos=$auto_digitos
  fi

  local -a orden=()
  case "$criterio" in
    2) mapfile -t orden < <(orden_indices_por_criterio fecha); etiqueta_orden_es="$(t_lang es numbering_order_mtime_label)"; etiqueta_orden_en="$(t_lang en numbering_order_mtime_label)" ;;
    3) comprobar_herramientas_exif
       if [[ -z "$EXIFTOOL_DISPONIBLE" && -z "$IDENTIFY_DISPONIBLE" ]]; then
         echo -e "${C_WARN}${I_WARN} $(t exif_fallback_short)${C_RESET}"
       fi
       mapfile -t orden < <(orden_indices_por_criterio exif); etiqueta_orden_es="$(t_lang es numbering_order_exif_label)"; etiqueta_orden_en="$(t_lang en numbering_order_exif_label)" ;;
    4) mapfile -t orden < <(orden_indices_por_criterio tamano); etiqueta_orden_es="$(t_lang es numbering_order_size_label)"; etiqueta_orden_en="$(t_lang en numbering_order_size_label)" ;;
    *) orden=("${!FILES[@]}"); etiqueta_orden_es=""; etiqueta_orden_en="" ;;
  esac

  guardar_snapshot_cola
  transformar_numeracion "$modo" "$base" "$inicio" "$digitos" "${orden[*]}"
  registrar_paso "$(t_lang es step_numbering) ('$base'${etiqueta_orden_es})" "$(t_lang en step_numbering) ('$base'${etiqueta_orden_en})"
}

transformar_prefijo() {
  local pre="$1" i
  for i in "${!FILES[@]}"; do NOMBRES_COLA[i]="${pre}${NOMBRES_COLA[$i]}"; done
}

metodo_prefijo() {
  local pre
  read -rp "${C_PROMPT}$(t prefix)${C_RESET}" pre
  guardar_snapshot_cola
  transformar_prefijo "$pre"
  registrar_paso "$(t_lang es step_prefix): '$pre'" "$(t_lang en step_prefix): '$pre'"
}

transformar_sufijo() {
  local suf="$1" i nombre base ext
  for i in "${!FILES[@]}"; do
    nombre="${NOMBRES_COLA[$i]}"
    separar_nombre_ext "$nombre"; base="$SEPARAR_BASE"; ext="$SEPARAR_EXT"
    [[ -n "$ext" ]] && ext=".${ext}"
    NOMBRES_COLA[i]="${base}${suf}${ext}"
  done
}

metodo_sufijo() {
  local suf
  read -rp "${C_PROMPT}$(t suffix)${C_RESET}" suf
  guardar_snapshot_cola
  transformar_sufijo "$suf"
  registrar_paso "$(t_lang es step_suffix): '$suf'" "$(t_lang en step_suffix): '$suf'"
}

validar_regex() {
  local buscar="$1" reemplazo="$2" delim="$3"
  # Intentional order: drop stdout, keep sed's stderr as the returned message.
  # shellcheck disable=SC2069
  printf '%s' "" | sed -E "s${delim}${buscar}${delim}${reemplazo}${delim}g" 2>&1 1>/dev/null
}

delimitador_para() {
  local buscar="$1" reemplazo="$2" delim
  for delim in '/' '#' '|' '@' '~' ';' ':' ',' '%' '!' '^' '_' '+' '=' $'\x1f' $'\x1e' $'\x1d' $'\x1c' $'\x1b' $'\x1a'; do
    [[ "$buscar$reemplazo" != *"$delim"* ]] && { printf '%s' "$delim"; return; }
  done
  return 1
}

transformar_buscar_reemplazar() {
  local modo="$1" buscar="$2" reemplazo="$3" i nombre delim buscar_esc resultado
  if [[ "$modo" == "2" ]]; then
    delim=$(delimitador_para "$buscar" "$reemplazo") || return 1
    for i in "${!FILES[@]}"; do
      nombre="${NOMBRES_COLA[$i]}"
      if IFS= read -r -d '' resultado < <(printf '%s\0' "$nombre" | sed -z -E "s${delim}${buscar}${delim}${reemplazo}${delim}g"); then
        NOMBRES_COLA[i]="$resultado"
      else
        NOMBRES_COLA[i]="$nombre"
      fi
    done
  else
    buscar_esc="${buscar//\\/\\\\}"
    buscar_esc="${buscar_esc//\*/\\*}"
    buscar_esc="${buscar_esc//\?/\\?}"
    buscar_esc="${buscar_esc//\[/\\[}"
    for i in "${!FILES[@]}"; do
      nombre="${NOMBRES_COLA[$i]}"
      NOMBRES_COLA[i]="${nombre//$buscar_esc/$reemplazo}"
    done
  fi
}

metodo_buscar_reemplazar() {
  local modo buscar reemplazo delim err
  echo -e "  ${C_ACCENT}1)${C_RESET} $(t replace_literal)   ${C_ACCENT}2)${C_RESET} $(t replace_regex)"
  read -rp "${C_PROMPT}$(t choice_default)${C_RESET}" modo; modo=${modo:-1}
  read -rp "${C_PROMPT}$(t search)${C_RESET}" buscar
  if [[ -z "$buscar" ]]; then
    echo -e "${C_WARN}${I_WARN} $(t empty_search)${C_RESET}"; pausa; return
  fi
  [[ "$modo" == "2" ]] && echo -e "${C_DIM}$(t capture_hint)${C_RESET}"
  read -rp "${C_PROMPT}$(t replace)${C_RESET}" reemplazo
  if [[ "$modo" == "2" ]]; then
    delim=$(delimitador_para "$buscar" "$reemplazo")
    err=$(validar_regex "$buscar" "$reemplazo" "$delim")
    if [[ -n "$err" ]]; then
      printf '%s%s %s%s\n' "$C_ERR" "$I_ERR" "$(t invalid_regex "$(sanear_salida "$err")")" "$C_RESET"; pausa; return
    fi
  fi
  guardar_snapshot_cola
  transformar_buscar_reemplazar "$modo" "$buscar" "$reemplazo"
  if [[ "$modo" == "2" ]]; then
    registrar_paso "$(t_lang es step_regex): '$buscar' ${I_ARROW} '$reemplazo'" "$(t_lang en step_regex): '$buscar' ${I_ARROW} '$reemplazo'"
  else
    registrar_paso "$(t_lang es step_replace): '$buscar' ${I_ARROW} '$reemplazo'" "$(t_lang en step_replace): '$buscar' ${I_ARROW} '$reemplazo'"
  fi
}

capitalizar() {
  local nombre="$1" __var="${2:-}" base ext resultado
  separar_nombre_ext "$nombre"; base="$SEPARAR_BASE"; ext="$SEPARAR_EXT"
  [[ -n "$ext" ]] && ext=".$ext"
  base="${base,,}"
  IFS= read -r -d '' resultado < <(printf '%s\0' "$base" | sed -z -E 's/(^|[ _-])([[:lower:]])/\1\U\2/g') || resultado="$base"
  resultado="${resultado}${ext}"
  if [[ -n "$__var" ]]; then printf -v "$__var" '%s' "$resultado"; else printf '%s' "$resultado"; fi
}

transformar_mayus_minus() {
  local op="$1" i nombre base ext capitalizado
  for i in "${!FILES[@]}"; do
    nombre="${NOMBRES_COLA[$i]}"
    case "$op" in
      1) NOMBRES_COLA[i]="${nombre,,}" ;;
      2) NOMBRES_COLA[i]="${nombre^^}" ;;
      3) capitalizar "$nombre" capitalizado; NOMBRES_COLA[i]="$capitalizado" ;;
      4) separar_nombre_ext "$nombre"; base="$SEPARAR_BASE"; ext="$SEPARAR_EXT"
         [[ -n "$ext" ]] && ext=".${ext}"
         base="${base,,}"; NOMBRES_COLA[i]="${base^}${ext}" ;;
      *) ;;
    esac
  done
}

metodo_mayus_minus() {
  local op
  echo -e "  ${C_ACCENT}1)${C_RESET} $(t case_lower)   ${C_ACCENT}2)${C_RESET} $(t case_upper)   ${C_ACCENT}3)${C_RESET} $(t case_title)   ${C_ACCENT}4)${C_RESET} $(t case_sentence)"
  read -rp "${C_PROMPT}$(t choice_default)${C_RESET}" op; op=${op:-1}
  if [[ ! "$op" =~ ^[1-4]$ ]]; then
    echo -e "${C_WARN}${I_WARN} $(t invalid_option_no_change)${C_RESET}"; pausa; return
  fi
  guardar_snapshot_cola
  transformar_mayus_minus "$op"
  registrar_paso "$(t_lang es step_case)" "$(t_lang en step_case)"
}

transformar_fecha() {
  local origen_fecha="$1" pos="$2" i nombre fecha base ext tipo
  [[ "$origen_fecha" == 3 ]] && precargar_exif
  for i in "${!FILES[@]}"; do
    nombre="${NOMBRES_COLA[$i]}"
    separar_nombre_ext "$nombre"; base="$SEPARAR_BASE"; ext="$SEPARAR_EXT"
    case "$origen_fecha" in
      2) fecha=$(date -r "${FILES[$i]}" +%Y-%m-%d) ;;
      3) tipo=$(detectar_tipo "$ext"); fecha=$(fecha_foto "${FILES[$i]}" "$tipo") ;;
      *) fecha=$(date +%Y-%m-%d) ;;
    esac
    [[ -z "$fecha" ]] && fecha=$(date +%Y-%m-%d)
    [[ -n "$ext" ]] && ext=".${ext}"
    if [[ "$pos" == "1" ]]; then NOMBRES_COLA[i]="${fecha}_${base}${ext}"; else NOMBRES_COLA[i]="${base}_${fecha}${ext}"; fi
  done
}

metodo_fecha() {
  local op pos
  echo -e "  ${C_ACCENT}1)${C_RESET} $(t date_current)   ${C_ACCENT}2)${C_RESET} $(t date_modified)   ${C_ACCENT}3)${C_RESET} $(t date_exif)"
  read -rp "${C_PROMPT}$(t choice_default)${C_RESET}" op; op=${op:-1}
  if [[ "$op" == "3" ]]; then
    comprobar_herramientas_exif
    if [[ -z "$EXIFTOOL_DISPONIBLE" && -z "$IDENTIFY_DISPONIBLE" ]]; then
      echo -e "${C_WARN}${I_WARN} $(t exif_fallback_long)${C_RESET}"
      echo -e "${C_DIM}  $(t exif_install)${C_RESET}"
    fi
  fi
  echo -e "  ${C_ACCENT}1)${C_RESET} $(t position_start)   ${C_ACCENT}2)${C_RESET} $(t position_end)"
  read -rp "${C_PROMPT}$(t position_prompt)${C_RESET}" pos; pos=${pos:-2}
  guardar_snapshot_cola
  transformar_fecha "$op" "$pos"
  case "$op" in
    2) registrar_paso "$(t_lang es step_date_modified)" "$(t_lang en step_date_modified)" ;;
    3) registrar_paso "$(t_lang es step_date_exif)" "$(t_lang en step_date_exif)" ;;
    *) registrar_paso "$(t_lang es step_date_current)" "$(t_lang en step_date_current)" ;;
  esac
}

transformar_limpiar() {
  local sep="$1" i nombre base ext
  for i in "${!FILES[@]}"; do
    nombre="${NOMBRES_COLA[$i]}"
    separar_nombre_ext "$nombre"; base="$SEPARAR_BASE"; ext="$SEPARAR_EXT"
    [[ -n "$ext" ]] && ext=".${ext}"
    base="${base// /$sep}"
    base="${base//\//$sep}"
    local cleaned=''
    IFS= read -r -d '' cleaned < <(printf '%s\0' "$base" | sed -z -E 's#[<>:"\|?*]##g') || cleaned="$base"
    NOMBRES_COLA[i]="${cleaned}${ext}"
  done
}

metodo_limpiar() {
  local op sep
  echo -e "  ${C_ACCENT}1)${C_RESET} $(t clean_spaces) ${I_ARROW} $(t clean_underscore)   ${C_ACCENT}2)${C_RESET} $(t clean_spaces) ${I_ARROW} $(t clean_dash)   ${C_ACCENT}3)${C_RESET} $(t clean_remove)"
  read -rp "${C_PROMPT}$(t choice_default)${C_RESET}" op; op=${op:-1}
  case "$op" in
    2) sep="-" ;;
    3) sep="" ;;
    *) sep="_" ;;
  esac
  guardar_snapshot_cola
  transformar_limpiar "$sep"
  registrar_paso "$(t_lang es step_clean)" "$(t_lang en step_clean)"
}

reiniciar_cola() {
  local i
  NOMBRES_COLA=(); PASOS_COLA=(); HISTORIAL_COLA=()
  for i in "${!FILES[@]}"; do NOMBRES_COLA[i]="${FILES[$i]##*/}"; done
}

menu_metodos() {
  local i op sub conf
  reiniciar_cola
  while true; do
    limpiar_pantalla
    sub="$(t method_selected "${#FILES[@]}")"
    (( ${#PASOS_COLA[@]} > 0 )) && sub+="$(t steps_pending "${#PASOS_COLA[@]}")"
    titulo "$(t method_title)" "$sub"
    echo
    opt 1 "🔢" "$(t method_numbering)"
    opt 2 "⏪" "$(t method_prefix)"
    opt 3 "⏩" "$(t method_suffix)"
    opt 4 "🔍" "$(t method_replace)"
    opt 5 "🔤" "$(t method_case)"
    opt 6 "📅" "$(t method_date)"
    opt 7 "🧹" "$(t method_clean)"
    echo -e "  ${C_DIM}$(repetir_char '·' 44)${C_RESET}"
    opt 8 "🤖" "$(t method_type)"
    opt 9 "📂" "$(t method_template)"
    opt 10 "✨" "$(t method_new_template)"
    opt 11 "🎯" "$(t method_pattern)"
    if (( ${#PASOS_COLA[@]} > 0 )); then
      echo -e "  ${C_DIM}$(repetir_char '·' 44)${C_RESET}"
      for i in "${!PASOS_COLA[@]}"; do
        printf '  %s   %d. %s%s\n' "$C_DIM" "$((i+1))" "$(paso_texto "${PASOS_COLA[$i]}")" "$C_RESET"
      done
      opt v "👁️" "$(t preview_queue)"
      opt u "⬅️" "$(t undo_step)"
      opt a "✅" "$(t apply_all)"
    fi
    echo -e "  ${C_DIM}$(repetir_char '·' 44)${C_RESET}"
    opt i "🌐" "$(etiqueta_cambio_idioma)"
    opt 0 "↩️" "$(t back)"
    echo
    read -rp "${C_PROMPT}$(t option_prompt)${C_RESET}" op || return
    case "$op" in
      1) metodo_numeracion ;;
      2) metodo_prefijo ;;
      3) metodo_sufijo ;;
      4) metodo_buscar_reemplazar ;;
      5) metodo_mayus_minus ;;
      6) metodo_fecha ;;
      7) metodo_limpiar ;;
      8) metodo_por_tipo ;;
      9) usar_plantilla_guardada ;;
      10) crear_plantilla ;;
      11) aplicar_patron_puntual ;;
      v|V) (( ${#PASOS_COLA[@]} > 0 )) && { vista_previa_cola; pausa; } ;;
      u|U) deshacer_paso_cola ;;
      a|A)
        if (( ${#PASOS_COLA[@]} == 0 )); then
          echo -e "${C_WARN}${I_WARN} $(t no_undo_steps)${C_RESET}"; pausa
        else
          NUEVOS=("${NOMBRES_COLA[@]}"); LOTE_APLICADO=0
          aplicar_renombrado
          (( LOTE_APLICADO )) && reiniciar_cola  # cancelled or refused: keep the queue
        fi
        ;;
      i|I) cambiar_idioma ;;
      0)
        if (( ${#PASOS_COLA[@]} > 0 )); then
          read -rp "${C_PROMPT}$(t discard_pending "${#PASOS_COLA[@]}")${C_RESET}" conf
          respuesta_si "$conf" || continue
        fi
        return ;;
      *) echo -e "${C_WARN}${I_WARN} $(t invalid_option)${C_RESET}"; pausa ;;
    esac
  done
}

# ---- Templates by file type ----

detectar_tipo() {
  case "${1,,}" in
    jpg|jpeg|png|gif|bmp|webp|tiff|svg|ico|heic|heif|avif) echo "Foto" ;;
    mp4|mkv|avi|mov|wmv|flv|webm) echo "Video" ;;
    mp3|wav|flac|ogg|m4a|aac|opus) echo "Audio" ;;
    pdf|doc|docx|odt|txt|xls|xlsx|ppt|pptx|csv|epub) echo "Documento" ;;
    zip|rar|7z|tar|gz|tgz|bz2|xz) echo "Comprimido" ;;
    sh|py|js|ts|html|css|json|c|cpp|java|php|rb|go|rs) echo "Codigo" ;;
    *) echo "Archivo" ;;
  esac
}

metodo_por_tipo() {
  local -A contador
  local i nombre base ext tipo num
  guardar_snapshot_cola
  for i in "${!FILES[@]}"; do
    nombre="${NOMBRES_COLA[$i]}"
    separar_nombre_ext "$nombre"; base="$SEPARAR_BASE"; ext="$SEPARAR_EXT"
    tipo=$(detectar_tipo "$ext")
    contador[$tipo]=$(( ${contador[$tipo]:-0} + 1 ))
    printf -v num "%03d" "${contador[$tipo]}"
    [[ -n "$ext" ]] && ext=".${ext}"
    NOMBRES_COLA[i]="${tipo}_${num}${ext}"
  done
  registrar_paso "$(t_lang es step_type)" "$(t_lang en step_type)"
}

# ---- Custom templates ----

# One-pass wildcard expansion: a name containing "{n}" or "{date}" stays
# literal. An empty {ext} also drops the dot right before it.
# $1 pattern, $2-$8 name ext n date parent filedate filetime, $9 output var.
expandir_patron() {
  local resto="$1" salida=''
  while [[ "$resto" == *'{'* ]]; do
    salida+="${resto%%\{*}"; resto="${resto#*\{}"
    case "$resto" in
      name\}*) salida+="$2"; resto="${resto#name\}}" ;;
      ext\}*) [[ -z "$3" ]] && salida="${salida%.}"; salida+="$3"; resto="${resto#ext\}}" ;;
      n\}*) salida+="$4"; resto="${resto#n\}}" ;;
      date\}*) salida+="$5"; resto="${resto#date\}}" ;;
      parent\}*) salida+="$6"; resto="${resto#parent\}}" ;;
      filedate\}*) salida+="$7"; resto="${resto#filedate\}}" ;;
      filetime\}*) salida+="$8"; resto="${resto#filetime\}}" ;;
      *) salida+='{' ;;
    esac
  done
  printf -v "$9" '%s' "$salida$resto"
}

aplicar_patron() {
  local patron="$1" inicio="${2:-1}" digitos="${3:-0}" n fecha i nombre base ext parent dir num resultado usa_ext=0 usa_sello=0 sello fecha_f='' hora_f=''
  local -A padres=()
  [[ "$patron" == *"{ext}"* ]] && usa_ext=1
  [[ "$patron" == *"{filedate}"* || "$patron" == *"{filetime}"* ]] && usa_sello=1
  (( usa_sello )) && precargar_exif
  fecha=$(date +%Y-%m-%d)
  n=$inicio
  guardar_snapshot_cola
  for i in "${!FILES[@]}"; do
    nombre="${NOMBRES_COLA[$i]}"
    separar_nombre_ext "$nombre"; base="$SEPARAR_BASE"; ext="$SEPARAR_EXT"
    dir="${FILES[$i]%/*}"
    if [[ -z "${padres[$dir/]+x}" ]]; then
      parent="${dir##*/}"
      if [[ -z "$parent" || "$parent" == . || "$parent" == .. ]]; then
        realpath_en_var parent "$dir" -e && parent="${parent##*/}" || parent=""
      fi
      padres[$dir/]="$parent"
    fi
    parent="${padres[$dir/]}"
    if [[ "$digitos" -gt 0 ]]; then printf -v num "%0${digitos}d" "$n"; else num="$n"; fi
    if (( usa_sello )); then
      sello=$(sello_archivo "${FILES[$i]}"); [[ -z "$sello" ]] && sello=$(date '+%Y-%m-%d %H-%M-%S')
      fecha_f="${sello% *}"; hora_f="${sello#* }"
    fi
    expandir_patron "$patron" "$base" "$ext" "$num" "$fecha" "$parent" "$fecha_f" "$hora_f" resultado
    [[ -n "$ext" && $usa_ext -eq 0 ]] && resultado="${resultado}.${ext}"
    NOMBRES_COLA[i]="$resultado"
    ((n++))
  done
  registrar_paso "$(t_lang es step_template): $patron" "$(t_lang en step_template): $patron"
}

pedir_parametros_n() {
  INICIO_N=1; DIGITOS_N=0
  if [[ "$1" == *"{n}"* ]]; then
    local auto_digitos
    echo -e "${C_DIM}$(t pattern_n_hint)${C_RESET}"
    read -rp "${C_PROMPT}$(t pattern_n_start)${C_RESET}" INICIO_N
    if [[ "$INICIO_N" =~ ^[0-9]+$ ]]; then
      INICIO_N=$(normalizar_decimal "$INICIO_N")
      en_rango_decimal "$INICIO_N" 9000000000000000000 || INICIO_N=1
    else
      INICIO_N=1
    fi
    auto_digitos=${#FILES[@]}; auto_digitos=${#auto_digitos}
    local ejemplo_num
    printf -v ejemplo_num "%0${auto_digitos}d" "$INICIO_N"
    echo -e "${C_DIM}$(t pattern_n_digits "$auto_digitos" "$INICIO_N" "$ejemplo_num")${C_RESET}"
    read -rp "${C_PROMPT}$(t pattern_n_digits_prompt)${C_RESET}" DIGITOS_N
    if [[ "$DIGITOS_N" =~ ^[0-9]+$ ]]; then
      DIGITOS_N=$(normalizar_decimal "$DIGITOS_N")
      en_rango_decimal "$DIGITOS_N" 18 || DIGITOS_N=0
    else
      DIGITOS_N=0
    fi
  fi
}

patron_es_ambiguo() {
  local p="$1"
  [[ "$p" != *"{name}"* && "$p" != *"{n}"* && "$p" != *"{date}"* && "$p" != *"{parent}"* \
    && "$p" != *"{filedate}"* && "$p" != *"{filetime}"* ]]
}

avisar_si_ambiguo() {
  patron_es_ambiguo "$1" && echo -e "${C_WARN}${I_WARN} $(t ambiguous_pattern)${C_RESET}"
}

pedir_nombre_y_patron() {
  read -rp "${C_PROMPT}$(t template_name)${C_RESET}" NOMBRE_PLANTILLA
  echo -e "${C_DIM}$(t template_hint)${C_RESET}"
  read -rp "${C_PROMPT}$(t pattern_prompt)${C_RESET}" PATRON_PLANTILLA
  if [[ -z "$PATRON_PLANTILLA" ]]; then
    echo -e "${C_WARN}${I_WARN} $(t empty_pattern)${C_RESET}"; return 1
  fi
  avisar_si_ambiguo "$PATRON_PLANTILLA"
  NOMBRE_PLANTILLA="${NOMBRE_PLANTILLA//|/-}"
  PATRON_PLANTILLA="${PATRON_PLANTILLA//|/}"
  [[ -z "$NOMBRE_PLANTILLA" ]] && NOMBRE_PLANTILLA="$(t template_default_name "$(date +%H%M%S)")"
  return 0
}

# ---- Template lock ----
# guardar_plantilla/eliminar_plantilla/importar_plantillas_desde_archivo read,
# compute and write back TEMPLATES_FILE non-atomically; two instances could
# erase each other's change. flock serializes them (released on every exit
# path, and by the kernel if the process dies).
PLANTILLAS_LOCK_FD=""
bloquear_plantillas() {
  [[ -L "$PLANTILLAS_LOCK_FILE" ]] && return 1
  exec {PLANTILLAS_LOCK_FD}>"$PLANTILLAS_LOCK_FILE" || return 1
  if ! flock -x -w 10 "$PLANTILLAS_LOCK_FD"; then
    exec {PLANTILLAS_LOCK_FD}>&-
    PLANTILLAS_LOCK_FD=""
    return 1
  fi
}
desbloquear_plantillas() {
  [[ -n "$PLANTILLAS_LOCK_FD" ]] || return 0
  exec {PLANTILLAS_LOCK_FD}>&-
  PLANTILLAS_LOCK_FD=""
}

guardar_plantilla() {
  pedir_nombre_y_patron || return 1
  if ! bloquear_plantillas; then
    echo -e "${C_ERR}${I_ERR} $(t storage_error)${C_RESET}"
    return 1
  fi
  local contenido=''
  if [[ -f "$TEMPLATES_FILE" ]] && ! contenido=$(cat -- "$TEMPLATES_FILE"); then
    echo -e "${C_ERR}${I_ERR} $(t storage_error)${C_RESET}"
    desbloquear_plantillas
    return 1
  fi
  [[ -n "$contenido" ]] && contenido+=$'\n'
  contenido+="${NOMBRE_PLANTILLA}|${PATRON_PLANTILLA}"$'\n'
  if ! printf '%s' "$contenido" | escritura_atomica "$TEMPLATES_FILE"; then
    echo -e "${C_ERR}${I_ERR} $(t storage_error)${C_RESET}"
    desbloquear_plantillas
    return 1
  fi
  desbloquear_plantillas
  printf '%s%s %s%s\n' "$C_OK" "$I_OK" "$(t template_saved "$(sanear_salida "$NOMBRE_PLANTILLA")")" "$C_RESET"
}

crear_plantilla() {
  local NOMBRE_PLANTILLA PATRON_PLANTILLA
  guardar_plantilla || { pausa; return; }
  pedir_parametros_n "$PATRON_PLANTILLA"
  aplicar_patron "$PATRON_PLANTILLA" "$INICIO_N" "$DIGITOS_N"
}

aplicar_patron_puntual() {
  local patron
  echo -e "${C_DIM}$(t template_hint)${C_RESET}"
  read -rp "${C_PROMPT}$(t pattern_prompt)${C_RESET}" patron
  if [[ -z "$patron" ]]; then
    echo -e "${C_WARN}${I_WARN} $(t empty_pattern)${C_RESET}"; pausa; return
  fi
  avisar_si_ambiguo "$patron"
  pedir_parametros_n "$patron"
  aplicar_patron "$patron" "$INICIO_N" "$DIGITOS_N"
}

listar_plantillas() {
  if [[ ! -s "$TEMPLATES_FILE" ]]; then echo -e "${C_DIM}$(t no_templates)${C_RESET}"; return; fi
  local i=1 n p
  while IFS='|' read -r n p || [[ -n "${n}${p}" ]]; do
    printf '  %s%d)%s %s  %s%s%s  %s\n' "$C_ACCENT" "$i" "$C_RESET" "$(sanear_salida "$n")" "$C_DIM" "$I_ARROW" "$C_RESET" "$(sanear_salida "$p")"
    ((i++))
  done < "$TEMPLATES_FILE"
}

usar_plantilla_guardada() {
  local sel n p r nombres=() patrones=()
  listar_plantillas
  if [[ ! -s "$TEMPLATES_FILE" ]]; then
    read -rp "${C_PROMPT}$(t load_templates_prompt)${C_RESET}" r || return
    respuesta_si "$r" || return 0
    importar_plantillas_desde_archivo
    [[ -s "$TEMPLATES_FILE" ]] || { pausa; return 0; }
    listar_plantillas
  fi
  while IFS='|' read -r n p || [[ -n "${n}${p}" ]]; do nombres+=("$n"); patrones+=("$p"); done < "$TEMPLATES_FILE"
  read -rp "${C_PROMPT}$(t select_template)${C_RESET}" sel
  if sel=$(numero_en_rango "$sel" "${#patrones[@]}"); then
    printf '%s%s%s\n' "$C_DIM" "$(t applying_template "$(sanear_salida "${nombres[$((sel-1))]}")")" "$C_RESET"
    pedir_parametros_n "${patrones[$((sel-1))]}"
    aplicar_patron "${patrones[$((sel-1))]}" "$INICIO_N" "$DIGITOS_N"
  else
    echo -e "${C_WARN}${I_WARN} $(t invalid_option)${C_RESET}"; pausa
  fi
}

guardar_plantilla_sin_aplicar() {
  local NOMBRE_PLANTILLA PATRON_PLANTILLA
  guardar_plantilla
  pausa
}

eliminar_plantilla() {
  listar_plantillas
  if [[ ! -s "$TEMPLATES_FILE" ]]; then pausa; return; fi
  local sel linea nombre_borrado conf resto veredicto=""
  local -a lineas=()
  mapfile -t lineas < "$TEMPLATES_FILE"
  read -rp "${C_PROMPT}$(t delete_template_number)${C_RESET}" sel
  if sel=$(numero_en_rango "$sel" "${#lineas[@]}"); then
    linea="${lineas[sel-1]}"; nombre_borrado="${linea%%|*}"
    read -rp "${C_PROMPT}$(t delete_template_confirm "$(sanear_salida "$nombre_borrado")")${C_RESET}" conf
    if respuesta_si "$conf"; then
      if bloquear_plantillas; then
        # Re-read under the lock: the chosen line must still be the same one.
        if ! mapfile -t lineas < "$TEMPLATES_FILE"; then
          veredicto=error
        elif [[ "${lineas[sel-1]-}" != "$linea" ]]; then
          veredicto=cambio
        else
          unset 'lineas[sel-1]'
          resto=$(printf '%s\n' "${lineas[@]}")
          [[ -n "$resto" ]] && resto+=$'\n'
          printf '%s' "$resto" | escritura_atomica "$TEMPLATES_FILE" || veredicto=error
        fi
        desbloquear_plantillas
      else
        veredicto=error
      fi
      case "$veredicto" in
        error) echo -e "${C_ERR}${I_ERR} $(t storage_error)${C_RESET}" ;;
        cambio) echo -e "${C_WARN}${I_WARN} $(t templates_changed)${C_RESET}" ;;
        *) printf '%s%s %s%s\n' "$C_OK" "$I_OK" "$(t template_deleted "$(sanear_salida "$nombre_borrado")")" "$C_RESET" ;;
      esac
    else
      echo -e "${C_DIM}$(t cancelled)${C_RESET}"
    fi
  else
    echo -e "${C_WARN}${I_WARN} $(t invalid_option)${C_RESET}"
  fi
  pausa
}

exportar_plantillas() {
  if [[ ! -s "$TEMPLATES_FILE" ]]; then echo -e "${C_WARN}${I_WARN} $(t no_templates_export)${C_RESET}"; pausa; return; fi
  local destino
  if [[ "$SELECTOR" == "zenity" ]]; then
    destino=$(zenity --file-selection --save --confirm-overwrite --filename="$(t export_default)" --title="$(t export_title)" 2>/dev/null)
  else
    destino=$(kdialog --getsavefilename "$HOME/$(t export_default)" --title "$(t export_title)" 2>/dev/null)
  fi
  [[ -z "$destino" ]] && { echo -e "${C_WARN}${I_WARN} $(t cancelled)${C_RESET}"; pausa; return; }
  # The config copy is 0600; an exported file gets the usual mode (0666 & ~umask).
  if copia_atomica "$TEMPLATES_FILE" "$destino" "$(printf '%o' $(( 0666 & ~0$(umask) )))"; then
    printf '%s%s %s%s\n' "$C_OK" "$I_OK" "$(t exported "$(sanear_salida "$destino")")" "$C_RESET"
  else
    echo -e "${C_ERR}${I_ERR} $(t export_failed)${C_RESET}"
  fi
  pausa
}

# assets/templates beside the script (repository layout), if it exists.
directorio_plantillas_ejemplo() {
  local ruta
  ruta=$(realpath -e -- "${BASH_SOURCE[0]}" 2>/dev/null) || return 1
  ruta=$(realpath -e -- "${ruta%/*}/../assets/templates" 2>/dev/null) && [[ -d "$ruta" ]] || return 1
  printf '%s' "$ruta"
}

# Picks a templates file (text, at most 1 MiB) and merges it into the store. No
# pauses; fails only if the store cannot be read or written.
importar_plantillas_desde_archivo() {
  local origen tam inicio
  inicio=$(directorio_plantillas_ejemplo)
  if [[ "$SELECTOR" != "zenity" ]]; then
    origen=$(kdialog --getopenfilename "${inicio:-$HOME}" --title "$(t import_title)" 2>/dev/null)
  elif [[ -n "$inicio" ]]; then
    origen=$(zenity --file-selection --filename="$inicio/" --title="$(t import_title)" 2>/dev/null)
  else
    origen=$(zenity --file-selection --title="$(t import_title)" 2>/dev/null)
  fi
  [[ -z "$origen" ]] && { echo -e "${C_WARN}${I_WARN} $(t cancelled)${C_RESET}"; return 0; }
  if [[ ! -f "$origen" ]]; then echo -e "${C_ERR}${I_ERR} $(t file_not_found)${C_RESET}"; return 0; fi
  # A real open: [[ -r ]] can disagree with the kernel (ACLs, LSMs).
  if ! { : < "$origen"; } 2>/dev/null; then echo -e "${C_ERR}${I_ERR} $(t file_unreadable)${C_RESET}"; return 0; fi
  # Text = no NUL bytes. Not "grep -q": it stops at the first match and misses late NULs.
  tam=$(stat -L -c %s -- "$origen" 2>/dev/null)
  if [[ ! "$tam" =~ ^[0-9]+$ ]] || (( tam > 1 << 20 )) || (( $(tr -d '\0' 2>/dev/null < "$origen" | wc -c) != tam )); then
    echo -e "${C_ERR}${I_ERR} $(t import_not_text)${C_RESET}"; return 0
  fi
  local contenido='' linea n p importadas=0 duplicadas=0 invalidas=0
  local -A existentes=()
  local -a nuevas=()
  if ! bloquear_plantillas; then
    echo -e "${C_ERR}${I_ERR} $(t storage_error)${C_RESET}"
    return 1
  fi
  if [[ -f "$TEMPLATES_FILE" ]] && ! contenido=$(cat -- "$TEMPLATES_FILE"); then
    echo -e "${C_ERR}${I_ERR} $(t storage_error)${C_RESET}"
    desbloquear_plantillas
    return 1
  fi
  while IFS='|' read -r n p || [[ -n "${n}${p}" ]]; do
    [[ -n "$n" ]] && existentes["$n"]=1
  done <<< "$contenido"
  while IFS= read -r linea || [[ -n "$linea" ]]; do
    linea=${linea#$'\xEF\xBB\xBF'}; linea=${linea%$'\r'}  # UTF-8 BOM, CRLF (Notepad)
    [[ -z "${linea//[[:space:]]/}" ]] && continue
    IFS='|' read -r n p <<< "$linea"
    read -r n <<< "$n"; read -r p <<< "${p//|/}"
    if [[ -z "$n" || -z "$p" ]]; then ((invalidas++)); continue; fi
    if [[ -n "${existentes[$n]:-}" ]]; then ((duplicadas++)); continue; fi
    nuevas+=("$n|$p")
    existentes["$n"]=1
    ((importadas++))
  done < "$origen"
  if (( importadas > 0 )); then
    [[ -n "$contenido" ]] && contenido+=$'\n'
    for linea in "${nuevas[@]}"; do contenido+="$linea"$'\n'; done
    if ! printf '%s' "$contenido" | escritura_atomica "$TEMPLATES_FILE"; then
      echo -e "${C_ERR}${I_ERR} $(t storage_error)${C_RESET}"
      desbloquear_plantillas
      return 1
    fi
  fi
  desbloquear_plantillas
  if (( importadas + duplicadas > 0 )); then
    echo -e "${C_OK}${I_OK} $(t imported "$importadas" "$duplicadas" "$invalidas")${C_RESET}"
  else
    echo -e "${C_WARN}${I_WARN} $(t import_none "$invalidas")${C_RESET}"
  fi
}

importar_plantillas() {
  local rc=0
  importar_plantillas_desde_archivo || rc=$?
  pausa
  return "$rc"
}

gestionar_plantillas() {
  while true; do
    limpiar_pantalla
    titulo "$(t templates_title)" "$(t templates_subtitle)"
    echo
    opt 1 "📋" "$(t templates_list)"
    opt 2 "✨" "$(t templates_create)"
    opt 3 "🗑️" "$(t templates_delete)"
    opt 4 "📤" "$(t templates_export)"
    opt 5 "📥" "$(t templates_import)"
    opt i "🌐" "$(etiqueta_cambio_idioma)"
    opt 0 "↩️" "$(t back)"
    echo
    read -rp "${C_PROMPT}$(t option_prompt)${C_RESET}" op || return
    case "$op" in
      1) listar_plantillas; pausa ;;
      2) guardar_plantilla_sin_aplicar ;;
      3) eliminar_plantilla ;;
      4) exportar_plantillas ;;
      5) importar_plantillas ;;
      i|I) cambiar_idioma ;;
      0) return ;;
      *) echo -e "${C_WARN}${I_WARN} $(t invalid_option)${C_RESET}"; pausa ;;
    esac
  done
}

# ---- Command-line mode (without menus) ----
# For Nemo, Cinnamon shortcuts or scripts, without the graphical selectors.

error_cli() { printf '%s%s %s%s\n' "$C_ERR" "$I_ERR" "$(sanear_salida "$1")" "$C_RESET" >&2; exit 1; }

realpath_en_var() {
  local __var="$1" ruta="$2" valor
  shift 2
  IFS= read -r -d '' valor < <(realpath -z "$@" -- "$ruta" 2>/dev/null) || return 1
  printf -v "$__var" '%s' "$valor"
}

autenticar_origen_ruta() {
  local ruta="$1" real
  [[ "$ruta" != "/" ]] || return 1
  [[ -L "$ruta" && ! -e "$ruta" ]] && return 0  # dangling link: the link itself is the item
  realpath_en_var real "$ruta" -e || return 1
  [[ "$real" != "/" ]]
}

# FILES = the normalized paths in "$@", each entry once: the same real directory
# plus name ("a.txt", "./a.txt", "$PWD/a.txt") counts as one item.
fijar_origenes_unicos() {
  local ruta dir clave
  local -A dirs_reales=() vistos=()
  FILES=()
  for ruta in "$@"; do
    dir="${ruta%/*}"; dir="${dir:-/}"
    if [[ -z "${dirs_reales[$dir]+x}" ]]; then
      realpath_en_var clave "$dir" -e || clave="$dir"
      dirs_reales[$dir]="$clave"
    fi
    clave="${dirs_reales[$dir]}/${ruta##*/}"
    [[ -n "${vistos[$clave]:-}" ]] && continue
    vistos[$clave]=1
    FILES+=("$ruta")
  done
}

mostrar_version() { echo "Renombrador $VERSION"; }

mostrar_ayuda_cli() {
  if [[ "$APP_LANG" == "en" ]]; then
    cat <<'EOF'
Usage:
  renombrador.sh --carpeta PATH [selection...] --metodo NAME [parameters...] [application...]
  renombrador.sh --archivo PATH [--archivo PATH ...] --metodo NAME [parameters...] [application...]

Source (one of the two):
  --carpeta PATH            Folder to process
  --archivo PATH            One item to include (repeatable)

Selection (only with --carpeta):
  --recursivo               Include subfolders
  --ocultos                 Include hidden files and folders
  --incluir-carpetas        Include folders as renameable items
  --seguir-enlaces          Follow symbolic links
  --filtro ext1,ext2        Filter by extension

Methods (--metodo NAME) and parameters:
  numeracion    --base TEXT | --mantener-nombre  [--inicio N] [--digitos N]
                [--orden actual|fecha|exif|tamano]
  prefijo       --prefijo TEXT
  sufijo        --sufijo TEXT
  buscar-reemplazar  --buscar TEXT --reemplazar TEXT [--regex]
  mayus-minus   --caso minusculas|mayusculas|capitalizar|frase
  fecha         [--fecha-origen actual|modificacion|exif] [--fecha-pos inicio|final]
  limpiar       [--espacios guion_bajo|guion|eliminar]
  tipo          (no extra parameters)
  plantilla     --plantilla NAME  [--inicio N] [--digitos N]
  patron        --patron '{date}_{name}_{n}'  [--inicio N] [--digitos N]

  --inicio N    First number in the series (default: 1)
  --digitos N   Padding zeros to match number length
                (default: automatic in 'numeracion'; no padding in 'plantilla'/'patron')

Applying changes:
  --modo mover|copiar                     (default: mover)
  --conflicto sufijo|sobrescribir|omitir  (default: sufijo)
  --dry-run                               Preview only, no changes
  --sin-confirmar                         Do not ask for confirmation (use with care)

Language:
  --lang es|en                            Interface language for this run (not saved)

Nemo integration (must be the first argument; --lang may follow):
  --instalar-nemo | --desinstalar-nemo    Add / remove the "Rename with Renombrador..." action
  --activar-nemo | --desactivar-nemo      Enable / disable it without removing it

Examples:
  renombrador.sh --carpeta ~/Photos --recursivo --metodo fecha --fecha-origen exif --dry-run
  renombrador.sh --carpeta ~/Downloads --metodo prefijo --prefijo "2026_" --sin-confirmar
EOF
  else
    cat <<'EOF'
Uso:
  renombrador.sh --carpeta RUTA [selección...] --metodo NOMBRE [parámetros...] [aplicación...]
  renombrador.sh --archivo RUTA [--archivo RUTA ...] --metodo NOMBRE [parámetros...] [aplicación...]

Origen (uno de los dos):
  --carpeta RUTA           Carpeta a procesar
  --archivo RUTA           Un elemento a incluir (repetible)

Selección (solo con --carpeta):
  --recursivo              Incluir subcarpetas
  --ocultos                Incluir archivos y carpetas ocultas
  --incluir-carpetas       Incluir también las carpetas como elementos a renombrar
  --seguir-enlaces         Seguir enlaces simbólicos
  --filtro ext1,ext2       Filtrar por extensión

Métodos (--metodo NOMBRE) y sus parámetros:
  numeracion    --base TEXTO | --mantener-nombre  [--inicio N] [--digitos N]
                [--orden actual|fecha|exif|tamano]
  prefijo       --prefijo TEXTO
  sufijo        --sufijo TEXTO
  buscar-reemplazar  --buscar TEXTO --reemplazar TEXTO [--regex]
  mayus-minus   --caso minusculas|mayusculas|capitalizar|frase
  fecha         [--fecha-origen actual|modificacion|exif] [--fecha-pos inicio|final]
  limpiar       [--espacios guion_bajo|guion|eliminar]
  tipo          (sin parámetros extra)
  plantilla     --plantilla NOMBRE  [--inicio N] [--digitos N]
  patron        --patron '{date}_{name}_{n}'  [--inicio N] [--digitos N]

  --inicio N    Primer número de la serie (por defecto: 1)
  --digitos N   Ceros de relleno para igualar el largo de los números
                (por defecto: automático en 'numeracion'; sin relleno en 'plantilla'/'patron')

Aplicación de cambios:
  --modo mover|copiar                     (por defecto: mover)
  --conflicto sufijo|sobrescribir|omitir  (por defecto: sufijo)
  --dry-run                               Solo vista previa, no cambia nada
  --sin-confirmar                         No pedir confirmación (úsalo con cuidado)

Idioma:
  --lang es|en                            Idioma de esta ejecución (no se guarda)

Integración con Nemo (debe ir como primer argumento; --lang puede seguirlo):
  --instalar-nemo | --desinstalar-nemo    Añadir / quitar la acción «Renombrar con Renombrador...»
  --activar-nemo | --desactivar-nemo      Activarla / desactivarla sin quitarla

Ejemplos:
  renombrador.sh --carpeta ~/Fotos --recursivo --metodo fecha --fecha-origen exif --dry-run
  renombrador.sh --carpeta ~/Descargas --metodo prefijo --prefijo "2026_" --sin-confirmar
EOF
  fi
}

modo_cli() {
  CLI_MODE=1
  local carpeta="" archivos_cli=() recursivo="n" ocultos="n" incluir_carpetas="n" seguir_enlaces="n" filtro=""
  local ruta_normalizada
  local metodo="" base="" mantener=0 inicio=1 digitos="" orden_criterio="actual"
  local prefijo="" sufijo="" buscar="" reemplazar="" regex=0
  local caso="" fecha_origen="actual" fecha_pos="final" espacios="guion_bajo"
  local plantilla_nombre="" patron="" modo_flag="mover" conflicto_flag="sufijo"

  while (( $# > 0 )); do
    [[ "$OPCIONES_CON_VALOR" == *" $1 "* ]] && (( $# < 2 )) && error_cli "$(t cli_need_value "$1")"
    case "$1" in
      --carpeta) carpeta="$2"; shift 2 ;;
      --archivo) archivos_cli+=("$2"); shift 2 ;;
      --recursivo) recursivo="s"; shift ;;
      --ocultos) ocultos="s"; shift ;;
      --incluir-carpetas) incluir_carpetas="s"; shift ;;
      --seguir-enlaces) seguir_enlaces="s"; shift ;;
      --filtro) filtro="$2"; shift 2 ;;
      --metodo) metodo="$2"; shift 2 ;;
      --base) base="$2"; shift 2 ;;
      --mantener-nombre) mantener=1; shift ;;
      --inicio) inicio="$2"; shift 2 ;;
      --digitos) digitos="$2"; shift 2 ;;
      --orden) orden_criterio="$2"; shift 2 ;;
      --prefijo) prefijo="$2"; shift 2 ;;
      --sufijo) sufijo="$2"; shift 2 ;;
      --buscar) buscar="$2"; shift 2 ;;
      --reemplazar) reemplazar="$2"; shift 2 ;;
      --regex) regex=1; shift ;;
      --caso) caso="$2"; shift 2 ;;
      --fecha-origen) fecha_origen="$2"; shift 2 ;;
      --fecha-pos) fecha_pos="$2"; shift 2 ;;
      --espacios) espacios="$2"; shift 2 ;;
      --plantilla) plantilla_nombre="$2"; shift 2 ;;
      --patron) patron="$2"; shift 2 ;;
      --modo) modo_flag="$2"; shift 2 ;;
      --conflicto) conflicto_flag="$2"; shift 2 ;;
      --lang) establecer_idioma "$2" || exit 2; shift 2 ;;
      --dry-run) CLI_DRY_RUN=1; shift ;;
      --sin-confirmar) CLI_SIN_CONFIRMAR=1; shift ;;
      --ayuda|--help|-h) mostrar_ayuda_cli; exit 0 ;;
      --version|-v) mostrar_version; exit 0 ;;
      *) error_cli "$(t cli_unknown_arg "$1")" ;;
    esac
  done

  case "$modo_flag" in
    mover) CLI_MODO="mover" ;;
    copiar) CLI_MODO="copiar" ;;
    *) error_cli "$(t cli_mode_invalid "$modo_flag")" ;;
  esac
  case "$conflicto_flag" in
    sufijo) CLI_CONFLICTO=1 ;;
    sobrescribir) CLI_CONFLICTO=2 ;;
    omitir) CLI_CONFLICTO=3 ;;
    *) error_cli "$(t cli_conflict_invalid "$conflicto_flag")" ;;
  esac
  [[ "$inicio" =~ ^[0-9]+$ ]] || error_cli "$(t cli_start_invalid "$inicio")"
  inicio=$(normalizar_decimal "$inicio")
  en_rango_decimal "$inicio" 9000000000000000000 || error_cli "$(t cli_start_invalid "$inicio")"
  [[ -z "$digitos" || "$digitos" =~ ^[0-9]+$ ]] || error_cli "$(t cli_digits_invalid "$digitos")"
  if [[ -n "$digitos" ]]; then
    digitos=$(normalizar_decimal "$digitos")
    en_rango_decimal "$digitos" 18 || error_cli "$(t cli_digits_invalid "$digitos")"
  fi

  if [[ -n "$carpeta" && ${#archivos_cli[@]} -gt 0 ]]; then
    error_cli "$(t cli_both_source)"
  elif [[ -n "$carpeta" ]]; then
    [[ "$carpeta" == \~ || "$carpeta" == \~/* ]] && carpeta="$HOME${carpeta:1}"
    [[ -d "$carpeta" ]] || error_cli "$(t cli_folder_missing "$carpeta")"
    autenticar_origen_ruta "$carpeta" || error_cli "$(t cli_unsafe_source "$carpeta")"
    filtro="${filtro// /}"; filtro="${filtro//./}"
    filtro=$(sed -E 's/,+/,/g; s/^,//; s/,$//' <<< "$filtro")
    construir_lista_desde_carpeta "$carpeta" "$recursivo" "$filtro" "$ocultos" "$incluir_carpetas" "$seguir_enlaces"
  elif (( ${#archivos_cli[@]} > 0 )); then
    local a
    local -a candidatos=()
    for a in "${archivos_cli[@]}"; do
      [[ "$a" == \~ || "$a" == \~/* ]] && a="$HOME${a:1}"
      if [[ -e "$a" || -L "$a" ]]; then
        autenticar_origen_ruta "$a" || error_cli "$(t cli_unsafe_source "$a")"
        normalizar_ruta "$a" ruta_normalizada
        candidatos+=("$ruta_normalizada")
      else printf '%s%s %s%s\n' "$C_WARN" "$I_WARN" "$(t cli_item_missing "$(sanear_salida "$a")")" "$C_RESET" >&2; fi
    done
    fijar_origenes_unicos "${candidatos[@]}"
  else
    error_cli "$(t cli_no_source)"
  fi
  (( ${#FILES[@]} == 0 )) && error_cli "$(t cli_none)"
  (( ${#FILES[@]} > 2000 )) && echo -e "${C_WARN}${I_WARN} $(t cli_large "${#FILES[@]}")${C_RESET}" >&2
  echo -e "${C_OK}${I_OK} $(t cli_found "${#FILES[@]}")${C_RESET}"

  reiniciar_cola
  local i op pos sep modo_br delim err
  case "$metodo" in
    numeracion)
      local modo_num=1; (( mantener )) && modo_num=2
      (( modo_num == 1 )) && [[ -z "$base" ]] && error_cli "$(t cli_numbering_need_base)"
      [[ -z "$digitos" ]] && { digitos=${#FILES[@]}; digitos=${#digitos}; }
      local -a orden_idx=()
      case "$orden_criterio" in
        actual) orden_idx=("${!FILES[@]}") ;;
        fecha) mapfile -t orden_idx < <(orden_indices_por_criterio fecha) ;;
        exif) comprobar_herramientas_exif; mapfile -t orden_idx < <(orden_indices_por_criterio exif) ;;
        tamano) mapfile -t orden_idx < <(orden_indices_por_criterio tamano) ;;
        *) error_cli "$(t cli_order_invalid "$orden_criterio")" ;;
      esac
      transformar_numeracion "$modo_num" "$base" "$inicio" "$digitos" "${orden_idx[*]}"
      ;;
    prefijo) transformar_prefijo "$prefijo" ;;
    sufijo) transformar_sufijo "$sufijo" ;;
    buscar-reemplazar)
      [[ -z "$buscar" ]] && error_cli "$(t cli_replace_need_search)"
      modo_br=1; (( regex )) && modo_br=2
      if (( regex )); then
        delim=$(delimitador_para "$buscar" "$reemplazar")
        err=$(validar_regex "$buscar" "$reemplazar" "$delim")
        [[ -n "$err" ]] && error_cli "$(t cli_regex_invalid "$err")"
      fi
      transformar_buscar_reemplazar "$modo_br" "$buscar" "$reemplazar"
      ;;
    mayus-minus)
      case "$caso" in
        minusculas) op=1 ;; mayusculas) op=2 ;; capitalizar) op=3 ;; frase) op=4 ;;
        *) error_cli "$(t cli_case_invalid "$caso")" ;;
      esac
      transformar_mayus_minus "$op"
      ;;
    fecha)
      case "$fecha_origen" in
        actual) op=1 ;; modificacion) op=2 ;; exif) op=3; comprobar_herramientas_exif ;;
        *) error_cli "$(t cli_date_source_invalid "$fecha_origen")" ;;
      esac
      case "$fecha_pos" in
        inicio) pos=1 ;; final) pos=2 ;;
        *) error_cli "$(t cli_date_pos_invalid "$fecha_pos")" ;;
      esac
      transformar_fecha "$op" "$pos"
      ;;
    limpiar)
      case "$espacios" in
        guion_bajo) sep="_" ;; guion) sep="-" ;; eliminar) sep="" ;;
        *) error_cli "$(t cli_spaces_invalid "$espacios")" ;;
      esac
      transformar_limpiar "$sep"
      ;;
    tipo) metodo_por_tipo ;;
    plantilla)
      [[ -z "$plantilla_nombre" ]] && error_cli "$(t cli_template_need)"
      local n p encontrado=""
      while IFS='|' read -r n p || [[ -n "${n}${p}" ]]; do [[ "$n" == "$plantilla_nombre" ]] && { encontrado="$p"; break; }; done < "$TEMPLATES_FILE"
      [[ -z "$encontrado" ]] && error_cli "$(t cli_template_missing "$plantilla_nombre")"
      aplicar_patron "$encontrado" "$inicio" "${digitos:-0}"
      ;;
    patron)
      [[ -z "$patron" ]] && error_cli "$(t cli_pattern_need)"
      aplicar_patron "$patron" "$inicio" "${digitos:-0}"
      ;;
    "") error_cli "$(t cli_method_need)" ;;
    *) error_cli "$(t cli_method_unknown "$metodo")" ;;
  esac

  NUEVOS=("${NOMBRES_COLA[@]}")
  aplicar_renombrado || exit 1
}

establecer_idioma_desde_args() {
  local args=("$@") i=0 arg
  while (( i < ${#args[@]} )); do
    arg="${args[$i]}"
    case "$arg" in
      --lang)
        (( i + 1 < ${#args[@]} )) || { echo -e "${C_ERR}${I_ERR} $(t cli_need_value "--lang")${C_RESET}" >&2; return 1; }
        establecer_idioma "${args[$((i+1))]}" || return 1
        ((i+=2))
        ;;
      *) if [[ "$OPCIONES_CON_VALOR" == *" $arg "* ]]; then ((i+=2)); else ((i+=1)); fi ;;
    esac
  done
}

main() {
  local a ruta_normalizada n_plantillas n_lotes deshacer_info nemo_label opcion despedida
  establecer_idioma_desde_args "$@" || exit 2

case "${1:-}" in
  --instalar-nemo) instalar_nemo || exit 1; exit 0 ;;
  --desinstalar-nemo) desinstalar_nemo || exit 1; exit 0 ;;
  --activar-nemo) activar_nemo || exit 1; exit 0 ;;
  --desactivar-nemo) desactivar_nemo || exit 1; exit 0 ;;
  --ayuda|--help|-h) mostrar_ayuda_cli; exit 0 ;;
  --version|-v) mostrar_version; exit 0 ;;
esac

if [[ "${1:-}" == --* ]]; then
  modo_cli "$@"
  exit 0
fi

comprobar_dependencias

if (( $# > 0 )); then
  local -a candidatos=()
  for a in "$@"; do
    if [[ -e "$a" || -L "$a" ]]; then
      autenticar_origen_ruta "$a" || continue
      normalizar_ruta "$a" ruta_normalizada
      candidatos+=("$ruta_normalizada")
    fi
  done
  fijar_origenes_unicos "${candidatos[@]}"
  if (( ${#FILES[@]} == 0 )); then
    echo -e "${C_ERR}${I_ERR} $(t none_found)${C_RESET}"; pausa
  else
    limpiar_pantalla
    titulo "R E N O M B R A D O R" "$(t received "${#FILES[@]}")"
    echo -e "${C_OK}${I_OK} $(t ready)${C_RESET}"
    menu_metodos
  fi
fi

while true; do
  limpiar_pantalla
  titulo "R E N O M B R A D O R" "$(t main_subtitle)"
  echo
  n_plantillas=0
  [[ -s "$TEMPLATES_FILE" ]] && n_plantillas=$(grep -c '' "$TEMPLATES_FILE")
  n_lotes=$(nombres_lotes | wc -l)
  deshacer_info=""
  (( n_lotes > 0 )) && deshacer_info="  ${C_DIM}(${n_lotes})${C_RESET}"
  nemo_label="$(t main_nemo_add)"
  [[ -f "$NEMO_ACTION" ]] && nemo_label="$(t main_nemo_remove)"
  opt 1 "📁" "$(t main_folder)"
  opt 2 "🗂" "$(t main_files)"
  opt 3 "🧩" "$(t main_templates)  ${C_DIM}(${n_plantillas})${C_RESET}"
  opt 4 "↩️" "$(t main_undo)${deshacer_info}"
  opt 5 "🧩" "$nemo_label"
  opt i "🌐" "$(etiqueta_cambio_idioma)"
  opt 6 "🚪" "$(t main_exit)"
  echo
  read -rp "${C_PROMPT}$(t option_prompt)${C_RESET}" opcion || exit 0
  case "$opcion" in
    1) opcion_carpeta ;;
    2) opcion_archivos ;;
    3) gestionar_plantillas ;;
    4) deshacer_ultimo ;;
    5) if [[ -f "$NEMO_ACTION" ]]; then gestionar_nemo; else instalar_nemo; fi; pausa ;;
    i|I) cambiar_idioma ;;
    6) despedida="👋"; (( SIN_EMOJI )) && despedida="•"
       echo -e "${C_OK}${despedida} $(t goodbye)${C_RESET}"; exit 0 ;;
    *) echo -e "${C_WARN}${I_WARN} $(t invalid_option)${C_RESET}"; pausa ;;
  esac
done
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
