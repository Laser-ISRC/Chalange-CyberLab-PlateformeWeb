#!/usr/bin/env bash
#
# deployLab.sh — appelé par le backend du portail après createTenant.sh.
#
#   entrée  (stdin)  : projet, réseaux, flavor, VM et cloud-init encodés en JSON
#   sortie  (stdout) : objet JSON de résultat
#   progression      : lignes sur stderr, relayées à la page web
#
# Déploie dans le tenant : un routeur raccordé au réseau externe, deux réseaux
# internes avec leurs sous-réseaux, un groupe de sécurité SSH + ICMP et une VM
# Debian. L'image, le flavor et la keypair sont configurés lors de l'appairage
# par setup-remote.sh.
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "${HERE}/remote-call.sh"

echo "Préparation du déploiement de l'infrastructure de base" >&2
run_action deploy-lab
