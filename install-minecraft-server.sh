#!/usr/bin/env bash

set -Eeuo pipefail

APP_NAME="Minecraft VPS Assistant"
DEFAULT_SERVICE_USER="minecraft"
DEFAULT_BASE_DIR="/opt/minecraft"
MINECRAFT_GAME_ID="432"

if [[ "${TRACE:-0}" == "1" ]]; then
  set -x
fi

RESET='\033[0m'
BOLD='\033[1m'
DIM='\033[2m'
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'

log() { printf "${GREEN}==>${RESET} %s\n" "$*"; }
info() { printf "${BLUE} •${RESET} %s\n" "$*"; }
warn() { printf "${YELLOW} !${RESET} %s\n" "$*"; }
die() { printf "${RED}Error:${RESET} %s\n" "$*" >&2; exit 1; }

on_error() {
  local exit_code=$?
  printf "\n${RED}La instalacion se detuvo en la linea %s.${RESET}\n" "${BASH_LINENO[0]}" >&2
  printf "Puedes relanzar el script; intenta no duplicar lo que ya exista.\n" >&2
  exit "$exit_code"
}
trap on_error ERR

banner() {
  clear 2>/dev/null || true
  cat <<'EOF'
 __  __ _                            __ _     __     ______  ____  
|  \/  (_)_ __   ___  ___ _ __ __ _ / _| |_   \ \   / /  _ \/ ___| 
| |\/| | | '_ \ / _ \/ __| '__/ _` | |_| __|   \ \ / /| |_) \___ \ 
| |  | | | | | |  __/ (__| | | (_| |  _| |_     \ V / |  __/ ___) |
|_|  |_|_|_| |_|\___|\___|_|  \__,_|_|  \__|     \_/  |_|   |____/ 
EOF
  printf "\n${BOLD}%s${RESET}\n" "$APP_NAME"
  printf "${DIM}Instalador simple para servidores Minecraft en Ubuntu/Debian.${RESET}\n\n"
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "Ejecuta este script como root: sudo bash $0"
  fi
}

detect_os() {
  [[ -r /etc/os-release ]] || die "No puedo detectar el sistema operativo."
  # shellcheck disable=SC1091
  source /etc/os-release
  case "${ID:-}" in
    ubuntu|debian) ;;
    *)
      case "${ID_LIKE:-}" in
        *debian*) ;;
        *) die "Este asistente soporta Ubuntu/Debian. Detectado: ${PRETTY_NAME:-desconocido}" ;;
      esac
      ;;
  esac
}

ask() {
  local prompt="$1"
  local default="${2:-}"
  local answer
  if [[ -n "$default" ]]; then
    read -r -p "$(printf "%b" "${CYAN}?${RESET} ${prompt} [${default}]: ")" answer
    printf '%s' "${answer:-$default}"
  else
    read -r -p "$(printf "%b" "${CYAN}?${RESET} ${prompt}: ")" answer
    printf '%s' "$answer"
  fi
}

ask_yes_no() {
  local prompt="$1"
  local default="${2:-s}"
  local answer suffix

  case "$default" in
    true|TRUE|True) default="s" ;;
    false|FALSE|False) default="n" ;;
  esac

  if [[ "$default" =~ ^[sS]$ ]]; then
    suffix="S/n"
  else
    suffix="s/N"
  fi

  while true; do
    read -r -p "$(printf "%b" "${CYAN}?${RESET} ${prompt} [${suffix}]: ")" answer
    answer="${answer:-$default}"
    case "$answer" in
      s|S|si|SI|Si|y|Y|yes|YES) return 0 ;;
      n|N|no|NO|No) return 1 ;;
      *) warn "Responde s o n." ;;
    esac
  done
}

ask_choice() {
  local prompt="$1"
  shift
  local choices=("$@")
  local index choice

  printf "%b\n" "${CYAN}?${RESET} ${prompt}" >&2
  for index in "${!choices[@]}"; do
    printf "  %s) %s\n" "$((index + 1))" "${choices[$index]}" >&2
  done

  while true; do
    read -r -p "Selecciona una opcion: " choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#choices[@]} )); then
      printf '%s' "${choices[$((choice - 1))]}"
      return
    fi
    warn "Opcion invalida."
  done
}

install_packages() {
  local java_package="$1"
  local packages=(
    ca-certificates
    curl
    jq
    unzip
    tar
    screen
    nano
    "$java_package"
  )

  log "Actualizando paquetes e instalando dependencias"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y "${packages[@]}"
}

ensure_user() {
  local service_user="$1"
  if id "$service_user" >/dev/null 2>&1; then
    info "El usuario $service_user ya existe."
  else
    log "Creando usuario del servicio: $service_user"
    useradd --system --home "$DEFAULT_BASE_DIR" --shell /usr/sbin/nologin "$service_user"
  fi
}

latest_paper_version() {
  curl -fsSL "https://api.papermc.io/v2/projects/paper" | jq -r '.versions[-1]'
}

latest_paper_build() {
  local version="$1"
  curl -fsSL "https://api.papermc.io/v2/projects/paper/versions/${version}" | jq -r '.builds[-1]'
}

latest_mojang_release() {
  curl -fsSL "https://piston-meta.mojang.com/mc/game/version_manifest_v2.json" | jq -r '.latest.release'
}

latest_fabric_game_version() {
  curl -fsSL "https://meta.fabricmc.net/v2/versions/game" | jq -r '[.[] | select(.stable == true)][0].version'
}

resolve_mc_version() {
  local loader="$1"
  local mc_version="$2"

  if [[ "$mc_version" != "latest" ]]; then
    printf '%s' "$mc_version"
    return
  fi

  case "$loader" in
    paper) latest_paper_version ;;
    fabric) latest_fabric_game_version ;;
    vanilla|forge|neoforge) latest_mojang_release ;;
    *) latest_mojang_release ;;
  esac
}

download_paper() {
  local mc_version="$1"
  local output="$2"
  local build jar_name url
  build="$(latest_paper_build "$mc_version")"
  jar_name="paper-${mc_version}-${build}.jar"
  url="https://api.papermc.io/v2/projects/paper/versions/${mc_version}/builds/${build}/downloads/${jar_name}"
  log "Descargando Paper ${mc_version}, build ${build}"
  curl -fL "$url" -o "$output"
}

download_vanilla() {
  local mc_version="$1"
  local output="$2"
  local manifest version_url server_url
  manifest="$(mktemp)"
  curl -fsSL "https://piston-meta.mojang.com/mc/game/version_manifest_v2.json" -o "$manifest"

  version_url="$(jq -r --arg v "$mc_version" '.versions[] | select(.id == $v) | .url' "$manifest")"
  [[ -n "$version_url" && "$version_url" != "null" ]] || die "No encontre Minecraft $mc_version en el manifiesto oficial."
  server_url="$(curl -fsSL "$version_url" | jq -r '.downloads.server.url')"
  [[ -n "$server_url" && "$server_url" != "null" ]] || die "La version $mc_version no tiene server.jar oficial."

  log "Descargando Vanilla ${mc_version}"
  curl -fL "$server_url" -o "$output"
}

download_fabric() {
  local mc_version="$1"
  local output="$2"
  local installer_version loader_version installer
  installer_version="$(curl -fsSL "https://meta.fabricmc.net/v2/versions/installer" | jq -r '.[0].version')"
  loader_version="$(curl -fsSL "https://meta.fabricmc.net/v2/versions/loader" | jq -r '.[0].version')"
  installer="$(mktemp --suffix=.jar)"

  log "Descargando instalador Fabric ${installer_version}"
  curl -fL "https://maven.fabricmc.net/net/fabricmc/fabric-installer/${installer_version}/fabric-installer-${installer_version}.jar" -o "$installer"

  log "Generando servidor Fabric para Minecraft ${mc_version}"
  java -jar "$installer" server \
    -mcversion "$mc_version" \
    -loader "$loader_version" \
    -downloadMinecraft \
    -dir "$(dirname "$output")"

  if [[ -f "$(dirname "$output")/fabric-server-launch.jar" ]]; then
    mv "$(dirname "$output")/fabric-server-launch.jar" "$output"
  elif [[ -f "$(dirname "$output")/server.jar" ]]; then
    mv "$(dirname "$output")/server.jar" "$output"
  else
    die "Fabric no genero el jar esperado."
  fi
}

download_manual_loader() {
  local loader="$1"
  local output="$2"
  local url
  warn "$loader cambia sus instaladores con frecuencia. Usare un enlace directo que pegues tu."
  url="$(ask "Pega la URL directa del instalador/jar de ${loader}, o deja vacio para hacerlo despues")"
  if [[ -z "$url" ]]; then
    warn "No se descargo server.jar. La instancia quedara preparada, pero no arrancara hasta instalar el jar."
    return 0
  fi
  curl -fL "$url" -o "$output"
}

write_eula_and_properties() {
  local server_dir="$1"
  local online_mode="$2"
  local port="$3"
  local motd="$4"
  local max_players="$5"
  local difficulty="$6"
  local pvp="$7"

  cat > "${server_dir}/eula.txt" <<EOF
eula=true
EOF

  cat > "${server_dir}/server.properties" <<EOF
# Generado por ${APP_NAME}
server-port=${port}
motd=${motd}
max-players=${max_players}
online-mode=${online_mode}
difficulty=${difficulty}
pvp=${pvp}
enable-command-block=false
spawn-protection=16
view-distance=10
simulation-distance=10
enable-query=false
enable-rcon=false
EOF
}

write_start_script() {
  local server_dir="$1"
  local min_ram="$2"
  local max_ram="$3"

  cat > "${server_dir}/start.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
cd "\$(dirname "\$0")"
if [[ ! -f server.jar ]]; then
  echo "No existe server.jar en \$(pwd). Instala el jar del servidor desde el asistente antes de arrancar."
  exit 1
fi
exec java -Xms${min_ram} -Xmx${max_ram} -jar server.jar nogui
EOF
  chmod +x "${server_dir}/start.sh"
}

write_systemd_service() {
  local service_name="$1"
  local service_user="$2"
  local server_dir="$3"
  local unit="/etc/systemd/system/${service_name}.service"

  cat > "$unit" <<EOF
[Unit]
Description=Minecraft Server (${service_name})
After=network.target

[Service]
User=${service_user}
Group=${service_user}
WorkingDirectory=${server_dir}
ExecStart=${server_dir}/start.sh
Restart=on-failure
RestartSec=10
SuccessExitStatus=0 143
NoNewPrivileges=true
ProtectHome=true
PrivateTmp=true
ReadWritePaths=${server_dir}

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable "$service_name"
}

install_firewall_rule() {
  local port="$1"
  if command -v ufw >/dev/null 2>&1; then
    ufw allow "${port}/tcp"
    info "Regla UFW creada para TCP/${port}."
  elif apt-get install -y ufw; then
    ufw allow OpenSSH || true
    ufw allow "${port}/tcp"
    ufw --force enable
    info "UFW instalado y regla creada para TCP/${port}."
  else
    warn "No pude configurar UFW automaticamente."
  fi
}

slug_from_modrinth_url() {
  local url="$1"
  sed -E 's#https?://modrinth\.com/(mod|plugin|datapack)/([^/?#]+).*#\2#' <<<"$url"
}

download_modrinth_project() {
  local url="$1"
  local mc_version="$2"
  local loader="$3"
  local mods_dir="$4"
  local slug version_api file_url file_name
  slug="$(slug_from_modrinth_url "$url")"
  [[ -n "$slug" && "$slug" != "$url" ]] || return 1

  version_api="https://api.modrinth.com/v2/project/${slug}/version?game_versions=[%22${mc_version}%22]&loaders=[%22${loader}%22]"
  file_url="$(curl -fsSL "$version_api" | jq -r '.[0].files[] | select(.primary == true) | .url' | head -n1)"
  if [[ -z "$file_url" || "$file_url" == "null" ]]; then
    file_url="$(curl -fsSL "$version_api" | jq -r '.[0].files[0].url')"
  fi
  [[ -n "$file_url" && "$file_url" != "null" ]] || return 1

  file_name="$(basename "${file_url%%\?*}")"
  log "Descargando Modrinth: ${slug}"
  curl -fL "$file_url" -o "${mods_dir}/${file_name}"
}

curseforge_slug_from_url() {
  local url="$1"
  sed -E 's#https?://www\.curseforge\.com/minecraft/(mc-mods|bukkit-plugins)/([^/?#]+).*#\2#' <<<"$url"
}

curseforge_file_id_from_url() {
  local url="$1"
  sed -nE 's#.*/files/([0-9]+).*#\1#p' <<<"$url"
}

download_curseforge_project() {
  local url="$1"
  local mc_version="$2"
  local loader="$3"
  local mods_dir="$4"
  local api_key="${CF_API_KEY:-}"
  local slug file_id search_json mod_id files_json download_url file_name class_id

  [[ -n "$api_key" ]] || return 2
  slug="$(curseforge_slug_from_url "$url")"
  [[ -n "$slug" && "$slug" != "$url" ]] || return 1

  case "$loader" in
    forge) class_id="6" ;;
    fabric|quilt) class_id="6" ;;
    *) class_id="6" ;;
  esac

  search_json="$(curl -fsSL -H "x-api-key: ${api_key}" \
    "https://api.curseforge.com/v1/mods/search?gameId=${MINECRAFT_GAME_ID}&classId=${class_id}&slug=${slug}")"
  mod_id="$(jq -r '.data[0].id // empty' <<<"$search_json")"
  [[ -n "$mod_id" ]] || return 1

  file_id="$(curseforge_file_id_from_url "$url")"
  if [[ -n "$file_id" ]]; then
    download_url="$(curl -fsSL -H "x-api-key: ${api_key}" \
      "https://api.curseforge.com/v1/mods/${mod_id}/files/${file_id}/download-url" | jq -r '.data // empty')"
  else
    files_json="$(curl -fsSL -H "x-api-key: ${api_key}" \
      "https://api.curseforge.com/v1/mods/${mod_id}/files?gameVersion=${mc_version}&pageSize=50")"
    download_url="$(jq -r --arg loader "$loader" '
      .data[]
      | select((.gameVersions | map(ascii_downcase) | index($loader)) or true)
      | .downloadUrl // empty
    ' <<<"$files_json" | head -n1)"
  fi

  [[ -n "$download_url" && "$download_url" != "null" ]] || return 1
  file_name="$(basename "${download_url%%\?*}")"
  log "Descargando CurseForge: ${slug}"
  curl -fL "$download_url" -o "${mods_dir}/${file_name}"
}

download_direct_file() {
  local url="$1"
  local target_dir="$2"
  local file_name
  file_name="$(basename "${url%%\?*}")"
  [[ "$file_name" == *.jar || "$file_name" == *.zip ]] || file_name="download-$(date +%s).jar"
  curl -fL "$url" -o "${target_dir}/${file_name}"
}

install_mods_from_file() {
  local list_file="$1"
  local mc_version="$2"
  local loader="$3"
  local mods_dir="$4"
  local line failed=0

  [[ -f "$list_file" ]] || die "No existe el archivo de mods: $list_file"
  mkdir -p "$mods_dir"

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    line="$(xargs <<<"$line")"
    [[ -z "$line" ]] && continue

    if [[ "$line" =~ modrinth\.com ]]; then
      if ! download_modrinth_project "$line" "$mc_version" "$loader" "$mods_dir"; then
        warn "No pude descargar desde Modrinth: $line"
        failed=$((failed + 1))
      fi
    elif [[ "$line" =~ curseforge\.com ]]; then
      if ! download_curseforge_project "$line" "$mc_version" "$loader" "$mods_dir"; then
        warn "CurseForge no permitio autodescarga para: $line"
        warn "Para CurseForge fiable define CF_API_KEY o usa enlaces directos a .jar cuando existan."
        failed=$((failed + 1))
      fi
    else
      if ! download_direct_file "$line" "$mods_dir"; then
        warn "No pude descargar enlace directo: $line"
        failed=$((failed + 1))
      fi
    fi
  done < "$list_file"

  if (( failed > 0 )); then
    warn "${failed} descarga(s) de mods fallaron. Revisa manualmente la carpeta ${mods_dir}."
  fi
}

print_summary() {
  local service_name="$1"
  local server_dir="$2"
  local port="$3"

  cat <<EOF

${GREEN}Listo.${RESET}

Servidor: ${server_dir}
Servicio:  ${service_name}
Puerto:    ${port}/tcp

Comandos utiles:
  sudo systemctl start ${service_name}
  sudo systemctl stop ${service_name}
  sudo systemctl status ${service_name}
  sudo journalctl -u ${service_name} -f

Primer arranque:
  sudo systemctl start ${service_name}

EOF
}

read_property() {
  local file="$1"
  local key="$2"
  local default="${3:-}"
  local value

  if [[ -f "$file" ]]; then
    value="$(grep -E "^${key}=" "$file" | tail -n1 | cut -d= -f2- || true)"
    printf '%s' "${value:-$default}"
  else
    printf '%s' "$default"
  fi
}

set_property() {
  local file="$1"
  local key="$2"
  local value="$3"
  local tmp

  [[ -f "$file" ]] || die "No existe ${file}"
  tmp="$(mktemp)"
  awk -v key="$key" -v value="$value" '
    index($0, key "=") == 1 {
      print key "=" value
      found = 1
      next
    }
    { print }
    END {
      if (!found) {
        print key "=" value
      }
    }
  ' "$file" > "$tmp"
  mv "$tmp" "$file"
}

backup_properties() {
  local server_dir="$1"
  local properties="${server_dir}/server.properties"
  local backup="${server_dir}/server.properties.backup.$(date +%Y%m%d-%H%M%S)"

  [[ -f "$properties" ]] || die "No existe ${properties}"
  cp "$properties" "$backup"
  info "Backup creado: ${backup}"
}

service_for_instance() {
  local server_dir="$1"
  local instance
  instance="$(basename "$server_dir")"

  if [[ -f "/etc/systemd/system/minecraft-${instance}.service" ]]; then
    printf 'minecraft-%s' "$instance"
  else
    ask "Nombre del servicio systemd" "minecraft-${instance}"
  fi
}

choose_instance() {
  local instances=()
  local dir choice index

  [[ -d "$DEFAULT_BASE_DIR" ]] || die "No existe ${DEFAULT_BASE_DIR}. Instala una instancia primero."

  while IFS= read -r dir; do
    [[ -f "${dir}/server.properties" ]] && instances+=("$dir")
  done < <(find "$DEFAULT_BASE_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)

  (( ${#instances[@]} > 0 )) || die "No encontre instancias con server.properties en ${DEFAULT_BASE_DIR}."

  printf "%b\n" "${CYAN}?${RESET} Elige una instancia" >&2
  for index in "${!instances[@]}"; do
    printf "  %s) %s\n" "$((index + 1))" "${instances[$index]}" >&2
  done

  while true; do
    read -r -p "Selecciona una opcion: " choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#instances[@]} )); then
      printf '%s' "${instances[$((choice - 1))]}"
      return
    fi
    warn "Opcion invalida."
  done
}

show_instance_summary() {
  local server_dir="$1"
  local service_name="$2"
  local properties="${server_dir}/server.properties"

  printf "\n${BOLD}Instancia:${RESET} %s\n" "$server_dir"
  printf "${BOLD}Servicio:${RESET}  %s\n" "$service_name"
  printf "gamemode=%s\n" "$(read_property "$properties" "gamemode" "survival")"
  printf "difficulty=%s\n" "$(read_property "$properties" "difficulty" "normal")"
  printf "online-mode=%s\n" "$(read_property "$properties" "online-mode" "true")"
  printf "pvp=%s\n" "$(read_property "$properties" "pvp" "true")"
  printf "white-list=%s\n" "$(read_property "$properties" "white-list" "false")"
  printf "max-players=%s\n" "$(read_property "$properties" "max-players" "20")"
  printf "server-port=%s\n\n" "$(read_property "$properties" "server-port" "25565")"

  if systemctl list-unit-files "${service_name}.service" >/dev/null 2>&1; then
    systemctl is-active --quiet "$service_name" && info "Estado: activo" || warn "Estado: detenido o fallando"
  else
    warn "No encontre el servicio ${service_name}.service en systemd."
  fi
}

edit_basic_properties() {
  local server_dir="$1"
  local properties="${server_dir}/server.properties"
  local value

  backup_properties "$server_dir"

  value="$(ask_choice "Modo de juego por defecto" "survival" "creative" "adventure" "spectator")"
  set_property "$properties" "gamemode" "$value"

  if ask_yes_no "Forzar ese modo al entrar los jugadores" "n"; then
    set_property "$properties" "force-gamemode" "true"
  else
    set_property "$properties" "force-gamemode" "false"
  fi

  value="$(ask_choice "Dificultad" "normal" "easy" "hard" "peaceful")"
  set_property "$properties" "difficulty" "$value"

  if ask_yes_no "Activar PvP" "$(read_property "$properties" "pvp" "true")"; then
    set_property "$properties" "pvp" "true"
  else
    set_property "$properties" "pvp" "false"
  fi

  if ask_yes_no "Activar command blocks" "n"; then
    set_property "$properties" "enable-command-block" "true"
  else
    set_property "$properties" "enable-command-block" "false"
  fi

  if ask_yes_no "Servidor premium / cuentas oficiales" "$(read_property "$properties" "online-mode" "true")"; then
    set_property "$properties" "online-mode" "true"
  else
    set_property "$properties" "online-mode" "false"
    warn "online-mode=false reduce la verificacion de identidad. Usa whitelist si es privado."
  fi

  log "Propiedades actualizadas."
}

edit_limits_and_network() {
  local server_dir="$1"
  local properties="${server_dir}/server.properties"
  local value

  backup_properties "$server_dir"

  value="$(ask "MOTD" "$(read_property "$properties" "motd" "Minecraft VPS")")"
  set_property "$properties" "motd" "$value"

  value="$(ask "Maximo de jugadores" "$(read_property "$properties" "max-players" "20")")"
  [[ "$value" =~ ^[0-9]+$ ]] && (( value >= 1 )) || die "Maximo de jugadores invalido: $value"
  set_property "$properties" "max-players" "$value"

  value="$(ask "View distance" "$(read_property "$properties" "view-distance" "10")")"
  [[ "$value" =~ ^[0-9]+$ ]] && (( value >= 2 && value <= 32 )) || die "View distance invalida: $value"
  set_property "$properties" "view-distance" "$value"

  value="$(ask "Simulation distance" "$(read_property "$properties" "simulation-distance" "10")")"
  [[ "$value" =~ ^[0-9]+$ ]] && (( value >= 2 && value <= 32 )) || die "Simulation distance invalida: $value"
  set_property "$properties" "simulation-distance" "$value"

  value="$(ask "Puerto" "$(read_property "$properties" "server-port" "25565")")"
  [[ "$value" =~ ^[0-9]+$ ]] && (( value >= 1 && value <= 65535 )) || die "Puerto invalido: $value"
  set_property "$properties" "server-port" "$value"

  log "Limites y red actualizados."
}

edit_access_properties() {
  local server_dir="$1"
  local properties="${server_dir}/server.properties"

  backup_properties "$server_dir"

  if ask_yes_no "Activar whitelist" "$(read_property "$properties" "white-list" "false")"; then
    set_property "$properties" "white-list" "true"
    set_property "$properties" "enforce-whitelist" "true"
  else
    set_property "$properties" "white-list" "false"
    set_property "$properties" "enforce-whitelist" "false"
  fi

  if ask_yes_no "Permitir vuelo" "$(read_property "$properties" "allow-flight" "false")"; then
    set_property "$properties" "allow-flight" "true"
  else
    set_property "$properties" "allow-flight" "false"
  fi

  if ask_yes_no "Generar animales" "$(read_property "$properties" "spawn-animals" "true")"; then
    set_property "$properties" "spawn-animals" "true"
  else
    set_property "$properties" "spawn-animals" "false"
  fi

  if ask_yes_no "Generar monstruos" "$(read_property "$properties" "spawn-monsters" "true")"; then
    set_property "$properties" "spawn-monsters" "true"
  else
    set_property "$properties" "spawn-monsters" "false"
  fi

  log "Acceso y mundo actualizados."
}

edit_ram() {
  local server_dir="$1"
  local start_script="${server_dir}/start.sh"
  local min_ram max_ram

  [[ -f "$start_script" ]] || die "No existe ${start_script}"
  cp "$start_script" "${start_script}.backup.$(date +%Y%m%d-%H%M%S)"

  min_ram="$(ask "RAM minima para Java" "1G")"
  max_ram="$(ask "RAM maxima para Java" "4G")"

  sed -i -E "s/-Xms[^ ]+/-Xms${min_ram}/; s/-Xmx[^ ]+/-Xmx${max_ram}/" "$start_script"
  chmod +x "$start_script"
  log "RAM actualizada en ${start_script}."
}

manage_mods_existing() {
  local server_dir="$1"
  local loader target_dir mc_version mods_list

  loader="$(ask_choice "Tipo de mods/plugins a instalar" "fabric" "forge" "neoforge" "paper-plugins")"
  mc_version="$(ask "Version de Minecraft para buscar mods" "latest")"
  if [[ "$mc_version" == "latest" ]]; then
    case "$loader" in
      fabric) mc_version="$(latest_fabric_game_version)" ;;
      *) mc_version="$(latest_mojang_release)" ;;
    esac
  fi

  mods_list="$(ask "Ruta al archivo .txt con enlaces")"
  if [[ "$loader" == "paper-plugins" ]]; then
    target_dir="${server_dir}/plugins"
    install_mods_from_file "$mods_list" "$mc_version" "bukkit" "$target_dir"
  else
    target_dir="${server_dir}/mods"
    install_mods_from_file "$mods_list" "$mc_version" "$loader" "$target_dir"
  fi
}

install_server_jar_existing() {
  local server_dir="$1"
  local loader mc_version

  loader="$(ask_choice "Tipo de server.jar a instalar/reemplazar" "paper" "vanilla" "fabric" "forge" "neoforge")"
  mc_version="$(ask "Version de Minecraft, o latest" "latest")"
  mc_version="$(resolve_mc_version "$loader" "$mc_version")"
  info "Version de Minecraft resuelta: ${mc_version}"

  if [[ -f "${server_dir}/server.jar" ]]; then
    cp "${server_dir}/server.jar" "${server_dir}/server.jar.backup.$(date +%Y%m%d-%H%M%S)"
    info "Backup creado del server.jar actual."
  fi

  case "$loader" in
    paper) download_paper "$mc_version" "${server_dir}/server.jar" ;;
    vanilla) download_vanilla "$mc_version" "${server_dir}/server.jar" ;;
    fabric) download_fabric "$mc_version" "${server_dir}/server.jar" ;;
    forge) download_manual_loader "Forge" "${server_dir}/server.jar" ;;
    neoforge) download_manual_loader "NeoForge" "${server_dir}/server.jar" ;;
    *) die "Loader no soportado: $loader" ;;
  esac

  if [[ -f "${server_dir}/server.jar" ]]; then
    log "server.jar instalado en ${server_dir}/server.jar."
  else
    warn "Aun no hay server.jar. La instancia queda preparada pero no puede arrancar todavia."
  fi
}

manage_service() {
  local service_name="$1"
  local action

  action="$(ask_choice "Accion del servicio" "start" "stop" "restart" "status" "logs")"
  case "$action" in
    start|stop|restart) systemctl "$action" "$service_name" ;;
    status) systemctl status "$service_name" --no-pager ;;
    logs) journalctl -u "$service_name" -n 80 --no-pager ;;
  esac
}

manage_instance() {
  local server_dir service_name option

  server_dir="$(choose_instance)"
  service_name="$(service_for_instance "$server_dir")"

  while true; do
    banner
    show_instance_summary "$server_dir" "$service_name"
    option="$(ask_choice "Que quieres hacer" \
      "modo/dificultad/premium" \
      "motd/jugadores/puerto/distancias" \
      "whitelist/vuelo/mobs" \
      "ram" \
      "instalar/reemplazar server.jar" \
      "instalar mods/plugins" \
      "servicio start/stop/restart/logs" \
      "salir")"

    case "$option" in
      "modo/dificultad/premium") edit_basic_properties "$server_dir" ;;
      "motd/jugadores/puerto/distancias") edit_limits_and_network "$server_dir" ;;
      "whitelist/vuelo/mobs") edit_access_properties "$server_dir" ;;
      "ram") edit_ram "$server_dir" ;;
      "instalar/reemplazar server.jar") install_server_jar_existing "$server_dir" ;;
      "instalar mods/plugins") manage_mods_existing "$server_dir" ;;
      "servicio start/stop/restart/logs") manage_service "$service_name" ;;
      "salir") return ;;
    esac

    if [[ "$option" != "servicio start/stop/restart/logs" ]] && ask_yes_no "Reiniciar ${service_name} para aplicar cambios" "s"; then
      systemctl restart "$service_name"
    fi
    read -r -p "Pulsa Enter para continuar..."
  done
}

install_server() {
  banner
  require_root
  detect_os

  local server_name server_dir service_name service_user loader mc_version java_version java_package
  local premium online_mode port motd max_players difficulty pvp min_ram max_ram install_mods mods_list

  server_name="$(ask "Nombre interno del servidor" "survival")"
  server_name="$(tr -cd 'a-zA-Z0-9_.-' <<<"$server_name")"
  [[ -n "$server_name" ]] || die "Nombre de servidor invalido."

  service_user="$(ask "Usuario Linux para ejecutar Minecraft" "$DEFAULT_SERVICE_USER")"
  service_name="minecraft-${server_name}"
  server_dir="${DEFAULT_BASE_DIR}/${server_name}"

  loader="$(ask_choice "Tipo de servidor" "paper" "vanilla" "fabric" "forge" "neoforge")"
  mc_version="$(ask "Version de Minecraft, o latest" "latest")"

  java_version="$(ask_choice "Version de Java" "21" "17" "8")"
  case "$java_version" in
    21) java_package="openjdk-21-jre-headless" ;;
    17) java_package="openjdk-17-jre-headless" ;;
    8) java_package="openjdk-8-jre-headless" ;;
    *) die "Java invalido." ;;
  esac

  if ask_yes_no "Servidor premium / cuentas oficiales de Microsoft" "s"; then
    premium="si"
    online_mode="true"
  else
    premium="no"
    online_mode="false"
    warn "Modo no premium significa online-mode=false. Usa whitelist y backups; reduce protecciones de identidad."
  fi

  port="$(ask "Puerto del servidor" "25565")"
  [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 )) || die "Puerto invalido: $port"
  motd="$(ask "MOTD" "Minecraft VPS")"
  max_players="$(ask "Maximo de jugadores" "20")"
  [[ "$max_players" =~ ^[0-9]+$ ]] && (( max_players >= 1 )) || die "Maximo de jugadores invalido: $max_players"
  difficulty="$(ask_choice "Dificultad" "normal" "easy" "hard" "peaceful")"
  if ask_yes_no "Activar PvP" "s"; then pvp="true"; else pvp="false"; fi
  min_ram="$(ask "RAM minima para Java" "1G")"
  max_ram="$(ask "RAM maxima para Java" "4G")"

  install_packages "$java_package"
  ensure_user "$service_user"

  log "Preparando directorio ${server_dir}"
  mkdir -p "$server_dir"
  chown -R "${service_user}:${service_user}" "$DEFAULT_BASE_DIR"

  mc_version="$(resolve_mc_version "$loader" "$mc_version")"
  info "Version de Minecraft resuelta: ${mc_version}"

  case "$loader" in
    paper) download_paper "$mc_version" "${server_dir}/server.jar" ;;
    vanilla) download_vanilla "$mc_version" "${server_dir}/server.jar" ;;
    fabric) download_fabric "$mc_version" "${server_dir}/server.jar" ;;
    forge) download_manual_loader "Forge" "${server_dir}/server.jar" ;;
    neoforge) download_manual_loader "NeoForge" "${server_dir}/server.jar" ;;
    *) die "Loader no soportado: $loader" ;;
  esac

  write_eula_and_properties "$server_dir" "$online_mode" "$port" "$motd" "$max_players" "$difficulty" "$pvp"
  write_start_script "$server_dir" "$min_ram" "$max_ram"

  if [[ "$loader" =~ ^(fabric|forge|neoforge|paper)$ ]] && ask_yes_no "Quieres instalar mods/plugins desde una lista de enlaces" "n"; then
    mods_list="$(ask "Ruta al archivo .txt con enlaces")"
    if [[ "$loader" == "paper" ]]; then
      install_mods_from_file "$mods_list" "$mc_version" "bukkit" "${server_dir}/plugins"
    else
      install_mods_from_file "$mods_list" "$mc_version" "$loader" "${server_dir}/mods"
    fi
  fi

  chown -R "${service_user}:${service_user}" "$server_dir"
  write_systemd_service "$service_name" "$service_user" "$server_dir"

  if ask_yes_no "Abrir puerto ${port}/tcp en UFW" "s"; then
    install_firewall_rule "$port"
  fi

  if [[ ! -f "${server_dir}/server.jar" ]]; then
    warn "No se arrancara ahora porque falta ${server_dir}/server.jar."
    warn "Luego usa: editar instancia existente -> instalar/reemplazar server.jar."
  elif ask_yes_no "Arrancar el servidor ahora" "n"; then
    systemctl start "$service_name"
  fi

  info "Configuracion premium: ${premium}"
  print_summary "$service_name" "$server_dir" "$port"
}

main() {
  local option

  banner
  require_root
  detect_os

  option="$(ask_choice "Que quieres hacer" "instalar nuevo servidor" "editar instancia existente" "salir")"
  case "$option" in
    "instalar nuevo servidor") install_server ;;
    "editar instancia existente") manage_instance ;;
    "salir") exit 0 ;;
  esac
}

main "$@"
