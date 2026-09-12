#!/usr/bin/env bash
set -euo pipefail
umask 077

USERNAME=""
ASSUME_YES=0
LOCAL_ONLY=0
DOMAIN="${OS_DOMAIN:-Default}"

fail() { printf 'Échec : %s\n' "$*" >&2; exit 1; }
info() { printf '%s\n' "$*"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --yes) ASSUME_YES=1; shift ;;
        --local) LOCAL_ONLY=1; shift ;;
        -*) fail "option inconnue : $1" ;;
        *) [ -z "$USERNAME" ] || fail "un seul utilisateur peut être sélectionné."
           USERNAME="$1"; shift ;;
    esac
done

[ "$(id -u)" -eq 0 ] || fail "exécutez ce script avec sudo."
if [ -n "$USERNAME" ]; then
    printf '%s' "$USERNAME" | grep -Eq '^[a-z][a-z0-9._-]{2,31}$' \
        || fail "identifiant utilisateur invalide."
fi

if command -v microstack.openstack >/dev/null 2>&1; then
    OSC=(microstack.openstack)
elif command -v openstack >/dev/null 2>&1; then
    OSC=(openstack)
elif [ "$LOCAL_ONLY" -eq 0 ]; then
    [ -r /etc/microstack-portal/portal.env ] \
        || fail "configuration du portail introuvable dans /etc/microstack-portal/portal.env."
    . /etc/microstack-portal/portal.env
    [ -n "${OPENSTACK_HOST:-}" ] || fail "OPENSTACK_HOST absent de portal.env."
    [ -n "${OPENSTACK_SSH_USER:-}" ] || fail "OPENSTACK_SSH_USER absent de portal.env."

    SELF="$(readlink -f "${BASH_SOURCE[0]}")"
    REMOTE_SCRIPT="/tmp/delete-microstack-tenant-$$-${RANDOM}.sh"
    SSH_TARGET="${OPENSTACK_SSH_USER}@${OPENSTACK_HOST}"
    SSH_OPTS=(-p "${OPENSTACK_SSH_PORT:-22}" -o ConnectTimeout=10)

    info "Le client OpenStack est distant : relais vers ${SSH_TARGET}."
    ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "umask 077; cat > '${REMOTE_SCRIPT}'" < "$SELF" \
        || fail "transfert du script vers le serveur OpenStack impossible."

    REMOTE_COMMAND="sudo bash '${REMOTE_SCRIPT}' --local"
    [ -n "$USERNAME" ] && REMOTE_COMMAND+=" '${USERNAME}'"
    [ "$ASSUME_YES" -eq 1 ] && REMOTE_COMMAND+=" --yes"
    REMOTE_COMMAND+="; rc=\$?; rm -f '${REMOTE_SCRIPT}'; exit \$rc"
    ssh -t "${SSH_OPTS[@]}" "$SSH_TARGET" "$REMOTE_COMMAND" \
        || fail "suppression distante interrompue ou en échec."
    exit 0
else
    fail "aucun client OpenStack trouvé sur le serveur OpenStack."
fi

if [ -z "${OS_AUTH_URL:-}" ]; then
    for rc in /var/snap/microstack/common/etc/microstack.rc \
              /var/snap/microstack/common/etc/admin-openrc.sh \
              /root/admin-openrc.sh /etc/openstack/admin-openrc.sh; do
        if [ -r "$rc" ]; then
            . "$rc"
            break
        fi
    done
fi

[ -n "${OS_AUTH_URL:-}" ] || fail "identifiants administrateur OpenStack introuvables."
[ -r /etc/default/microstack-tenant ] && . /etc/default/microstack-tenant
osc() { "${OSC[@]}" "$@"; }

info ""
info "Utilisateurs présents dans le domaine ${DOMAIN} :"
osc user list --domain "$DOMAIN" || fail "lecture des utilisateurs impossible."
info ""
info "Projets présents dans le domaine ${DOMAIN} :"
osc project list --domain "$DOMAIN" || fail "lecture des projets impossible."
info ""

if [ -z "$USERNAME" ]; then
    [ -r /dev/tty ] || fail "sélection impossible sans terminal."
    printf 'Identifiant exact de l’utilisateur à supprimer : ' > /dev/tty
    IFS= read -r USERNAME < /dev/tty
    printf '%s' "$USERNAME" | grep -Eq '^[a-z][a-z0-9._-]{2,31}$' \
        || fail "identifiant utilisateur invalide."
fi

PROJECT="${USERNAME}-project"
PROJECT_ID="$(osc project show -f value -c id "$PROJECT" 2>/dev/null || true)"
USER_ID="$(osc user show --domain "$DOMAIN" -f value -c id "$USERNAME" 2>/dev/null || true)"

if [ -z "$PROJECT_ID" ] && [ -z "$USER_ID" ]; then
    fail "ni le projet ${PROJECT}, ni l'utilisateur ${USERNAME} n'existent."
fi

info ""
info "Suppression ciblée :"
info "  domaine     : ${DOMAIN}"
info "  utilisateur : ${USERNAME}${USER_ID:+ (${USER_ID})}"
info "  projet      : ${PROJECT}${PROJECT_ID:+ (${PROJECT_ID})}"
info "Toutes les ressources appartenant exclusivement à ce projet seront supprimées."

if [ "$ASSUME_YES" -ne 1 ]; then
    [ -r /dev/tty ] || fail "confirmation impossible sans terminal."
    printf 'Saisissez exactement DELETE %s %s : ' "$USERNAME" "$PROJECT" > /dev/tty
    IFS= read -r CONFIRM < /dev/tty
    [ "$CONFIRM" = "DELETE ${USERNAME} ${PROJECT}" ] \
        || fail "confirmation incorrecte, aucune suppression effectuée."
fi

if [ -n "$PROJECT_ID" ]; then
    mapfile -t SERVER_IDS < <(osc server list --all-projects --project "$PROJECT_ID" -f value -c ID 2>/dev/null || true)
    for id in "${SERVER_IDS[@]}"; do
        [ -n "$id" ] || continue
        info "Suppression de l'instance ${id}"
        osc server delete --wait "$id" || fail "suppression de l'instance ${id} impossible."
    done

    KEYPAIR_NAME="${USERNAME}-cyberlab-key"
    if osc keypair show "$KEYPAIR_NAME" >/dev/null 2>&1; then
        info "Suppression de la keypair Nova ${KEYPAIR_NAME}"
        osc keypair delete "$KEYPAIR_NAME" || fail "suppression de la keypair impossible."
    fi

    mapfile -t FLOATING_IDS < <(osc floating ip list --project "$PROJECT_ID" -f value -c ID 2>/dev/null || true)
    for id in "${FLOATING_IDS[@]}"; do
        [ -n "$id" ] || continue
        info "Suppression de l'IP flottante ${id}"
        osc floating ip delete "$id" || fail "suppression de l'IP flottante ${id} impossible."
    done

    mapfile -t SUBNET_IDS < <(osc subnet list --project "$PROJECT_ID" -f value -c ID 2>/dev/null || true)
    mapfile -t ROUTER_IDS < <(osc router list --project "$PROJECT_ID" -f value -c ID 2>/dev/null || true)
    for router_id in "${ROUTER_IDS[@]}"; do
        [ -n "$router_id" ] || continue
        for subnet_id in "${SUBNET_IDS[@]}"; do
            [ -n "$subnet_id" ] || continue
            osc router remove subnet "$router_id" "$subnet_id" >/dev/null 2>&1 || true
        done
        osc router unset --external-gateway "$router_id" >/dev/null 2>&1 || true
        info "Suppression du routeur ${router_id}"
        osc router delete "$router_id" || fail "suppression du routeur ${router_id} impossible."
    done

    mapfile -t PORT_IDS < <(osc port list --project "$PROJECT_ID" -f value -c ID 2>/dev/null || true)
    for id in "${PORT_IDS[@]}"; do
        [ -n "$id" ] || continue
        osc port delete "$id" >/dev/null 2>&1 || true
    done

    for id in "${SUBNET_IDS[@]}"; do
        [ -n "$id" ] || continue
        info "Suppression du sous-réseau ${id}"
        osc subnet delete "$id" || fail "suppression du sous-réseau ${id} impossible."
    done

    mapfile -t NETWORK_IDS < <(osc network list --project "$PROJECT_ID" -f value -c ID 2>/dev/null || true)
    for id in "${NETWORK_IDS[@]}"; do
        [ -n "$id" ] || continue
        info "Suppression du réseau ${id}"
        osc network delete "$id" || fail "suppression du réseau ${id} impossible."
    done

    mapfile -t VOLUME_IDS < <(osc volume list --all-projects --project "$PROJECT_ID" -f value -c ID 2>/dev/null || true)
    for id in "${VOLUME_IDS[@]}"; do
        [ -n "$id" ] || continue
        info "Suppression du volume ${id}"
        osc volume delete "$id" || fail "suppression du volume ${id} impossible."
    done

    # Le groupe de sécurité du lab survit sinon à la suppression du projet.
    mapfile -t SG_IDS < <(osc security group list --project "$PROJECT_ID" -f value -c ID 2>/dev/null || true)
    for id in "${SG_IDS[@]}"; do
        [ -n "$id" ] || continue
        info "Suppression du groupe de sécurité ${id}"
        osc security group delete "$id" || fail "suppression du groupe de sécurité ${id} impossible."
    done

    info "Suppression du projet ${PROJECT}"
    osc project delete "$PROJECT_ID" \
        || fail "suppression du projet impossible ; l'utilisateur est conservé."
fi

if [ -n "$USER_ID" ]; then
    info "Suppression de l'utilisateur ${USERNAME}"
    osc user delete "$USER_ID" || fail "suppression de l'utilisateur impossible."
fi

info "Suppression terminée : seules les ressources du tenant ${USERNAME} ont été ciblées."
