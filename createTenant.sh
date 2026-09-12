#!/usr/bin/env bash
#
# createTenant.sh — appelé par le backend du portail.
#
#   entrée  (stdin)  : {"username","password","email","description","project",
#                       "role","domain"}
#   sortie  (stdout) : objet JSON de résultat
#   progression      : lignes sur stderr, relayées à la page web
#
# Le script ne crée rien lui-même : il ouvre une session SSH vers l'hôte
# MicroStack et transmet la charge utile au helper microstack-tenant, qui
# détient seul les identifiants admin.
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "${HERE}/remote-call.sh"

echo "Préparation de la demande de création de tenant" >&2
run_action create
