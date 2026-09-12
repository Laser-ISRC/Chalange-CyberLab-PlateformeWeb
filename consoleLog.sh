#!/usr/bin/env bash
#
# consoleLog.sh — appelé par le backend du portail pour relire la console
# d'une VM déployée (journal série + URL novnc).
#
#   entrée  (stdin)  : {"project","server_id"}
#   sortie  (stdout) : objet JSON de résultat
#   progression      : lignes sur stderr, relayées à la page web
#
# Sert de console de secours quand l'onglet Console d'Horizon ne répond pas.
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "${HERE}/remote-call.sh"

echo "Lecture de la console de la VM" >&2
run_action console
