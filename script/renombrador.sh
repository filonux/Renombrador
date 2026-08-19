#!/usr/bin/env bash
# Renombrador - selector gráfico + renombrado por plantillas para Nemo/Cinnamon
# Copyright (C) 2026 Filonux - Licencia GPLv3 (ver LICENSE)

VERSION="1.0.0"
CONFIG_DIR="$HOME/.config/renombrador"
TEMPLATES_FILE="$CONFIG_DIR/plantillas.conf"
HISTORY_DIR="$CONFIG_DIR/historial"
MAX_HISTORIAL=20
LOG_SEP=$'\x1f'  # separador de campos en el log de deshacer; nunca aparece en un nombre de archivo real (a diferencia de '|')
NEMO_DIR="$HOME/.local/share/nemo/actions"
NEMO_ACTION="$NEMO_DIR/renombrador.nemo_action"
APP_DIR="$HOME/.local/share/renombrador"
APP_SCRIPT="$APP_DIR/renombrador.sh"
APP_ICON="$APP_DIR/icono.svg"
mkdir -p "$CONFIG_DIR" "$HISTORY_DIR"
touch "$TEMPLATES_FILE"

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

# Soporte de emoji: se degradan a una viñeta simple si el locale no es UTF-8
# (TTY basica, C/POSIX, SSH sin locale) o si es la consola virtual de Linux
# (TERM=linux), cuya fuente por defecto no trae glifos de emoji aunque el
# texto UTF-8 se decodifique bien.
SIN_EMOJI=0
_loc="${LC_ALL:-${LC_CTYPE:-${LANG:-}}}"
if [[ "${_loc^^}" != *UTF-8* && "${_loc^^}" != *UTF8* ]]; then
  SIN_EMOJI=1
elif [[ "${TERM:-}" == "linux" ]]; then
  SIN_EMOJI=1
fi
unset _loc

# Simbolos de estado (fuera de los iconos de menu, que ya maneja opt()). Se
# degradan con el mismo criterio SIN_EMOJI: en TTY/SSH basica o consola sin
# fuente Unicode completa, "check/cruz/alerta/flecha" pueden verse como
# cuadros vacios igual que los emoji, asi que siguen la misma regla.
if (( SIN_EMOJI )); then
  I_OK='OK:'; I_ERR='ERROR:'; I_WARN='AVISO:'; I_ARROW='->'
else
  I_OK='✔'; I_ERR='✖'; I_WARN='⚠'; I_ARROW='→'
fi

FILES=()
NUEVOS=()
SELECTOR=""
NOMBRES_COLA=()
PASOS_COLA=()
HISTORIAL_COLA=()
EXIFTOOL_DISPONIBLE=""
IDENTIFY_DISPONIBLE=""
EXIF_CHEQUEADO=""
CLI_MODE=0
CLI_MODO=""
CLI_CONFLICTO=""
CLI_DRY_RUN=0
CLI_SIN_CONFIRMAR=0

pausa() { (( CLI_MODE )) && return; echo; read -rp "${C_DIM}Pulsa Enter para continuar...${C_RESET}" _; }

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

instalar_icono() {
  mkdir -p "$APP_DIR"
  cat > "$APP_ICON" <<'EOF'
<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" viewBox="0 0 256 256"><defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#22D3EE"/><stop offset="1" stop-color="#D946EF"/></linearGradient><path id="p" d="M12,0 L84,0 L104,20 L104,122 Q104,134 92,134 L12,134 Q0,134 0,122 L0,12 Q0,0 12,0 Z"/><path id="f" d="M84,0 L104,20 L84,20 Z"/></defs><ellipse cx="128" cy="222" rx="70" ry="9" fill="#000" opacity=".12"/><g transform="rotate(-16 128 194) translate(76 60)"><use xlink:href="#p" fill="#E4D4FF" stroke="#C7A6F5" stroke-width="2"/><use xlink:href="#f" fill="#B79AE0"/></g><g transform="rotate(-4 128 194) translate(76 60)"><use xlink:href="#p" fill="#CFF3FF" stroke="#7FD9F0" stroke-width="2"/><use xlink:href="#f" fill="#9FE0F3"/></g><g transform="rotate(9 128 194) translate(76 60)"><use xlink:href="#p" fill="#FFFFFF" stroke="url(#g)" stroke-width="2.5"/><use xlink:href="#f" fill="#E7E7EE"/><rect x="16" y="96" width="56" height="12" rx="6" fill="url(#g)"/><rect x="76" y="96" width="3" height="12" fill="#334155" opacity=".6"/></g><g transform="translate(196 196)"><circle r="34" fill="url(#g)"/><g transform="rotate(-45)"><rect x="-24" y="-3" width="6" height="6" fill="#334155"/><rect x="-19" y="-4" width="32" height="8" rx="4" fill="#fff"/><path d="M13,-4 L24,0 L13,4 Z" fill="#FFD75F"/></g><path d="M18,-19 L20,-14 L25,-12 L20,-10 L18,-5 L16,-10 L11,-12 L16,-14 Z" fill="#fff" opacity=".9"/></g></svg>
EOF
}

instalar_nemo() {
  mkdir -p "$NEMO_DIR" "$APP_DIR"
  instalar_icono
  local origen; origen="$(readlink -f "${BASH_SOURCE[0]}")"
  [[ "$origen" != "$APP_SCRIPT" ]] && cp -f -- "$origen" "$APP_SCRIPT"
  chmod +x "$APP_SCRIPT"
  cat > "$NEMO_ACTION" <<EOF
[Nemo Action]
Active=true
Name=Renombrar con Renombrador...
Comment=Renombra los archivos o carpetas seleccionadas
Exec=$APP_SCRIPT %F
Icon-Name=$APP_ICON
Selection=notnone
Extensions=any;
Terminal=true
EOF
  nemo -q &>/dev/null &
  echo -e "${C_OK}${I_OK} Integrado en Nemo.${C_RESET} Clic derecho sobre archivos ${I_ARROW} «Renombrar con Renombrador...»"
  echo -e "${C_DIM}Si no aparece de inmediato, cierra y vuelve a abrir Nemo.${C_RESET}"
}

desinstalar_nemo() {
  rm -f "$NEMO_ACTION"
  nemo -q &>/dev/null &
  echo -e "${C_OK}${I_OK} Acción de Nemo eliminada.${C_RESET}"
}

comprobar_dependencias() {
  if command -v zenity &>/dev/null; then
    SELECTOR="zenity"; return
  elif command -v kdialog &>/dev/null; then
    SELECTOR="kdialog"; return
  fi
  echo -e "${C_WARN}${I_WARN} No se encontró 'zenity' ni 'kdialog' (selector gráfico de archivos).${C_RESET}"
  read -rp "${C_PROMPT}¿Instalar zenity ahora? (s/n): ${C_RESET}" r
  if [[ ! "$r" =~ ^[sS]$ ]]; then
    echo -e "${C_ERR}${I_ERR} No se puede continuar sin un selector gráfico.${C_RESET}"; exit 1
  fi
  if command -v apt &>/dev/null; then sudo apt update && sudo apt install -y zenity
  elif command -v dnf &>/dev/null; then sudo dnf install -y zenity
  elif command -v pacman &>/dev/null; then sudo pacman -S --noconfirm zenity
  elif command -v zypper &>/dev/null; then sudo zypper install -y zenity
  else
    echo -e "${C_ERR}${I_ERR} Gestor de paquetes no reconocido. Instala zenity manualmente.${C_RESET}"; exit 1
  fi
  if command -v zenity &>/dev/null; then
    SELECTOR="zenity"
  else
    echo -e "${C_ERR}${I_ERR} No se pudo instalar zenity.${C_RESET}"; exit 1
  fi
}

# Garantiza que la ruta tenga un componente de directorio (con "/"), para que
# "${ruta%/*}" nunca devuelva la propia ruta en vez de su carpeta contenedora.
normalizar_ruta() {
  local r="$1"
  [[ "$r" == */* ]] || r="./$r"
  printf '%s' "$r"
}

separar_nombre_ext() {
  local base="$1"
  if [[ "$base" == .* && "$base" != *.*.* ]]; then
    printf '%s%s%s' "$base" "$LOG_SEP" ""
  elif [[ "$base" == *.* ]]; then
    printf '%s%s%s' "${base%.*}" "$LOG_SEP" "${base##*.}"
  else
    printf '%s%s%s' "$base" "$LOG_SEP" ""
  fi
}

# ---- Fecha EXIF real (fotos) ----

comprobar_herramientas_exif() {
  [[ -n "$EXIF_CHEQUEADO" ]] && return
  command -v exiftool &>/dev/null && EXIFTOOL_DISPONIBLE=1
  command -v identify &>/dev/null && IDENTIFY_DISPONIBLE=1
  EXIF_CHEQUEADO=1
}

# Fecha/hora EXIF original en "YYYY-MM-DD HH:MM:SS" (vacio si no se pudo leer)
fecha_exif_raw() {
  local archivo="$1" f=""
  comprobar_herramientas_exif
  if [[ -n "$EXIFTOOL_DISPONIBLE" ]]; then
    f=$(exiftool -DateTimeOriginal -CreateDate -s3 -- "$archivo" 2>/dev/null | head -n1)
  fi
  if [[ -z "$f" && -n "$IDENTIFY_DISPONIBLE" ]]; then
    f=$(identify -format '%[EXIF:DateTimeOriginal]\n' -- "$archivo" 2>/dev/null | head -n1)
  fi
  [[ "$f" =~ ^([0-9]{4}):([0-9]{2}):([0-9]{2})[\ T]([0-9]{2}:[0-9]{2}:[0-9]{2}) ]] && printf '%s-%s-%s %s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" "${BASH_REMATCH[4]}"
}

# Fecha (YYYY-MM-DD) de una foto por EXIF; si no es foto, no hay EXIF, o el EXIF
# es invalido (p.ej. el placeholder "0000:00:00" de camaras sin reloj), usa la
# fecha de modificacion.
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

# Igual que fecha_foto pero en epoch, para ordenar cronologicamente
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

# ---- Seleccion de archivos ----

seleccionar_carpeta() {
  if [[ "$SELECTOR" == "zenity" ]]; then
    zenity --file-selection --directory --title="Selecciona una carpeta" 2>/dev/null
  else
    kdialog --getexistingdirectory "$HOME" --title "Selecciona una carpeta" 2>/dev/null
  fi
}

seleccionar_archivos() {
  if [[ "$SELECTOR" == "zenity" ]]; then
    zenity --file-selection --multiple --separator=$'\x1f' --title="Selecciona archivos" 2>/dev/null
  else
    kdialog --getopenfilename "$HOME" --multiple --separate-output 2>/dev/null | paste -sd$'\x1f' -
  fi
}

construir_lista_desde_carpeta() {
  local carpeta="$1" recursivo="$2" filtro="$3" ocultos="$4" incluir_carpetas="${5:-n}" seguir_enlaces="${6:-n}"
  FILES=()
  local prof=(-maxdepth 1)
  [[ "$recursivo" == "s" ]] && prof=()
  local flags=()
  [[ "$seguir_enlaces" == "s" ]] && flags=(-L)
  # Se pide siempre el tipo "l": sin seguir enlaces es el propio enlace (en vez de
  # ignorarlo en silencio); siguiendo enlaces cubre los que queden rotos, que -L
  # no puede resolver a f/d y de otro modo volverian a desaparecer sin avisar.
  local tipos="f,l"
  [[ "$incluir_carpetas" == "s" ]] && tipos+=",d"
  local relpath archivo ext real
  local -A vistos_real=()
  while IFS= read -r -d '' relpath; do
    relpath="${relpath#./}"
    if [[ "$ocultos" != "s" ]] && [[ "$relpath" == .* || "$relpath" == */.* ]]; then
      continue
    fi
    archivo="$carpeta/$relpath"
    if [[ "$seguir_enlaces" == "s" ]]; then
      # Un enlace a una carpeta dentro del propio arbol listaria los mismos
      # archivos dos veces (por su ruta real y por el enlace); se descarta el
      # duplicado comparando la ruta canonica. Los enlaces rotos no resuelven
      # ruta real, asi que no se filtran por aqui y siempre se incluyen.
      real=$(realpath -e -- "$archivo" 2>/dev/null)
      if [[ -n "$real" ]]; then
        [[ -n "${vistos_real[$real]:-}" ]] && continue
        vistos_real[$real]=1
      fi
    fi
    if [[ -n "$filtro" && ! -d "$archivo" ]]; then
      IFS="$LOG_SEP" read -r _ ext <<< "$(separar_nombre_ext "$(basename "$archivo")")"
      ext="${ext,,}"
      [[ ",${filtro,,}," == *",${ext},"* ]] && FILES+=("$archivo")
    else
      FILES+=("$archivo")
    fi
  done < <(cd "$carpeta" && find "${flags[@]}" . -mindepth 1 "${prof[@]}" -type "$tipos" -print0 | sort -z -V)
}

opcion_carpeta() {
  local carpeta recursivo filtro ocultos incluir_carpetas seguir_enlaces
  carpeta=$(seleccionar_carpeta)
  [[ -z "$carpeta" ]] && { echo -e "${C_WARN}${I_WARN} Cancelado.${C_RESET}"; pausa; return; }
  read -rp "${C_PROMPT}¿Incluir subcarpetas? (s/n) [n]: ${C_RESET}" recursivo; recursivo=${recursivo:-n}
  read -rp "${C_PROMPT}¿Incluir archivos y carpetas ocultas? (s/n) [n]: ${C_RESET}" ocultos; ocultos=${ocultos:-n}
  read -rp "${C_PROMPT}¿Incluir también las carpetas como elementos a renombrar? (s/n) [n]: ${C_RESET}" incluir_carpetas; incluir_carpetas=${incluir_carpetas:-n}
  read -rp "${C_PROMPT}¿Seguir enlaces simbólicos al buscar? (s/n) [n]: ${C_RESET}" seguir_enlaces; seguir_enlaces=${seguir_enlaces:-n}
  read -rp "${C_PROMPT}Filtrar por extensión, ej: jpg,png [Enter = todas]: ${C_RESET}" filtro
  filtro="${filtro// /}"; filtro="${filtro//./}"
  filtro=$(sed -E 's/,+/,/g; s/^,//; s/,$//' <<< "$filtro")
  construir_lista_desde_carpeta "$carpeta" "$recursivo" "$filtro" "$ocultos" "$incluir_carpetas" "$seguir_enlaces"
  if [[ ${#FILES[@]} -eq 0 ]]; then
    echo -e "${C_WARN}${I_WARN} No se encontraron elementos.${C_RESET}"; pausa; return
  fi
  echo -e "${C_OK}${I_OK} ${#FILES[@]} elemento(s) encontrado(s).${C_RESET}"
  if (( ${#FILES[@]} > 2000 )); then
    read -rp "${C_PROMPT}Es un lote muy grande, ¿continuar de todas formas? (s/n) [n]: ${C_RESET}" seguir
    [[ "$seguir" =~ ^[sS]$ ]] || { echo -e "${C_WARN}${I_WARN} Cancelado.${C_RESET}"; pausa; return; }
  fi
  menu_metodos
}

opcion_archivos() {
  local seleccion
  seleccion=$(seleccionar_archivos)
  [[ -z "$seleccion" ]] && { echo -e "${C_WARN}${I_WARN} Cancelado.${C_RESET}"; pausa; return; }
  IFS=$'\x1f' read -ra FILES <<< "$seleccion"
  echo -e "${C_OK}${I_OK} ${#FILES[@]} archivo(s) seleccionado(s).${C_RESET}"
  menu_metodos
}

# ---- Cola de transformaciones encadenadas ----

guardar_snapshot_cola() {
  HISTORIAL_COLA+=("$(IFS=$'\x1f'; echo "${NOMBRES_COLA[*]}")")
}

registrar_paso() {
  PASOS_COLA+=("$1")
}

deshacer_paso_cola() {
  local total=${#HISTORIAL_COLA[@]}
  if (( total == 0 )); then
    echo -e "${C_WARN}${I_WARN} No hay pasos que deshacer.${C_RESET}"; pausa; return
  fi
  local idx=$(( total - 1 ))
  IFS=$'\x1f' read -ra NOMBRES_COLA <<< "${HISTORIAL_COLA[$idx]}"
  unset "HISTORIAL_COLA[$idx]"; HISTORIAL_COLA=("${HISTORIAL_COLA[@]}")
  idx=$(( ${#PASOS_COLA[@]} - 1 ))
  unset "PASOS_COLA[$idx]"; PASOS_COLA=("${PASOS_COLA[@]}")
}

vista_previa_cola() {
  clear
  titulo "Vista previa acumulada" "${#PASOS_COLA[@]} paso(s) en cola"
  echo
  local i n=${#FILES[@]} ancho=0 nombre_i cabeza=15 cola=5
  for i in "${!FILES[@]}"; do
    nombre_i="$(basename "${FILES[$i]}")"
    (( ${#nombre_i} > ancho )) && ancho=${#nombre_i}
  done
  (( ancho > 42 )) && ancho=42
  for i in "${!FILES[@]}"; do
    if (( n > 30 )); then
      (( i == cabeza )) && echo -e "  ${C_DIM}... $(( n - cabeza - cola )) archivo(s) mas ...${C_RESET}"
      (( i >= cabeza && i < n - cola )) && continue
    fi
    printf "  ${C_DIM}%-${ancho}s${C_RESET} ${C_ACCENT}${I_ARROW}${C_RESET} ${C_OK}%s${C_RESET}\n" "$(basename "${FILES[$i]}")" "${NOMBRES_COLA[$i]}"
  done
}

# ---- Motor de renombrado ----

nombre_alternativo() {
  local ruta="$1" dir base nombre ext n=1 nuevo
  dir="${ruta%/*}"
  base="${ruta##*/}"
  IFS="$LOG_SEP" read -r nombre ext <<< "$(separar_nombre_ext "$base")"
  [[ -n "$ext" ]] && ext=".${ext}"
  nuevo="$dir/${nombre}($n)$ext"
  while [[ -e "$nuevo" || -L "$nuevo" ]]; do
    ((n++))
    nuevo="$dir/${nombre}($n)$ext"
  done
  echo "$nuevo"
}

sanear_nuevo() {
  local n="${1//\//-}"
  n="${n#"${n%%[![:space:]]*}"}"
  n="${n%"${n##*[![:space:]]}"}"
  [[ -z "$n" || "$n" == "." || "$n" == ".." ]] && n="sin_nombre_${RANDOM}"
  if (( $(printf '%s' "$n" | wc -c) > 255 )); then
    n="$(printf '%s' "$n" | head -c 255 | iconv -f UTF-8 -t UTF-8 -c 2>/dev/null)"
    [[ -z "$n" ]] && n="sin_nombre_${RANDOM}"
  fi
  printf '%s' "$n"
}

# Mueve LIVE[idx] a nuevo_path. Si lo movido es una carpeta, repara la ruta
# en LIVE[] de cualquier otro elemento del lote que estuviera anidado dentro,
# para que un lote pueda incluir una carpeta y su contenido a la vez sin romperse.
mover_item() {
  local idx="$1" nuevo_path="$2" viejo_path="${LIVE[$1]}" j
  mv -n -- "$viejo_path" "$nuevo_path" 2>/dev/null || return 1
  LIVE[$idx]="$nuevo_path"
  if [[ -d "$nuevo_path" ]]; then
    for j in "${!LIVE[@]}"; do
      [[ "$j" == "$idx" ]] && continue
      case "${LIVE[$j]}" in
        "$viejo_path"/*) LIVE[$j]="$nuevo_path/${LIVE[$j]#"$viejo_path"/}" ;;
      esac
    done
  fi
}

preguntar_politica_conflicto() {
  local n_existentes="$1"
  if (( n_existentes == 0 )); then echo 1; return; fi
  echo -e "${C_WARN}${I_WARN} ${n_existentes} nombre(s) ya existían fuera del lote.${C_RESET} ¿Qué hacer con ellos?" >&2
  echo -e "  ${C_ACCENT}1)${C_RESET} Añadir sufijo automático (1), (2)...  ${C_DIM}[por defecto]${C_RESET}" >&2
  echo -e "  ${C_ACCENT}2)${C_RESET} Sobrescribir el archivo o carpeta existente ${C_DIM}(irreversible)${C_RESET}" >&2
  echo -e "  ${C_ACCENT}3)${C_RESET} Omitir (no renombrar esos elementos)" >&2
  local politica_conflicto
  read -rp "${C_PROMPT}➤ Opción [1]: ${C_RESET}" politica_conflicto
  politica_conflicto=${politica_conflicto:-1}
  [[ "$politica_conflicto" =~ ^[123]$ ]] || politica_conflicto=1
  echo "$politica_conflicto"
}

mostrar_cancelado() { echo -e "${C_DIM}Cancelado.${C_RESET}"; pausa; }

mostrar_error() { echo -e "${C_ERR}${I_ERR} $1${C_RESET}"; pausa; }

mostrar_resumen() {
  local ok="$1" fallos="$2" sin_cambios="$3" omitidos="$4" modo="${5:-mover}" etiqueta_ok="Renombrados"
  [[ "$modo" == "copiar" ]] && etiqueta_ok="Copiados"
  echo -e "${C_OK}${I_OK} ${etiqueta_ok}: $ok${C_RESET}  ${C_WARN}• Omitidos: $omitidos${C_RESET}  ${C_ERR}${I_ERR} Fallos: $fallos${C_RESET}  ${C_DIM}• Sin cambios: $sin_cambios${C_RESET}"
  pausa
}

aplicar_renombrado() {
  local i n=${#FILES[@]}
  if (( ${#NUEVOS[@]} != n )); then
    mostrar_error "Error interno: las listas de nombres no coinciden."; return
  fi
  for i in "${!NUEVOS[@]}"; do NUEVOS[$i]=$(sanear_nuevo "${NUEVOS[$i]}"); done

  # Analisis previo: colisiones entre nuevos nombres y coincidencias con elementos externos al lote
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

  echo -e "${C_TITLE}Vista previa${C_RESET} ${C_DIM}(${n} elemento(s))${C_RESET}"
  local ancho=0 nombre_i color cabeza=15 cola=5
  for i in "${!FILES[@]}"; do
    nombre_i="$(basename "${FILES[$i]}")"
    (( ${#nombre_i} > ancho )) && ancho=${#nombre_i}
  done
  (( ancho > 42 )) && ancho=42
  for i in "${!FILES[@]}"; do
    if (( n > 30 )); then
      (( i == cabeza )) && echo -e "  ${C_DIM}... $(( n - cabeza - cola )) elemento(s) mas ...${C_RESET}"
      (( i >= cabeza && i < n - cola )) && continue
    fi
    case "${estado[$i]}" in
      colision) color="$C_ERR" ;;
      existe) color="$C_WARN" ;;
      *) color="$C_OK" ;;
    esac
    printf "  ${C_DIM}%-${ancho}s${C_RESET} ${C_ACCENT}${I_ARROW}${C_RESET} ${color}%s${C_RESET}\n" "$(basename "${FILES[$i]}")" "${NUEVOS[$i]}"
  done
  (( n_colisiones > 0 )) && echo -e "${C_ERR}${I_ERR} ${n_colisiones} colisión(es) entre los nuevos nombres: se resolverán solas con un sufijo (1), (2)...${C_RESET}"

  local modo_aplicacion="${CLI_MODO:-mover}"
  if [[ -z "$CLI_MODO" ]]; then
    echo -e "  ${C_ACCENT}1)${C_RESET} Mover / renombrar los originales  ${C_DIM}[por defecto]${C_RESET}   ${C_ACCENT}2)${C_RESET} Copiar (deja los originales intactos)"
    read -rp "${C_PROMPT}➤ ¿Cómo aplicar los cambios? [1]: ${C_RESET}" sel_modo
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
    (( hay_anidados )) && echo -e "${C_WARN}${I_WARN} El lote incluye una carpeta y elementos dentro de ella: en modo copiar cada uno se copia por separado (no se anidan entre sí).${C_RESET}"
  fi

  local politica_conflicto="${CLI_CONFLICTO:-}"
  if [[ -z "$politica_conflicto" ]]; then
    politica_conflicto=$(preguntar_politica_conflicto "$n_existentes")
    [[ -z "$politica_conflicto" ]] && { mostrar_cancelado; return; }
  fi

  if (( CLI_DRY_RUN )); then
    echo -e "${C_DIM}Vista previa únicamente (--dry-run): no se aplicó ningún cambio.${C_RESET}"
    return 0
  fi

  if (( ! CLI_SIN_CONFIRMAR )); then
    echo -e "  ${C_DIM}$(repetir_char '─' 40)${C_RESET}"
    read -rp "${C_PROMPT}➤ ¿Aplicar estos cambios? (s/n): ${C_RESET}" conf
    [[ "$conf" =~ ^[sS]$ ]] || { mostrar_cancelado; return; }
  fi

  local lote_file
  lote_file="$HISTORY_DIR/$(date +%Y%m%d_%H%M%S)_$$.log"
  : > "$lote_file"
  echo "#modo:${modo_aplicacion}" >> "$lote_file"
  local origen ok=0 fallos=0 sin_cambios=0 omitidos=0 ts TEMP=()
  ts="$$_${RANDOM}"
  local mostrar_progreso=0 hechos=0
  (( n > 200 )) && mostrar_progreso=1

  if [[ "$modo_aplicacion" == "copiar" ]]; then
    # Cada elemento se copia de forma independiente desde su ruta original (que
    # nunca se toca), por eso no hace falta el rastreo de rutas en dos fases que
    # usa el modo mover.
    declare -A COLOCADOS=()
    for i in "${!FILES[@]}"; do
      dir="${FILES[$i]%/*}"
      [[ "${FILES[$i]}" == "$dir/${NUEVOS[$i]}" ]] && COLOCADOS["${FILES[$i]}"]=1
    done
    for i in "${!FILES[@]}"; do
      origen="${FILES[$i]}"
      dir="${origen%/*}"; destino="$dir/${NUEVOS[$i]}"
      if [[ "$origen" == "$destino" ]]; then ((sin_cambios++)); continue; fi
      if [[ -e "$destino" || -L "$destino" ]]; then
        if [[ -n "${COLOCADOS[$destino]:-}" ]]; then
          destino=$(nombre_alternativo "$destino")
        else
          case "$politica_conflicto" in
            2) rm -rf -- "$destino" ;;
            3) ((omitidos++)); continue ;;
            *) destino=$(nombre_alternativo "$destino") ;;
          esac
        fi
      fi
      if cp -a -- "$origen" "$destino"; then
        printf '%s%s\n' "$destino" "$LOG_SEP" >> "$lote_file"
        COLOCADOS[$destino]=1; ((ok++))
      else
        echo -e "${C_ERR}${I_ERR} Error al copiar '$origen'${C_RESET}"
        ((fallos++))
      fi
      if (( mostrar_progreso )); then
        ((hechos++))
        (( hechos % 25 == 0 || hechos == n )) && barra_progreso "$hechos" "$n"
      fi
    done
  else
    declare -A LIVE=()
    for i in "${!FILES[@]}"; do LIVE[$i]="${FILES[$i]}"; done

    # Fase 1: mover a nombres temporales unicos. Evita colisiones entre elementos
    # del propio lote (p.ej. A->B y B->A a la vez) sin arriesgar sobrescrituras.
    # Usa LIVE[] (no FILES[]) porque si una carpeta del lote ya se movio, la ruta
    # de sus elementos hijos cambia con ella; mover_item mantiene LIVE[] al dia.
    for i in "${!FILES[@]}"; do
      origen="${LIVE[$i]}"
      dir="${origen%/*}"; destino="$dir/${NUEVOS[$i]}"
      if [[ "$origen" == "$destino" ]]; then TEMP[$i]=""; ((sin_cambios++)); continue; fi
      TEMP[$i]="$dir/.renombrador_tmp_${ts}_${i}"
      if ! mover_item "$i" "${TEMP[$i]}"; then
        echo -e "${C_ERR}${I_ERR} No se pudo preparar '$origen'${C_RESET}"
        TEMP[$i]="!"; ((fallos++))
      fi
    done

    # Fase 2: mover de nombre temporal a nombre final, aplicando la politica elegida
    # ante nombres que ya existian fuera del lote (sufijo / sobrescribir / omitir).
    declare -A COLOCADOS=()
    for i in "${!FILES[@]}"; do
      [[ -z "${TEMP[$i]:-}" || "${TEMP[$i]}" == "!" ]] && COLOCADOS["${LIVE[$i]}"]=1
    done
    for i in "${!FILES[@]}"; do
      [[ -z "${TEMP[$i]:-}" || "${TEMP[$i]}" == "!" ]] && continue
      origen="${FILES[$i]}"
      dir="${LIVE[$i]%/*}"; destino="$dir/${NUEVOS[$i]}"
      if [[ -e "$destino" || -L "$destino" ]]; then
        if [[ -n "${COLOCADOS[$destino]:-}" ]]; then
          destino=$(nombre_alternativo "$destino")
        else
          case "$politica_conflicto" in
            2) rm -rf -- "$destino" ;;
            3) mover_item "$i" "$dir/$(basename "$origen")"; ((omitidos++)); continue ;;
            *) destino=$(nombre_alternativo "$destino") ;;
          esac
        fi
      fi
      if mover_item "$i" "$destino"; then
        printf '%s%s%s\n' "$destino" "$LOG_SEP" "$origen" >> "$lote_file"
        FILES[$i]="$destino"; COLOCADOS[$destino]=1; ((ok++))
      else
        echo -e "${C_ERR}${I_ERR} Error al mover '$origen' a su nombre final${C_RESET}"
        mover_item "$i" "$dir/$(basename "$origen")"
        ((fallos++))
      fi
      if (( mostrar_progreso )); then
        ((hechos++))
        (( hechos % 25 == 0 || hechos == n )) && barra_progreso "$hechos" "$n"
      fi
    done
  fi
  (( mostrar_progreso )) && printf "\r%*s\r" 60 ""
  (( ok > 0 )) || rm -f "$lote_file"
  mapfile -t _viejos < <(ls -1t "$HISTORY_DIR" 2>/dev/null | tail -n "+$((MAX_HISTORIAL+1))")
  for _v in "${_viejos[@]:-}"; do [[ -n "$_v" ]] && rm -f "$HISTORY_DIR/$_v"; done

  mostrar_resumen "$ok" "$fallos" "$sin_cambios" "$omitidos" "$modo_aplicacion"
}

listar_historial() {
  mapfile -t LOTES < <(ls -1t "$HISTORY_DIR" 2>/dev/null)
  if (( ${#LOTES[@]} == 0 )); then echo -e "${C_DIM}No hay lotes en el historial.${C_RESET}"; return 1; fi
  local i f n fecha hora modo etiqueta
  for i in "${!LOTES[@]}"; do
    f="${LOTES[$i]}"
    modo=$(modo_de_lote "$HISTORY_DIR/$f")
    n=$(grep -vc '^#' "$HISTORY_DIR/$f" 2>/dev/null)
    etiqueta="archivo(s) renombrado(s)"
    [[ "$modo" == "copiar" ]] && etiqueta="copia(s) creada(s)"
    fecha="${f:0:4}-${f:4:2}-${f:6:2}"; hora="${f:9:2}:${f:11:2}:${f:13:2}"
    echo -e "  ${C_ACCENT}$((i+1)))${C_RESET} ${fecha} ${hora}  ${C_DIM}·${C_RESET} ${n} ${etiqueta}"
  done
  return 0
}

# Lee el modo (mover|copiar) de la cabecera "#modo:" de un lote. Los lotes
# antiguos, guardados antes de que existiera el modo copiar, no tienen esa
# cabecera; se asume "mover" para no romper el historial ya existente.
modo_de_lote() {
  local cabecera
  cabecera=$(head -n1 -- "$1" 2>/dev/null)
  if [[ "$cabecera" == "#modo:"* ]]; then
    printf '%s' "${cabecera#"#modo:"}"
  else
    printf 'mover'
  fi
}

# Mueve ACTUAL[idx] a nuevo_path (para deshacer; igual que mover_item pero
# sobre ACTUAL[] en vez de LIVE[]). Si lo movido es una carpeta, repara en
# ACTUAL[] la ruta de otros elementos del lote anidados dentro.
mover_actual() {
  local idx="$1" nuevo_path="$2" viejo_path="${ACTUAL[$1]}" j
  mv -n -- "$viejo_path" "$nuevo_path" 2>/dev/null || return 1
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
  clear
  titulo "Deshacer renombrado" "Elige un lote del historial"
  echo
  listar_historial || { pausa; return; }
  echo
  read -rp "${C_PROMPT}➤ Número de lote (Enter = más reciente, 0 = cancelar): ${C_RESET}" sel
  sel=${sel:-1}
  [[ "$sel" == "0" ]] && return
  if [[ ! "$sel" =~ ^[0-9]+$ ]] || (( sel < 1 || sel > ${#LOTES[@]} )); then
    echo -e "${C_WARN}${I_WARN} Opción no válida.${C_RESET}"; pausa; return
  fi
  local archivo="$HISTORY_DIR/${LOTES[$((sel-1))]}"
  local modo; modo=$(modo_de_lote "$archivo")
  local nuevo original ok=0 fallos=0
  local -a VIVOS=() ORIGENES=() pendientes=()
  while IFS="$LOG_SEP" read -r nuevo original; do
    [[ -z "$nuevo" || "$nuevo" == "#"* ]] && continue
    VIVOS+=("$nuevo"); ORIGENES+=("$original")
  done < "$archivo"

  if [[ "$modo" == "copiar" ]]; then
    # No hay "original" que restaurar (las copias se crearon sin tocar la
    # fuente): deshacer un lote copiado significa borrar las copias creadas.
    local i
    for i in "${!VIVOS[@]}"; do
      nuevo="${VIVOS[$i]}"
      if [[ ! -e "$nuevo" && ! -L "$nuevo" ]]; then ((fallos++)); pendientes+=("$nuevo$LOG_SEP"); continue; fi
      if rm -rf -- "$nuevo"; then ((ok++)); else ((fallos++)); pendientes+=("$nuevo$LOG_SEP"); fi
    done
    if (( ${#pendientes[@]} > 0 )); then
      { echo "#modo:copiar"; printf '%s\n' "${pendientes[@]}"; } > "$archivo"
    else
      rm -f "$archivo"
    fi
    echo -e "${C_OK}${I_OK} Copias eliminadas: $ok${C_RESET}  ${C_ERR}${I_ERR} Fallos: $fallos${C_RESET}"
    pausa
    return
  fi

  # modo == mover. Se restaura en dos fases con un nombre temporal de por
  # medio, igual que aplicar_renombrado: asi un lote con intercambios de
  # nombre (A->B y B->A a la vez) se deshace sin que un elemento choque
  # contra otro que todavia ocupa el nombre que este necesita. ACTUAL[]
  # rastrea la ruta actual de cada elemento (igual que LIVE[] al aplicar),
  # porque restaurar una carpeta cambia la ruta de sus hijos.
  local i dir ts
  ts="$$_${RANDOM}"
  local -a ACTUAL=("${VIVOS[@]}") TEMP=()

  # Fase 1: a nombres temporales.
  for i in "${!VIVOS[@]}"; do
    dir="${ACTUAL[$i]%/*}"
    TEMP[i]="$dir/.renombrador_undo_tmp_${ts}_${i}"
    if ! mover_actual "$i" "${TEMP[$i]}"; then
      ((fallos++)); pendientes+=("${VIVOS[$i]}$LOG_SEP${ORIGENES[$i]}"); TEMP[i]="!"
    fi
  done

  # Fase 2: de temporal al nombre original.
  for i in "${!VIVOS[@]}"; do
    [[ "${TEMP[$i]}" == "!" ]] && continue
    original="${ORIGENES[$i]}"
    if [[ -e "$original" || -L "$original" ]]; then
      echo -e "${C_WARN}${I_WARN} '$original' ya existe, no se restaura '${VIVOS[$i]}'${C_RESET}"
      mover_actual "$i" "${VIVOS[$i]}"
      ((fallos++)); pendientes+=("${VIVOS[$i]}$LOG_SEP$original")
      continue
    fi
    if mover_actual "$i" "$original"; then
      ((ok++))
    else
      mover_actual "$i" "${VIVOS[$i]}"
      ((fallos++)); pendientes+=("${VIVOS[$i]}$LOG_SEP$original")
    fi
  done
  if (( ${#pendientes[@]} > 0 )); then
    { echo "#modo:mover"; printf '%s\n' "${pendientes[@]}"; } > "$archivo"
  else
    rm -f "$archivo"
  fi
  echo -e "${C_OK}${I_OK} Deshechos: $ok${C_RESET}  ${C_ERR}${I_ERR} Fallos: $fallos${C_RESET}"
  pausa
}

# ---- Metodos de renombrado ----

# ---- Transformaciones puras (usadas tanto por el modo terminal como por el modo grafico) ----

# Devuelve los indices de FILES[] ordenados por el criterio pedido (uno por linea).
# Empates (p.ej. misma fecha) se resuelven por el orden original, para que el
# resultado sea predecible y estable.
orden_indices_por_criterio() {
  local criterio="$1" i archivo valor tipo base ext
  local -a pares=()
  for i in "${!FILES[@]}"; do
    archivo="${FILES[$i]}"
    case "$criterio" in
      fecha) valor=$(date -r "$archivo" +%s 2>/dev/null) ;;
      exif)
        IFS="$LOG_SEP" read -r base ext <<< "$(separar_nombre_ext "$(basename "$archivo")")"
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
    IFS="$LOG_SEP" read -r orig ext <<< "$(separar_nombre_ext "$nombre")"
    [[ -n "$ext" ]] && ext=".${ext}"
    printf -v num "%0${digitos}d" "$n"
    [[ "$modo" == "2" ]] && base="$orig"
    NOMBRES_COLA[idx]="${base}_${num}${ext}"
    ((n++))
  done
}

metodo_numeracion() {
  local modo base inicio auto_digitos digitos criterio etiqueta_orden
  echo -e "  ${C_ACCENT}1)${C_RESET} Texto personalizado   ${C_ACCENT}2)${C_RESET} Mantener nombre original + número"
  read -rp "${C_PROMPT}Opción [1]: ${C_RESET}" modo; modo=${modo:-1}
  [[ "$modo" != "2" ]] && read -rp "${C_PROMPT}Texto base (ej: Vacaciones): ${C_RESET}" base
  echo -e "${C_DIM}Orden para asignar los números:${C_RESET}"
  echo -e "  ${C_ACCENT}1)${C_RESET} Como aparecen ahora   ${C_ACCENT}2)${C_RESET} Fecha de modificación (antigua${I_ARROW}nueva)"
  echo -e "  ${C_ACCENT}3)${C_RESET} Fecha EXIF real de la foto (antigua${I_ARROW}nueva)   ${C_ACCENT}4)${C_RESET} Tamaño (pequeño${I_ARROW}grande)"
  read -rp "${C_PROMPT}Opción [1]: ${C_RESET}" criterio; criterio=${criterio:-1}
  echo -e "${C_DIM}Con qué número empieza la serie; el resto de archivos lo continúan (2, 3, 4...).${C_RESET}"
  read -rp "${C_PROMPT}Número inicial [1]: ${C_RESET}" inicio
  [[ "$inicio" =~ ^[0-9]+$ ]] || inicio=1
  auto_digitos=${#FILES[@]}; auto_digitos=${#auto_digitos}
  echo -e "${C_DIM}Ceros a la izquierda para igualar el largo de los números (ej: con $auto_digitos, «$inicio» se escribe «$(printf "%0${auto_digitos}d" "$inicio")»).${C_RESET}"
  read -rp "${C_PROMPT}Dígitos de relleno [$auto_digitos]: ${C_RESET}" digitos
  [[ "$digitos" =~ ^[0-9]+$ ]] || digitos=$auto_digitos

  local -a orden=()
  case "$criterio" in
    2) mapfile -t orden < <(orden_indices_por_criterio fecha); etiqueta_orden=", por fecha de modificación" ;;
    3) comprobar_herramientas_exif
       if [[ -z "$EXIFTOOL_DISPONIBLE" && -z "$IDENTIFY_DISPONIBLE" ]]; then
         echo -e "${C_WARN}${I_WARN} No se encontró 'exiftool' ni 'identify': se usará la fecha de modificación como respaldo.${C_RESET}"
       fi
       mapfile -t orden < <(orden_indices_por_criterio exif); etiqueta_orden=", por fecha EXIF" ;;
    4) mapfile -t orden < <(orden_indices_por_criterio tamano); etiqueta_orden=", por tamaño" ;;
    *) orden=("${!FILES[@]}"); etiqueta_orden="" ;;
  esac

  guardar_snapshot_cola
  transformar_numeracion "$modo" "$base" "$inicio" "$digitos" "${orden[*]}"
  registrar_paso "Numeración ('$base'${etiqueta_orden})"
}

transformar_prefijo() {
  local pre="$1" i
  for i in "${!FILES[@]}"; do NOMBRES_COLA[i]="${pre}${NOMBRES_COLA[$i]}"; done
}

metodo_prefijo() {
  local pre
  read -rp "${C_PROMPT}Prefijo a añadir: ${C_RESET}" pre
  guardar_snapshot_cola
  transformar_prefijo "$pre"
  registrar_paso "Prefijo: '$pre'"
}

transformar_sufijo() {
  local suf="$1" i nombre base ext
  for i in "${!FILES[@]}"; do
    nombre="${NOMBRES_COLA[$i]}"
    IFS="$LOG_SEP" read -r base ext <<< "$(separar_nombre_ext "$nombre")"
    [[ -n "$ext" ]] && ext=".${ext}"
    NOMBRES_COLA[i]="${base}${suf}${ext}"
  done
}

metodo_sufijo() {
  local suf
  read -rp "${C_PROMPT}Sufijo a añadir (antes de la extensión): ${C_RESET}" suf
  guardar_snapshot_cola
  transformar_sufijo "$suf"
  registrar_paso "Sufijo: '$suf'"
}

validar_regex() {
  local buscar="$1" reemplazo="$2" delim="$3"
  # Orden de redireccion intencional (no es un error): descarta el stdout de
  # sed pero deja pasar su stderr, que es el mensaje de error que esta
  # funcion necesita devolver. Invertir el orden silenciaria ese mensaje.
  printf '%s' "" | sed -E "s${delim}${buscar}${delim}${reemplazo}${delim}g" 2>&1 1>/dev/null
}

delimitador_para() {
  local buscar="$1" reemplazo="$2" delim
  for delim in '/' '#' '|' '@' '~'; do
    [[ "$buscar$reemplazo" != *"$delim"* ]] && { printf '%s' "$delim"; return; }
  done
  printf '/'
}

transformar_buscar_reemplazar() {
  local modo="$1" buscar="$2" reemplazo="$3" i nombre delim buscar_esc
  if [[ "$modo" == "2" ]]; then
    delim=$(delimitador_para "$buscar" "$reemplazo")
    for i in "${!FILES[@]}"; do
      nombre="${NOMBRES_COLA[$i]}"
      NOMBRES_COLA[i]=$(printf '%s' "$nombre" | sed -E "s${delim}${buscar}${delim}${reemplazo}${delim}g")
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
  echo -e "  ${C_ACCENT}1)${C_RESET} Texto literal   ${C_ACCENT}2)${C_RESET} Expresión regular (ERE)"
  read -rp "${C_PROMPT}Opción [1]: ${C_RESET}" modo; modo=${modo:-1}
  read -rp "${C_PROMPT}Texto a buscar: ${C_RESET}" buscar
  if [[ -z "$buscar" ]]; then
    echo -e "${C_WARN}${I_WARN} Texto de busqueda vacio, cancelado.${C_RESET}"; pausa; return
  fi
  [[ "$modo" == "2" ]] && echo -e "${C_DIM}Puedes usar grupos de captura \\1, \\2... en el reemplazo.${C_RESET}"
  read -rp "${C_PROMPT}Reemplazar por: ${C_RESET}" reemplazo
  if [[ "$modo" == "2" ]]; then
    delim=$(delimitador_para "$buscar" "$reemplazo")
    err=$(validar_regex "$buscar" "$reemplazo" "$delim")
    if [[ -n "$err" ]]; then
      echo -e "${C_ERR}${I_ERR} Expresión regular no válida: ${err}${C_RESET}"; pausa; return
    fi
  fi
  guardar_snapshot_cola
  transformar_buscar_reemplazar "$modo" "$buscar" "$reemplazo"
  if [[ "$modo" == "2" ]]; then registrar_paso "Regex: '$buscar' ${I_ARROW} '$reemplazo'"
  else registrar_paso "Buscar/reemplazar: '$buscar' ${I_ARROW} '$reemplazo'"; fi
}

capitalizar() {
  local nombre="$1" base ext
  IFS="$LOG_SEP" read -r base ext <<< "$(separar_nombre_ext "$nombre")"
  [[ -n "$ext" ]] && ext=".${ext}"
  base=$(printf '%s' "$base" | sed -E 's/(^|[ _-])([[:lower:]])/\1\U\2/g')
  echo "${base}${ext}"
}

transformar_mayus_minus() {
  local op="$1" i nombre base ext
  for i in "${!FILES[@]}"; do
    nombre="${NOMBRES_COLA[$i]}"
    case "$op" in
      1) NOMBRES_COLA[i]="${nombre,,}" ;;
      2) NOMBRES_COLA[i]="${nombre^^}" ;;
      3) NOMBRES_COLA[i]="$(capitalizar "$nombre")" ;;
      4) IFS="$LOG_SEP" read -r base ext <<< "$(separar_nombre_ext "$nombre")"
         [[ -n "$ext" ]] && ext=".${ext}"
         base="${base,,}"; NOMBRES_COLA[i]="${base^}${ext}" ;;
      *) ;;
    esac
  done
}

metodo_mayus_minus() {
  local op
  echo -e "  ${C_ACCENT}1)${C_RESET} minúsculas   ${C_ACCENT}2)${C_RESET} MAYÚSCULAS   ${C_ACCENT}3)${C_RESET} Capitalizar cada palabra   ${C_ACCENT}4)${C_RESET} Primera letra de la frase"
  read -rp "${C_PROMPT}Opción [1]: ${C_RESET}" op; op=${op:-1}
  if [[ ! "$op" =~ ^[1-4]$ ]]; then
    echo -e "${C_WARN}${I_WARN} Opción no válida, no se aplicó ningún cambio.${C_RESET}"; pausa; return
  fi
  guardar_snapshot_cola
  transformar_mayus_minus "$op"
  registrar_paso "Mayúsculas/minúsculas"
}

transformar_fecha() {
  local origen_fecha="$1" pos="$2" i nombre fecha base ext tipo
  for i in "${!FILES[@]}"; do
    nombre="${NOMBRES_COLA[$i]}"
    IFS="$LOG_SEP" read -r base ext <<< "$(separar_nombre_ext "$nombre")"
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
  echo -e "  ${C_ACCENT}1)${C_RESET} Fecha actual   ${C_ACCENT}2)${C_RESET} Fecha de modificación del archivo   ${C_ACCENT}3)${C_RESET} Fecha EXIF real (fotos)"
  read -rp "${C_PROMPT}Opción [1]: ${C_RESET}" op; op=${op:-1}
  if [[ "$op" == "3" ]]; then
    comprobar_herramientas_exif
    if [[ -z "$EXIFTOOL_DISPONIBLE" && -z "$IDENTIFY_DISPONIBLE" ]]; then
      echo -e "${C_WARN}${I_WARN} No se encontró 'exiftool' ni 'identify' (ImageMagick): se usará la fecha de modificación como respaldo.${C_RESET}"
      echo -e "${C_DIM}  Instala 'libimage-exiftool-perl' para leer la fecha EXIF real de las fotos.${C_RESET}"
    fi
  fi
  echo -e "  ${C_ACCENT}1)${C_RESET} Al principio   ${C_ACCENT}2)${C_RESET} Al final"
  read -rp "${C_PROMPT}Posición [2]: ${C_RESET}" pos; pos=${pos:-2}
  guardar_snapshot_cola
  transformar_fecha "$op" "$pos"
  case "$op" in
    2) registrar_paso "Insertar fecha (modificación)" ;;
    3) registrar_paso "Insertar fecha (EXIF)" ;;
    *) registrar_paso "Insertar fecha (actual)" ;;
  esac
}

transformar_limpiar() {
  local sep="$1" i nombre base ext
  for i in "${!FILES[@]}"; do
    nombre="${NOMBRES_COLA[$i]}"
    IFS="$LOG_SEP" read -r base ext <<< "$(separar_nombre_ext "$nombre")"
    [[ -n "$ext" ]] && ext=".${ext}"
    base="${base// /$sep}"
    base="${base//\//$sep}"
    base=$(printf '%s' "$base" | sed -E 's#[<>:"\|?*]##g')
    NOMBRES_COLA[i]="${base}${ext}"
  done
}

metodo_limpiar() {
  local op sep
  echo -e "  ${C_ACCENT}1)${C_RESET} Espacios ${I_ARROW} guion bajo   ${C_ACCENT}2)${C_RESET} Espacios ${I_ARROW} guion   ${C_ACCENT}3)${C_RESET} Eliminar espacios"
  read -rp "${C_PROMPT}Opción [1]: ${C_RESET}" op; op=${op:-1}
  case "$op" in
    2) sep="-" ;;
    3) sep="" ;;
    *) sep="_" ;;
  esac
  guardar_snapshot_cola
  transformar_limpiar "$sep"
  registrar_paso "Limpiar nombre"
}

reiniciar_cola() {
  local i
  NOMBRES_COLA=(); PASOS_COLA=(); HISTORIAL_COLA=()
  for i in "${!FILES[@]}"; do NOMBRES_COLA[i]=$(basename "${FILES[$i]}"); done
}

menu_metodos() {
  local i op sub conf
  reiniciar_cola
  while true; do
    clear
    sub="${#FILES[@]} archivo(s) seleccionado(s)"
    (( ${#PASOS_COLA[@]} > 0 )) && sub+="  ·  ${#PASOS_COLA[@]} paso(s) en cola sin aplicar"
    titulo "Método de renombrado" "$sub"
    echo
    opt 1 "🔢" "Numeración secuencial"
    opt 2 "⏪" "Añadir prefijo"
    opt 3 "⏩" "Añadir sufijo"
    opt 4 "🔍" "Buscar y reemplazar (texto o regex)"
    opt 5 "🔤" "Cambiar MAYÚSCULAS/minúsculas"
    opt 6 "📅" "Insertar fecha"
    opt 7 "🧹" "Limpiar nombre (espacios y caracteres especiales)"
    echo -e "  ${C_DIM}$(repetir_char '·' 44)${C_RESET}"
    opt 8 "🤖" "Plantilla automática por tipo de archivo"
    opt 9 "📂" "Usar plantilla personalizada guardada"
    opt 10 "✨" "Crear y aplicar plantilla nueva"
    opt 11 "🎯" "Aplicar patrón puntual (sin guardar)"
    if (( ${#PASOS_COLA[@]} > 0 )); then
      echo -e "  ${C_DIM}$(repetir_char '·' 44)${C_RESET}"
      for i in "${!PASOS_COLA[@]}"; do
        echo -e "  ${C_DIM}   $((i+1)). ${PASOS_COLA[$i]}${C_RESET}"
      done
      opt v "👁️" "Ver vista previa acumulada"
      opt u "⬅️" "Deshacer último paso en cola"
      opt a "✅" "Aplicar todos los cambios"
    fi
    echo -e "  ${C_DIM}$(repetir_char '·' 44)${C_RESET}"
    opt 0 "↩️" "Volver al menú principal"
    echo
    read -rp "${C_PROMPT}➤ Opción: ${C_RESET}" op
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
          echo -e "${C_WARN}${I_WARN} No hay pasos en la cola.${C_RESET}"; pausa
        else
          NUEVOS=("${NOMBRES_COLA[@]}")
          aplicar_renombrado
          reiniciar_cola
        fi
        ;;
      0)
        if (( ${#PASOS_COLA[@]} > 0 )); then
          read -rp "${C_PROMPT}Hay ${#PASOS_COLA[@]} paso(s) sin aplicar, ¿descartarlos y volver? (s/n) [n]: ${C_RESET}" conf
          [[ "$conf" =~ ^[sS]$ ]] || continue
        fi
        return ;;
      *) echo -e "${C_WARN}${I_WARN} Opción no válida.${C_RESET}"; pausa ;;
    esac
  done
}

# ---- Plantillas por tipo de archivo ----

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
    IFS="$LOG_SEP" read -r base ext <<< "$(separar_nombre_ext "$nombre")"
    tipo=$(detectar_tipo "$ext")
    contador[$tipo]=$(( ${contador[$tipo]:-0} + 1 ))
    printf -v num "%03d" "${contador[$tipo]}"
    [[ -n "$ext" ]] && ext=".${ext}"
    NOMBRES_COLA[i]="${tipo}_${num}${ext}"
  done
  registrar_paso "Tipo de archivo"
}

# ---- Plantillas personalizadas ----

aplicar_patron() {
  local patron="$1" inicio="${2:-1}" digitos="${3:-0}" n fecha i nombre base ext parent num resultado usa_ext=0
  [[ "$patron" == *"{ext}"* ]] && usa_ext=1
  fecha=$(date +%Y-%m-%d)
  n=$inicio
  guardar_snapshot_cola
  for i in "${!FILES[@]}"; do
    nombre="${NOMBRES_COLA[$i]}"
    IFS="$LOG_SEP" read -r base ext <<< "$(separar_nombre_ext "$nombre")"
    parent=$(basename "$(dirname "${FILES[$i]}")")
    if [[ "$digitos" -gt 0 ]]; then printf -v num "%0${digitos}d" "$n"; else num="$n"; fi
    resultado="$patron"
    resultado="${resultado//\{name\}/$base}"
    resultado="${resultado//\{ext\}/$ext}"
    resultado="${resultado//\{n\}/$num}"
    resultado="${resultado//\{date\}/$fecha}"
    resultado="${resultado//\{parent\}/$parent}"
    [[ -n "$ext" && $usa_ext -eq 0 ]] && resultado="${resultado}.${ext}"
    NOMBRES_COLA[i]="$resultado"
    ((n++))
  done
  registrar_paso "Plantilla: $patron"
}

pedir_parametros_n() {
  INICIO_N=1; DIGITOS_N=0
  if [[ "$1" == *"{n}"* ]]; then
    local auto_digitos
    echo -e "${C_DIM}El patrón usa {n}: con qué número empieza esa parte (el resto de archivos lo continúan).${C_RESET}"
    read -rp "${C_PROMPT}Número inicial para {n} [1]: ${C_RESET}" INICIO_N
    [[ "$INICIO_N" =~ ^[0-9]+$ ]] || INICIO_N=1
    auto_digitos=${#FILES[@]}; auto_digitos=${#auto_digitos}
    echo -e "${C_DIM}Ceros a la izquierda para {n} (ej: con $auto_digitos, «$INICIO_N» se escribe «$(printf "%0${auto_digitos}d" "$INICIO_N")»). Vacío = sin relleno.${C_RESET}"
    read -rp "${C_PROMPT}Dígitos de relleno para {n} [sin relleno]: ${C_RESET}" DIGITOS_N
    [[ "$DIGITOS_N" =~ ^[0-9]+$ ]] || DIGITOS_N=0
  fi
}

HINT_COMODINES="${C_DIM}Comodines: {name} {ext} {n} {date} {parent}
     {ext} no incluye el punto · si el patrón no usa {ext}, la extensión original se añade sola al final${C_RESET}"

patron_es_ambiguo() {
  local p="$1"
  [[ "$p" != *"{name}"* && "$p" != *"{n}"* && "$p" != *"{date}"* && "$p" != *"{parent}"* ]]
}

avisar_si_ambiguo() {
  patron_es_ambiguo "$1" && echo -e "${C_WARN}${I_WARN} El patrón no usa {name}, {n}, {date} ni {parent}: todos los archivos partirían del mismo nombre (se numerarán automáticamente).${C_RESET}"
}

pedir_nombre_y_patron() {
  read -rp "${C_PROMPT}Nombre para la plantilla: ${C_RESET}" NOMBRE_PLANTILLA
  echo -e "$HINT_COMODINES"
  read -rp "${C_PROMPT}Patrón (ej: {date}_{name}_{n}): ${C_RESET}" PATRON_PLANTILLA
  if [[ -z "$PATRON_PLANTILLA" ]]; then
    echo -e "${C_WARN}${I_WARN} Patrón vacío, cancelado.${C_RESET}"; return 1
  fi
  avisar_si_ambiguo "$PATRON_PLANTILLA"
  NOMBRE_PLANTILLA="${NOMBRE_PLANTILLA//|/-}"
  PATRON_PLANTILLA="${PATRON_PLANTILLA//|/}"
  [[ -z "$NOMBRE_PLANTILLA" ]] && NOMBRE_PLANTILLA="Plantilla_$(date +%H%M%S)"
  return 0
}

guardar_plantilla() {
  pedir_nombre_y_patron || return 1
  echo "${NOMBRE_PLANTILLA}|${PATRON_PLANTILLA}" >> "$TEMPLATES_FILE"
  echo -e "${C_OK}${I_OK} Plantilla «${NOMBRE_PLANTILLA}» guardada.${C_RESET}"
}

crear_plantilla() {
  local NOMBRE_PLANTILLA PATRON_PLANTILLA
  guardar_plantilla || { pausa; return; }
  pedir_parametros_n "$PATRON_PLANTILLA"
  aplicar_patron "$PATRON_PLANTILLA" "$INICIO_N" "$DIGITOS_N"
}

aplicar_patron_puntual() {
  local patron
  echo -e "$HINT_COMODINES"
  read -rp "${C_PROMPT}Patrón (ej: {date}_{name}_{n}): ${C_RESET}" patron
  if [[ -z "$patron" ]]; then
    echo -e "${C_WARN}${I_WARN} Patrón vacío, cancelado.${C_RESET}"; pausa; return
  fi
  avisar_si_ambiguo "$patron"
  pedir_parametros_n "$patron"
  aplicar_patron "$patron" "$INICIO_N" "$DIGITOS_N"
}

listar_plantillas() {
  if [[ ! -s "$TEMPLATES_FILE" ]]; then echo -e "${C_DIM}No hay plantillas guardadas.${C_RESET}"; return; fi
  local i=1 n p
  while IFS='|' read -r n p; do
    echo -e "  ${C_ACCENT}${i})${C_RESET} ${n}  ${C_DIM}${I_ARROW}${C_RESET}  ${p}"
    ((i++))
  done < "$TEMPLATES_FILE"
}

usar_plantilla_guardada() {
  listar_plantillas
  if [[ ! -s "$TEMPLATES_FILE" ]]; then pausa; return; fi
  local sel n p nombres=() patrones=()
  while IFS='|' read -r n p; do nombres+=("$n"); patrones+=("$p"); done < "$TEMPLATES_FILE"
  read -rp "${C_PROMPT}Selecciona una plantilla: ${C_RESET}" sel
  if [[ "$sel" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= ${#patrones[@]} )); then
    echo -e "${C_DIM}Aplicando «${nombres[$((sel-1))]}»...${C_RESET}"
    pedir_parametros_n "${patrones[$((sel-1))]}"
    aplicar_patron "${patrones[$((sel-1))]}" "$INICIO_N" "$DIGITOS_N"
  else
    echo -e "${C_WARN}${I_WARN} Opción no válida.${C_RESET}"; pausa
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
  local sel total nombre_borrado conf
  total=$(grep -c '' "$TEMPLATES_FILE")
  read -rp "${C_PROMPT}Número de plantilla a eliminar: ${C_RESET}" sel
  if [[ "$sel" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= total )); then
    nombre_borrado=$(sed -n "${sel}p" "$TEMPLATES_FILE" | cut -d'|' -f1)
    read -rp "${C_PROMPT}¿Eliminar «${nombre_borrado}»? (s/n) [n]: ${C_RESET}" conf
    if [[ "$conf" =~ ^[sS]$ ]]; then
      sed -i "${sel}d" "$TEMPLATES_FILE"
      echo -e "${C_OK}${I_OK} Plantilla «${nombre_borrado}» eliminada.${C_RESET}"
    else
      echo -e "${C_DIM}Cancelado.${C_RESET}"
    fi
  else
    echo -e "${C_WARN}${I_WARN} Opción no válida.${C_RESET}"
  fi
  pausa
}

exportar_plantillas() {
  if [[ ! -s "$TEMPLATES_FILE" ]]; then echo -e "${C_WARN}${I_WARN} No hay plantillas para exportar.${C_RESET}"; pausa; return; fi
  local destino
  if [[ "$SELECTOR" == "zenity" ]]; then
    destino=$(zenity --file-selection --save --confirm-overwrite --filename="plantillas_renombrador.txt" --title="Exportar plantillas" 2>/dev/null)
  else
    destino=$(kdialog --getsavefilename "$HOME/plantillas_renombrador.txt" --title "Exportar plantillas" 2>/dev/null)
  fi
  [[ -z "$destino" ]] && { echo -e "${C_WARN}${I_WARN} Cancelado.${C_RESET}"; pausa; return; }
  if cp -f -- "$TEMPLATES_FILE" "$destino"; then
    echo -e "${C_OK}${I_OK} Plantillas exportadas a '$destino'.${C_RESET}"
  else
    echo -e "${C_ERR}${I_ERR} No se pudo exportar.${C_RESET}"
  fi
  pausa
}

importar_plantillas() {
  local origen
  if [[ "$SELECTOR" == "zenity" ]]; then
    origen=$(zenity --file-selection --title="Importar plantillas" 2>/dev/null)
  else
    origen=$(kdialog --getopenfilename "$HOME" --title "Importar plantillas" 2>/dev/null)
  fi
  [[ -z "$origen" ]] && { echo -e "${C_WARN}${I_WARN} Cancelado.${C_RESET}"; pausa; return; }
  if [[ ! -f "$origen" ]]; then echo -e "${C_ERR}${I_ERR} El archivo no existe.${C_RESET}"; pausa; return; fi
  local linea n p importadas=0 duplicadas=0 invalidas=0
  local -A existentes=()
  while IFS='|' read -r n p; do [[ -n "$n" ]] && existentes["$n"]=1; done < "$TEMPLATES_FILE"
  while IFS= read -r linea || [[ -n "$linea" ]]; do
    [[ -z "$linea" ]] && continue
    IFS='|' read -r n p <<< "$linea"
    n="${n//|/-}"; p="${p//|/}"
    if [[ -z "$n" || -z "$p" ]]; then ((invalidas++)); continue; fi
    if [[ -n "${existentes[$n]:-}" ]]; then ((duplicadas++)); continue; fi
    echo "${n}|${p}" >> "$TEMPLATES_FILE"
    existentes["$n"]=1
    ((importadas++))
  done < "$origen"
  echo -e "${C_OK}${I_OK} ${importadas} plantilla(s) importada(s).${C_RESET}  ${C_DIM}(${duplicadas} duplicada(s) omitida(s), ${invalidas} línea(s) no válida(s))${C_RESET}"
  pausa
}

gestionar_plantillas() {
  while true; do
    clear
    titulo "Plantillas personalizadas" "Crea, usa o elimina tus patrones de renombrado"
    echo
    opt 1 "📋" "Listar plantillas"
    opt 2 "✨" "Crear plantilla nueva"
    opt 3 "🗑️" "Eliminar plantilla"
    opt 4 "📤" "Exportar plantillas a archivo"
    opt 5 "📥" "Importar plantillas desde archivo"
    opt 0 "↩️" "Volver"
    echo
    read -rp "${C_PROMPT}➤ Opción: ${C_RESET}" op
    case "$op" in
      1) listar_plantillas; pausa ;;
      2) guardar_plantilla_sin_aplicar ;;
      3) eliminar_plantilla ;;
      4) exportar_plantillas ;;
      5) importar_plantillas ;;
      0) return ;;
      *) echo -e "${C_WARN}${I_WARN} Opción no válida.${C_RESET}"; pausa ;;
    esac
  done
}

# ---- Modo linea de comandos (sin menus) ----
# Permite invocar el script con argumentos, para integrarlo con Nemo, atajos
# de teclado de Cinnamon u otros scripts, sin pasar por los selectores graficos.

error_cli() { echo -e "${C_ERR}${I_ERR} $1${C_RESET}" >&2; exit 1; }

mostrar_version() { echo "Renombrador $VERSION"; }

mostrar_ayuda_cli() {
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

Ejemplos:
  renombrador.sh --carpeta ~/Fotos --recursivo --metodo fecha --fecha-origen exif --dry-run
  renombrador.sh --carpeta ~/Descargas --metodo prefijo --prefijo "2026_" --sin-confirmar
EOF
}

modo_cli() {
  CLI_MODE=1
  local carpeta="" archivos_cli=() recursivo="n" ocultos="n" incluir_carpetas="n" seguir_enlaces="n" filtro=""
  local metodo="" base="" mantener=0 inicio=1 digitos="" orden_criterio="actual"
  local prefijo="" sufijo="" buscar="" reemplazar="" regex=0
  local caso="" fecha_origen="actual" fecha_pos="final" espacios="guion_bajo"
  local plantilla_nombre="" patron="" modo_flag="mover" conflicto_flag="sufijo"

  while (( $# > 0 )); do
    case "$1" in
      --carpeta|--archivo|--filtro|--metodo|--base|--inicio|--digitos|--orden|--prefijo|--sufijo|\
      --buscar|--reemplazar|--caso|--fecha-origen|--fecha-pos|--espacios|--plantilla|--patron|\
      --modo|--conflicto)
        (( $# < 2 )) && error_cli "La opción '$1' necesita un valor." ;;
    esac
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
      --dry-run) CLI_DRY_RUN=1; shift ;;
      --sin-confirmar) CLI_SIN_CONFIRMAR=1; shift ;;
      --ayuda|--help|-h) mostrar_ayuda_cli; exit 0 ;;
      --version|-v) mostrar_version; exit 0 ;;
      *) error_cli "Argumento no reconocido: '$1' (usa --ayuda para ver las opciones)" ;;
    esac
  done

  case "$modo_flag" in
    mover) CLI_MODO="mover" ;;
    copiar) CLI_MODO="copiar" ;;
    *) error_cli "Valor de --modo no válido: '$modo_flag' (usa: mover, copiar)" ;;
  esac
  case "$conflicto_flag" in
    sufijo) CLI_CONFLICTO=1 ;;
    sobrescribir) CLI_CONFLICTO=2 ;;
    omitir) CLI_CONFLICTO=3 ;;
    *) error_cli "Valor de --conflicto no válido: '$conflicto_flag' (usa: sufijo, sobrescribir, omitir)" ;;
  esac
  [[ "$inicio" =~ ^[0-9]+$ ]] || inicio=1
  [[ -n "$digitos" && ! "$digitos" =~ ^[0-9]+$ ]] && error_cli "Valor de --digitos no válido: '$digitos'"

  if [[ -n "$carpeta" && ${#archivos_cli[@]} -gt 0 ]]; then
    error_cli "Usa --carpeta o --archivo, no ambos a la vez."
  elif [[ -n "$carpeta" ]]; then
    carpeta="${carpeta/#\~/$HOME}"
    [[ -d "$carpeta" ]] || error_cli "La carpeta no existe: '$carpeta'"
    filtro="${filtro// /}"; filtro="${filtro//./}"
    filtro=$(sed -E 's/,+/,/g; s/^,//; s/,$//' <<< "$filtro")
    construir_lista_desde_carpeta "$carpeta" "$recursivo" "$filtro" "$ocultos" "$incluir_carpetas" "$seguir_enlaces"
  elif (( ${#archivos_cli[@]} > 0 )); then
    FILES=()
    local a
    for a in "${archivos_cli[@]}"; do
      a="${a/#\~/$HOME}"
      if [[ -e "$a" || -L "$a" ]]; then FILES+=("$(normalizar_ruta "$a")"); else echo -e "${C_WARN}${I_WARN} No existe, se omite: '$a'${C_RESET}" >&2; fi
    done
  else
    error_cli "Falta el origen: usa --carpeta RUTA o --archivo RUTA (repetible)."
  fi
  (( ${#FILES[@]} == 0 )) && error_cli "No se encontraron elementos para renombrar."
  (( ${#FILES[@]} > 2000 )) && echo -e "${C_WARN}${I_WARN} Lote grande: ${#FILES[@]} elemento(s).${C_RESET}" >&2
  echo -e "${C_OK}${I_OK} ${#FILES[@]} elemento(s) encontrado(s).${C_RESET}"

  reiniciar_cola
  local i op pos sep modo_br delim err
  case "$metodo" in
    numeracion)
      local modo_num=1; (( mantener )) && modo_num=2
      (( modo_num == 1 )) && [[ -z "$base" ]] && error_cli "El método 'numeracion' necesita --base TEXTO (o --mantener-nombre)."
      [[ -z "$digitos" ]] && { digitos=${#FILES[@]}; digitos=${#digitos}; }
      local -a orden_idx=()
      case "$orden_criterio" in
        actual) orden_idx=("${!FILES[@]}") ;;
        fecha) mapfile -t orden_idx < <(orden_indices_por_criterio fecha) ;;
        exif) comprobar_herramientas_exif; mapfile -t orden_idx < <(orden_indices_por_criterio exif) ;;
        tamano) mapfile -t orden_idx < <(orden_indices_por_criterio tamano) ;;
        *) error_cli "Valor de --orden no válido: '$orden_criterio' (usa: actual, fecha, exif, tamano)" ;;
      esac
      transformar_numeracion "$modo_num" "$base" "$inicio" "$digitos" "${orden_idx[*]}"
      ;;
    prefijo) transformar_prefijo "$prefijo" ;;
    sufijo) transformar_sufijo "$sufijo" ;;
    buscar-reemplazar)
      [[ -z "$buscar" ]] && error_cli "El método 'buscar-reemplazar' necesita --buscar TEXTO."
      modo_br=1; (( regex )) && modo_br=2
      if (( regex )); then
        delim=$(delimitador_para "$buscar" "$reemplazar")
        err=$(validar_regex "$buscar" "$reemplazar" "$delim")
        [[ -n "$err" ]] && error_cli "Expresión regular no válida: $err"
      fi
      transformar_buscar_reemplazar "$modo_br" "$buscar" "$reemplazar"
      ;;
    mayus-minus)
      case "$caso" in
        minusculas) op=1 ;; mayusculas) op=2 ;; capitalizar) op=3 ;; frase) op=4 ;;
        *) error_cli "Valor de --caso no válido: '$caso' (usa: minusculas, mayusculas, capitalizar, frase)" ;;
      esac
      transformar_mayus_minus "$op"
      ;;
    fecha)
      case "$fecha_origen" in
        actual) op=1 ;; modificacion) op=2 ;; exif) op=3; comprobar_herramientas_exif ;;
        *) error_cli "Valor de --fecha-origen no válido: '$fecha_origen' (usa: actual, modificacion, exif)" ;;
      esac
      case "$fecha_pos" in
        inicio) pos=1 ;; final) pos=2 ;;
        *) error_cli "Valor de --fecha-pos no válido: '$fecha_pos' (usa: inicio, final)" ;;
      esac
      transformar_fecha "$op" "$pos"
      ;;
    limpiar)
      case "$espacios" in
        guion_bajo) sep="_" ;; guion) sep="-" ;; eliminar) sep="" ;;
        *) error_cli "Valor de --espacios no válido: '$espacios' (usa: guion_bajo, guion, eliminar)" ;;
      esac
      transformar_limpiar "$sep"
      ;;
    tipo) metodo_por_tipo ;;
    plantilla)
      [[ -z "$plantilla_nombre" ]] && error_cli "El método 'plantilla' necesita --plantilla NOMBRE."
      local n p encontrado=""
      while IFS='|' read -r n p; do [[ "$n" == "$plantilla_nombre" ]] && { encontrado="$p"; break; }; done < "$TEMPLATES_FILE"
      [[ -z "$encontrado" ]] && error_cli "No existe la plantilla «$plantilla_nombre»."
      aplicar_patron "$encontrado" "$inicio" "${digitos:-0}"
      ;;
    patron)
      [[ -z "$patron" ]] && error_cli "El método 'patron' necesita --patron 'TEXTO'."
      aplicar_patron "$patron" "$inicio" "${digitos:-0}"
      ;;
    "") error_cli "Falta --metodo (usa --ayuda para ver la lista de métodos)." ;;
    *) error_cli "Método no reconocido: '$metodo' (usa --ayuda para ver la lista de métodos)." ;;
  esac

  NUEVOS=("${NOMBRES_COLA[@]}")
  aplicar_renombrado
}

# Punto de entrada. Envuelto en una funcion (en vez de codigo suelto al final
# del archivo) para poder hacer "source" del script desde una bateria de
# pruebas sin disparar el menu interactivo; ver el guard al final del archivo.
main() {
case "${1:-}" in
  --instalar-nemo) comprobar_dependencias; instalar_nemo; exit 0 ;;
  --desinstalar-nemo) desinstalar_nemo; exit 0 ;;
  --ayuda|--help|-h) mostrar_ayuda_cli; exit 0 ;;
  --version|-v) mostrar_version; exit 0 ;;
esac

if [[ "${1:-}" == --* ]]; then
  modo_cli "$@"
  exit 0
fi

comprobar_dependencias

if (( $# > 0 )); then
  FILES=()
  for a in "$@"; do [[ -e "$a" || -L "$a" ]] && FILES+=("$(normalizar_ruta "$a")"); done
  if (( ${#FILES[@]} == 0 )); then
    echo -e "${C_ERR}${I_ERR} Ninguno de los elementos recibidos existe.${C_RESET}"; pausa
  else
    clear
    titulo "R E N O M B R A D O R" "${#FILES[@]} elemento(s) recibido(s) desde Nemo"
    echo -e "${C_OK}${I_OK} Listo para renombrar.${C_RESET}"
    menu_metodos
  fi
fi

while true; do
  clear
  titulo "R E N O M B R A D O R" "Renombrado de archivos por lotes"
  echo
  n_plantillas=0
  [[ -s "$TEMPLATES_FILE" ]] && n_plantillas=$(grep -c '' "$TEMPLATES_FILE")
  n_lotes=$(ls -1 "$HISTORY_DIR" 2>/dev/null | wc -l)
  deshacer_info=""
  (( n_lotes > 0 )) && deshacer_info="  ${C_DIM}(${n_lotes})${C_RESET}"
  nemo_label="Integrar con Nemo (clic derecho)"
  [[ -f "$NEMO_ACTION" ]] && nemo_label="Quitar integración con Nemo"
  opt 1 "📁" "Renombrar una carpeta completa"
  opt 2 "🗂" "Renombrar archivos seleccionados"
  opt 3 "🧩" "Gestionar plantillas personalizadas  ${C_DIM}(${n_plantillas})${C_RESET}"
  opt 4 "↩️" "Deshacer renombrado (historial)${deshacer_info}"
  opt 5 "🧩" "$nemo_label"
  opt 6 "🚪" "Salir"
  echo
  read -rp "${C_PROMPT}➤ Opción: ${C_RESET}" opcion
  case "$opcion" in
    1) opcion_carpeta ;;
    2) opcion_archivos ;;
    3) gestionar_plantillas ;;
    4) deshacer_ultimo ;;
    5) if [[ -f "$NEMO_ACTION" ]]; then desinstalar_nemo; else instalar_nemo; fi; pausa ;;
    6) despedida="👋"; (( SIN_EMOJI )) && despedida="•"
       echo -e "${C_OK}${despedida} ¡Hasta pronto!${C_RESET}"; exit 0 ;;
    *) echo -e "${C_WARN}${I_WARN} Opción no válida.${C_RESET}"; pausa ;;
  esac
done
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
