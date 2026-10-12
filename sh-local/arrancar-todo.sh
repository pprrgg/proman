#!/usr/bin/env bash
# ============================================
# Arranca todos los servicios de pkserver
#
#   ./arrancar-todo.sh            -> todos
#   ./arrancar-todo.sh n8n ia     -> solo los indicados
# ============================================

set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
IP="192.168.1.134"
BB="$HOME/Desktop/bb"

# Orden de arranque: "nombre|script|carpeta con start.sh (vacio si el script ya arranca)"
# typst-api va antes que n8n (su workflow genera PDFs con ella) y homepage al final
SERVICIOS=(
  "portainer|portainer.sh|"
  "jellyfin|jellyfin.sh|"
  "typst|fastapi-typst.sh|$BB/typst-api"
  "ia|ia.sh|$BB/ia"
  "n8n|n8n.sh|"
  "iot|iot-thingsboard.sh|"
  "proman|proman.sh|"
  "homepage|homepage.sh|"
)

if ! docker info >/dev/null 2>&1; then
  echo "ERROR: Docker no está disponible (¿está arrancado? ¿tu usuario está en el grupo docker?)" >&2
  exit 1
fi

FILTRO=("$@")

# true si no se han pasado argumentos o si el servicio esta entre ellos
seleccionado() {
  [ ${#FILTRO[@]} -eq 0 ] && return 0
  local s
  for s in "${FILTRO[@]}"; do [ "$s" = "$1" ] && return 0; done
  return 1
}

OK=()
FALLO=()

for entrada in "${SERVICIOS[@]}"; do
  IFS='|' read -r nombre script start_dir <<< "$entrada"
  seleccionado "$nombre" || continue

  echo
  echo "############################################"
  echo "# $nombre  ($script)"
  echo "############################################"

  if [ -n "$start_dir" ]; then
    # Estos scripts preguntan si arrancar; sin terminal no preguntan y se arrancan aqui
    if bash "$DIR/$script" </dev/null && "$start_dir/start.sh"; then
      OK+=("$nombre")
    else
      FALLO+=("$nombre")
    fi
  else
    if bash "$DIR/$script"; then
      OK+=("$nombre")
    else
      FALLO+=("$nombre")
    fi
  fi
done

echo
echo "============================================"
echo " Resumen"
echo "============================================"
[ ${#OK[@]} -gt 0 ]    && echo " OK:     ${OK[*]}"
[ ${#FALLO[@]} -gt 0 ] && echo " FALLO:  ${FALLO[*]}"
echo
echo " Dashboard: http://$IP:3000"
echo

docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'

[ ${#FALLO[@]} -eq 0 ]
