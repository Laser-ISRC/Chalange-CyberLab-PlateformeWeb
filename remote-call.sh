#!/usr/bin/env bash
#
# remote-call.sh — brique commune à createTenant.sh et deployLab.sh.
# Sourcé, jamais exécuté directement.
#
# Ouvre une session SSH vers l'hôte MicroStack et invoque le helper distant.
# La charge utile JSON traverse stdin : aucune donnée saisie par l'utilisateur
# n'est concaténée dans une ligne de commande, ni localement ni à distance.

emit_error() {
    MSK_ERR="$1" python3 -c \
        'import json,os;print(json.dumps({"ok":False,"error":os.environ["MSK_ERR"]},ensure_ascii=False))'
}

require_env() {
    local missing=0
    for v in "$@"; do
        if [ -z "${!v:-}" ]; then
            printf 'Variable %s non définie dans portal.env\n' "$v" >&2
            missing=1
        fi
    done
    return $missing
}

remote_call() {
    local action="$1"
    local key="${OPENSTACK_SSH_KEY:-/etc/microstack-portal/id_ed25519}"
    local kh="${OPENSTACK_KNOWN_HOSTS:-/etc/microstack-portal/known_hosts}"
    local user="${OPENSTACK_SSH_USER:-ubuntu}"
    local port="${OPENSTACK_SSH_PORT:-22}"

    [ -r "$key" ] || { printf "Clé SSH illisible : %s\n" "$key" >&2; return 78; }
    [ -r "$kh" ]  || { printf "Fichier known_hosts illisible : %s\n" "$kh" >&2; return 78; }

    # StrictHostKeyChecking=yes : une empreinte d'hôte inconnue fait échouer la
    # connexion au lieu de l'accepter. Sans cela, un attaquant capable de se
    # placer sur le chemin récupérerait le JSON, mot de passe compris.
    ssh -i "$key" \
        -o BatchMode=yes \
        -o IdentitiesOnly=yes \
        -o StrictHostKeyChecking=yes \
        -o UserKnownHostsFile="$kh" \
        -o ConnectTimeout="${SSH_CONNECT_TIMEOUT:-10}" \
        -o ServerAliveInterval=15 \
        -o ServerAliveCountMax=8 \
        -p "$port" \
        "${user}@${OPENSTACK_HOST}" "$action"
}

# Exécute l'action et garantit qu'un objet JSON sort toujours sur stdout,
# y compris quand SSH lui-même échoue.
run_action() {
    local action="$1" out rc

    require_env OPENSTACK_HOST || { emit_error "configuration incomplète du portail"; return 78; }

    printf 'Connexion SSH vers %s@%s\n' "${OPENSTACK_SSH_USER:-ubuntu}" "$OPENSTACK_HOST" >&2

    set +e
    out="$(remote_call "$action")"
    rc=$?
    set -e

    if [ "$rc" -eq 0 ] && printf '%s' "$out" | python3 -c 'import json,sys;json.load(sys.stdin)' 2>/dev/null; then
        printf '%s\n' "$out"
        return 0
    fi

    # Le helper distant renvoie lui aussi du JSON quand il refuse : on le relaie
    # tel quel plutôt que de masquer sa raison derrière un message générique.
    if printf '%s' "$out" | python3 -c 'import json,sys;json.load(sys.stdin)' 2>/dev/null; then
        printf '%s\n' "$out"
        return 1
    fi

    case "$rc" in
        255) emit_error "connexion SSH impossible vers ${OPENSTACK_HOST} (hôte injoignable, clé refusée ou empreinte inconnue)" ;;
        64)  emit_error "action refusée par le helper distant" ;;
        78)  emit_error "configuration SSH du portail incomplète" ;;
        *)   emit_error "le helper distant a échoué (code ${rc}) sans réponse exploitable" ;;
    esac
    return 1
}
