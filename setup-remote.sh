#!/usr/bin/env bash
#
# setup-remote.sh — installe le helper sur l'hôte Ubuntu qui porte MicroStack et
# y autorise la clé du portail, avec une commande forcée.
#
# À lancer depuis la VM du portail, APRÈS install.sh, avec un accès SSH
# administrateur existant vers l'hôte MicroStack (votre propre compte).
#
#   sudo ./setup-remote.sh --host 192.168.1.50 --user ubuntu
#
# Ce script est le seul moment où un accès privilégié à l'hôte MicroStack est
# nécessaire. Ensuite, le portail ne dispose que des actions ping, create et deploy-lab.
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -r "${HERE}/remote/microstack-tenant.sh" ]; then
    HELPER="${HERE}/remote/microstack-tenant.sh"
elif [ -r "${HERE}/../remote/microstack-tenant.sh" ]; then
    HELPER="${HERE}/../remote/microstack-tenant.sh"
else
    HELPER="${HERE}/microstack-tenant.sh"
fi
ETCDIR="/etc/microstack-portal"

HOST=""
SSH_USER=""
IDENTITY=""
PUBKEY="${ETCDIR}/id_ed25519.pub"
PORT=22
LAB_IMAGE="Debian12"
LAB_IMAGE_URL="https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2"
LAB_FLAVOR="kiwi-concombre"

usage() {
    cat <<'USAGE'
Usage : setup-remote.sh --host <ip> [options]

  --host <ip|nom>   Hôte MicroStack (IP flottante). Requis.
  --user <compte>   Compte Linux avec sudo sur cet hôte.
                    Demandé dans le terminal si cette option est absente.
  --port <n>        Port SSH (défaut : 22).
  --identity <clé>  Clé privée d'administration à utiliser pour cette
                    installation. Par défaut, l'agent ou la configuration SSH.
  --pubkey <fic>    Clé publique du portail à autoriser
                    (défaut : /etc/microstack-portal/id_ed25519.pub).
  --lab-image <nom> Nom de l'image Debian (défaut : Debian12).
  --lab-flavor <nom> Flavor existant (défaut : kiwi-concombre).
  -h, --help
USAGE
}

while [ $# -gt 0 ]; do
    case "$1" in
        --host)     HOST="${2:?}"; shift 2 ;;
        --user)     SSH_USER="${2:?}"; shift 2 ;;
        --port)     PORT="${2:?}"; shift 2 ;;
        --identity) IDENTITY="${2:?}"; shift 2 ;;
        --pubkey)     PUBKEY="${2:?}"; shift 2 ;;
        --lab-image)  LAB_IMAGE="${2:?}"; shift 2 ;;
        --lab-flavor) LAB_FLAVOR="${2:?}"; shift 2 ;;
        -h|--help)    usage; exit 0 ;;
        *) echo "Option inconnue : $1" >&2; usage; exit 2 ;;
    esac
done

step() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
info() { printf '   %s\n' "$*"; }
die()  { printf '\n\033[31mÉchec : %s\033[0m\n' "$*" >&2; exit 1; }

[ -n "$HOST" ] || { usage; die "--host est obligatoire."; }
if [ -z "$SSH_USER" ]; then
    [ -r /dev/tty ] || die "précisez le compte SSH administrateur avec --user."
    printf 'Compte Linux SSH avec accès sudo sur %s : ' "$HOST" > /dev/tty
    IFS= read -r SSH_USER < /dev/tty
fi
[ -n "$SSH_USER" ] || die "le compte SSH administrateur est obligatoire."
printf '%s' "$SSH_USER" | grep -Eq '^[a-z_][a-z0-9_-]*[$]?$' || die "compte SSH invalide."
printf '%s' "$PORT" | grep -Eq '^[0-9]{1,5}$' || die "port SSH invalide."
for value in "$LAB_IMAGE" "$LAB_FLAVOR"; do
    [ -z "$value" ] || printf '%s' "$value" | grep -Eq '^[A-Za-z0-9._-]{1,128}$' \
        || die "nom d'image, de flavor ou de keypair invalide."
done
[ -r "$HELPER" ] || die "helper introuvable : $HELPER"
[ -r "$PUBKEY" ] || die "clé publique du portail introuvable : $PUBKEY (lancez install.sh d'abord)"

PUB="$(cat "$PUBKEY")"
printf '%s' "$PUB" | grep -Eq '^(ssh-ed25519|ssh-rsa|ecdsa-sha2-[a-z0-9-]+) [A-Za-z0-9+/=]+( .*)?$' \
    || die "le fichier fourni n'est pas une clé publique SSH valide."

HELPER_B64="$(base64 -w0 < "$HELPER")"

SSH_OPTS=(-p "$PORT" -o ConnectTimeout=10)
[ -n "$IDENTITY" ] && SSH_OPTS+=(-i "$IDENTITY" -o IdentitiesOnly=yes)

step "Préparation du script d'appairage distant"

BOOTSTRAP="$(mktemp)"
trap 'rm -f "$BOOTSTRAP"' EXIT

cat > "$BOOTSTRAP" <<'REMOTE'
set -euo pipefail
HELPER_B64='@@HELPER_B64@@'
PUB='@@PUB@@'
ACCOUNT='@@ACCOUNT@@'
LAB_IMAGE='@@LAB_IMAGE@@'
LAB_IMAGE_URL='@@LAB_IMAGE_URL@@'
LAB_FLAVOR='@@LAB_FLAVOR@@'

echo "-- installation du helper"
printf '%s' "$HELPER_B64" | base64 -d > /usr/local/bin/microstack-tenant
chown root:root /usr/local/bin/microstack-tenant
chmod 0755 /usr/local/bin/microstack-tenant

DEFAULT_TMP="$(mktemp)"
if [ -r /etc/default/microstack-tenant ]; then
    grep -Ev '^MSK_LAB_(CREATE_VM|IMAGE|IMAGE_URL|FLAVOR|KEYPAIR)=' \
        /etc/default/microstack-tenant > "$DEFAULT_TMP" || true
fi
printf 'MSK_LAB_IMAGE=%s\nMSK_LAB_IMAGE_URL=%s\nMSK_LAB_FLAVOR=%s\n' \
    "$LAB_IMAGE" "$LAB_IMAGE_URL" "$LAB_FLAVOR" >> "$DEFAULT_TMP"
install -m 0600 -o root -g root "$DEFAULT_TMP" /etc/default/microstack-tenant
rm -f "$DEFAULT_TMP"

echo "-- règle sudo dédiée"
# Une seule commande, sans argument libre : le compte SSH ne gagne rien d'autre.
printf '%s ALL=(root) NOPASSWD: /usr/local/bin/microstack-tenant\n' "$ACCOUNT" \
    > /etc/sudoers.d/microstack-tenant
chmod 0440 /etc/sudoers.d/microstack-tenant
visudo -cf /etc/sudoers.d/microstack-tenant >/dev/null \
    || { rm -f /etc/sudoers.d/microstack-tenant; echo "règle sudo invalide" >&2; exit 1; }

echo "-- autorisation de la clé du portail"
HOME_DIR="$(getent passwd "$ACCOUNT" | cut -d: -f6)"
[ -n "$HOME_DIR" ] || { echo "compte $ACCOUNT introuvable" >&2; exit 1; }
install -d -m 0700 -o "$ACCOUNT" -g "$ACCOUNT" "$HOME_DIR/.ssh"
touch "$HOME_DIR/.ssh/authorized_keys"
chmod 0600 "$HOME_DIR/.ssh/authorized_keys"
chown "$ACCOUNT:$ACCOUNT" "$HOME_DIR/.ssh/authorized_keys"

KEYDATA="$(printf '%s' "$PUB" | awk '{print $2}')"
# On retire une éventuelle autorisation antérieure de la même clé avant de la
# réécrire : sinon une ancienne ligne sans commande forcée resterait valable.
grep -v -F "$KEYDATA" "$HOME_DIR/.ssh/authorized_keys" > "$HOME_DIR/.ssh/authorized_keys.new" || true
{
  printf 'command="/usr/local/bin/microstack-tenant",no-port-forwarding,'
  printf 'no-agent-forwarding,no-X11-forwarding,no-pty,no-user-rc %s\n' "$PUB"
} >> "$HOME_DIR/.ssh/authorized_keys.new"
mv "$HOME_DIR/.ssh/authorized_keys.new" "$HOME_DIR/.ssh/authorized_keys"
chmod 0600 "$HOME_DIR/.ssh/authorized_keys"
chown "$ACCOUNT:$ACCOUNT" "$HOME_DIR/.ssh/authorized_keys"

echo "-- contrôle du client openstack"
if command -v microstack.openstack >/dev/null 2>&1; then
    echo "   microstack.openstack présent"
elif command -v openstack >/dev/null 2>&1; then
    echo "   client openstack présent"
else
    echo "   AUCUN client openstack trouvé : le helper échouera" >&2
fi

echo "-- appairage terminé"
REMOTE

python3 - "$BOOTSTRAP" "$HELPER_B64" "$PUB" "$SSH_USER" \
    "$LAB_IMAGE" "$LAB_IMAGE_URL" "$LAB_FLAVOR" <<'PY'
import sys
path, helper_b64, pub, account, image, image_url, flavor = sys.argv[1:8]
with open(path) as fh:
    text = fh.read()
text = text.replace("@@HELPER_B64@@", helper_b64)
text = text.replace("@@PUB@@", pub.strip())
text = text.replace("@@ACCOUNT@@", account)
text = text.replace("@@LAB_IMAGE@@", image)
text = text.replace("@@LAB_IMAGE_URL@@", image_url)
text = text.replace("@@LAB_FLAVOR@@", flavor)
with open(path, "w") as fh:
    fh.write(text)
PY

step "Exécution sur ${SSH_USER}@${HOST}"
info "un mot de passe sudo peut être demandé."

REMOTE_BOOTSTRAP="/tmp/microstack-portal-bootstrap-$$-${RANDOM}.sh"
ssh "${SSH_OPTS[@]}" "${SSH_USER}@${HOST}" \
    "umask 077; cat > '${REMOTE_BOOTSTRAP}'" < "$BOOTSTRAP" \
    || die "transfert du script d'appairage impossible."
ssh -t "${SSH_OPTS[@]}" "${SSH_USER}@${HOST}" \
    "sudo bash '${REMOTE_BOOTSTRAP}'; rc=\$?; rm -f '${REMOTE_BOOTSTRAP}'; exit \$rc" \
    || die "l'appairage distant a échoué."

step "Enregistrement de l'empreinte de l'hôte"

install -d -m 0755 "$ETCDIR"
ssh-keyscan -p "$PORT" -H "$HOST" > "${ETCDIR}/known_hosts.new" 2>/dev/null \
    || die "ssh-keyscan n'a rien récupéré."
mv "${ETCDIR}/known_hosts.new" "${ETCDIR}/known_hosts"
chmod 0644 "${ETCDIR}/known_hosts"
info "empreinte enregistrée dans ${ETCDIR}/known_hosts"
info "à comparer avec ce que renvoie, sur l'hôte MicroStack :"
info "   ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub"

step "Test de la clé restreinte"

KEY="${PUBKEY%.pub}"
SSH_RUN=()
if id -u mspportal >/dev/null 2>&1; then
    chown mspportal:mspportal "$KEY"
    chmod 0600 "$KEY"
    SSH_RUN=(sudo -u mspportal --)
else
    chmod 0600 "$KEY"
fi
TEST_FAILED=0
if printf '{}' | "${SSH_RUN[@]}" ssh -i "$KEY" -o BatchMode=yes -o IdentitiesOnly=yes \
        -o StrictHostKeyChecking=yes -o UserKnownHostsFile="${ETCDIR}/known_hosts" \
        -p "$PORT" "${SSH_USER}@${HOST}" ping; then
    printf '\n\033[32mLe portail joint Keystone avec les droits admin.\033[0m\n'
else
    printf '\n\033[33mLe test a échoué. À vérifier sur la machine MicroStack :\033[0m\n'
    cat <<'HINT'
   - que les identifiants admin sont lisibles par root
     (/var/snap/microstack/common/etc/microstack.rc)
   - le retour de : sudo -n /usr/local/bin/microstack-tenant ping < /dev/null
   - le journal : sudo journalctl -u ssh -n 30
HINT
    TEST_FAILED=1
fi

step "Vérification du cloisonnement"
if printf '{}' | "${SSH_RUN[@]}" ssh -i "$KEY" -o BatchMode=yes -o IdentitiesOnly=yes \
        -o StrictHostKeyChecking=yes -o UserKnownHostsFile="${ETCDIR}/known_hosts" \
        -p "$PORT" "${SSH_USER}@${HOST}" "id" >/dev/null 2>&1; then
    printf '\033[31m   ANOMALIE : une commande arbitraire a été acceptée.\033[0m\n'
    printf '   La commande forcée ne s applique pas : reprenez authorized_keys.\n'
    TEST_FAILED=1
else
    info "une commande arbitraire est bien refusée par la commande forcée."
fi

[ "$TEST_FAILED" -eq 0 ] || die "les contrôles de l'appairage distant ont échoué."
