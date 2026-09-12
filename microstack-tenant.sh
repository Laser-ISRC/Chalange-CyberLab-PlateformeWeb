#!/usr/bin/env bash
#
# microstack-tenant — helper installé sur l'hôte Ubuntu qui porte MicroStack.
#
# Invoqué exclusivement par SSH depuis le portail web, via une clé publique
# porteuse d'une commande forcée dans authorized_keys :
#
#   command="/usr/local/bin/microstack-tenant",no-port-forwarding,\
#   no-agent-forwarding,no-X11-forwarding,no-pty ssh-ed25519 AAAA... portail
#
# La commande forcée fait que le portail ne peut pas exécuter de commande
# arbitraire sur cet hôte : quoi qu'il envoie, sshd lance ce script et place la
# chaîne demandée dans SSH_ORIGINAL_COMMAND, validée ici contre une liste fermée.
#
# Actions : ping | create | deploy-lab | console
# Entrée  : un objet JSON sur stdin
# Sortie  : un objet JSON sur stdout ; la progression lisible part sur stderr
#
set -euo pipefail
umask 077

[ -r /etc/default/microstack-tenant ] && . /etc/default/microstack-tenant

# ------------------------------------------------------------------- action

ACTION="${SSH_ORIGINAL_COMMAND:-${1:-}}"
ACTION="${ACTION%% *}"          # aucun argument accepté après le nom de l'action

case "$ACTION" in
    ping|create|deploy-lab|console) ;;
    *) printf 'Action refusée : %s\n' "${ACTION:-<vide>}" >&2; exit 64 ;;
esac

log() { printf '%s\n' "$*" >&2; }

fail() {
    MSK_ERR="$1" python3 -c 'import json,os;print(json.dumps({"ok":False,"error":os.environ["MSK_ERR"]},ensure_ascii=False))' \
        2>/dev/null || printf '{"ok":false,"error":"erreur interne"}\n'
    exit 1
}

# --------------------------------------------------- élévation de privilèges
# Le fichier d'identifiants admin de MicroStack n'est lisible que par root et le
# client snap doit tourner en root sur une installation par défaut. Plutôt que
# d'accorder un sudo large au compte SSH, on ré-exécute ce script précis, ce qui
# se déclare dans sudoers sur une seule ligne.

if [ "$(id -u)" -ne 0 ]; then
    exec sudo -n /usr/local/bin/microstack-tenant "$ACTION"
fi

# ----------------------------------------------------- client openstack + rc

if   command -v microstack.openstack >/dev/null 2>&1; then OSC=(microstack.openstack)
elif command -v openstack            >/dev/null 2>&1; then OSC=(openstack)
else fail "aucun client openstack trouvé sur l'hôte MicroStack"; fi

if [ -z "${OS_AUTH_URL:-}" ]; then
    for rc in /var/snap/microstack/common/etc/microstack.rc \
              /var/snap/microstack/common/etc/admin-openrc.sh \
              /root/admin-openrc.sh /etc/openstack/admin-openrc.sh; do
        if [ -r "$rc" ]; then
            # shellcheck disable=SC1090
            . "$rc"
            log "Identifiants admin chargés depuis $rc"
            break
        fi
    done
fi

[ -n "${OS_AUTH_URL:-}" ] || fail "OS_AUTH_URL introuvable : aucun fichier d'identifiants admin lisible"

osc() { "${OSC[@]}" "$@"; }

# --------------------------------------------------------------------- ping

if [ "$ACTION" = "ping" ]; then
    osc token issue -f value -c expires >/dev/null 2>&1 \
        || fail "authentification admin refusée par Keystone"
    MSK_URL="$OS_AUTH_URL" python3 -c 'import json,os;print(json.dumps({"ok":True,"auth_url":os.environ["MSK_URL"]}))'
    exit 0
fi

# ------------------------------------------------- lecture et contrôle du JSON
# La charge utile passe par une variable d'environnement et non par stdin : les
# blocs python ci-dessous lisent déjà leur propre code sur stdin via « - ».
# Les valeurs sont revalidées ici bien que le backend l'ait fait : ce script est
# la dernière barrière avant des commandes exécutées en root.

MSK_PAYLOAD="$(cat)"
export MSK_PAYLOAD

eval "$(python3 <<'PY'
import ipaddress, json, os, re, shlex

try:
    d = json.loads(os.environ["MSK_PAYLOAD"] or "{}")
    if not isinstance(d, dict):
        raise ValueError
except Exception:
    print("fail 'charge utile JSON illisible'")
    raise SystemExit(0)

RULES = {
    "username":     r"^$|^[a-z][a-z0-9._-]{2,31}$",
    "project":      r"^$|^[a-z][a-z0-9._-]{2,47}$",
    "domain":       r"^$|^[A-Za-z0-9._-]{1,64}$",
    "role":         r"^$|^[a-z_]{1,32}$",
    "admin_user":   r"^$|^[A-Za-z][A-Za-z0-9._-]{1,63}$",
    "admin_role":   r"^$|^[a-z_]{1,32}$",
    "prefix":       r"^$|^[a-z][a-z0-9._-]{2,31}$",
    "external_net": r"^[A-Za-z0-9._-]{0,64}$",
    "email":        r"^$|^[^\s@]+@[^\s@]+\.[^\s@]{2,}$",
    "description":  r"^[^\x00-\x1f]{0,200}$",
    "password":     r"^$|^[\x21-\x7e]{12,128}$",
    "cidr1":         r"^$|^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$",
    "cidr2":         r"^$|^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$",
    "vm_name":       r"^$|^[a-z][a-z0-9._-]{2,63}$",
    "keypair_name":  r"^$|^[a-z][a-z0-9._-]{2,63}$",
    "ssh_public_key_b64": r"^$|^[A-Za-z0-9+/=]{32,16384}$",
    "flavor_name":   r"^$|^[A-Za-z][A-Za-z0-9._-]{2,63}$",
    "flavor_ram":    r"^$|^[0-9]{3,6}$",
    "flavor_vcpus":  r"^$|^[0-9]{1,2}$",
    "flavor_disk":   r"^$|^[0-9]{1,4}$",
    "cloud_init_b64": r"^$|^[A-Za-z0-9+/=]{1,131072}$",
    "user_id":       r"^$|^[A-Za-z0-9-]{1,64}$",
    "server_id":     r"^$|^[A-Za-z0-9-]{1,64}$",
}

lines = []
for key, rx in RULES.items():
    val = d.get(key, "")
    val = "" if val is None else str(val)
    if not re.match(rx, val):
        print("fail %s" % shlex.quote("champ invalide : %s" % key))
        raise SystemExit(0)
    if key in ("cidr1", "cidr2") and val:
        try:
            ipaddress.ip_network(val, strict=True)
        except ValueError:
            print("fail %s" % shlex.quote("champ invalide : %s" % key))
            raise SystemExit(0)
    lines.append("P_%s=%s" % (key.upper(), shlex.quote(val)))

print("\n".join(lines))
PY
)"

unset MSK_PAYLOAD

# ------------------------------------------------------------------- create

if [ "$ACTION" = "create" ]; then
    [ -n "$P_USERNAME" ] || fail "username manquant"
    [ -n "$P_PASSWORD" ] || fail "password manquant"
    [ -n "$P_PROJECT" ]  || P_PROJECT="${P_USERNAME}-project"
    [ -n "$P_DOMAIN" ]     || P_DOMAIN="Default"
    [ -n "$P_ROLE" ]       || P_ROLE="admin"
    [ -n "$P_ADMIN_USER" ] || P_ADMIN_USER="admin"
    [ -n "$P_ADMIN_ROLE" ] || P_ADMIN_ROLE="member"

    log "Contrôle des collisions dans Keystone"
    if osc project show "$P_PROJECT" >/dev/null 2>&1; then
        fail "le projet ${P_PROJECT} existe déjà"
    fi
    if osc user show --domain "$P_DOMAIN" "$P_USERNAME" >/dev/null 2>&1; then
        fail "l'utilisateur ${P_USERNAME} existe déjà dans le domaine ${P_DOMAIN}"
    fi

    log "Création du projet ${P_PROJECT}"
    PROJECT_ID="$(osc project create -f value -c id \
        --domain "$P_DOMAIN" --description "tenant-${P_USERNAME}" \
        --enable "$P_PROJECT")" \
        || fail "création du projet impossible"

    log "Création du compte ${P_USERNAME}"
    # Le mot de passe transite par argv : il est visible dans /proc le temps de
    # la commande. Voir « exposition du mot de passe » dans le README.
    CREATE_ARGS=(user create --domain "$P_DOMAIN" --project "$P_PROJECT"
                 --password "$P_PASSWORD" --enable)
    [ -n "$P_EMAIL" ] && CREATE_ARGS+=(--email "$P_EMAIL")
    if [ -n "$P_DESCRIPTION" ]; then
        SAFE_DESCRIPTION="request-${P_DESCRIPTION// /-}"
        CREATE_ARGS+=(--description "$SAFE_DESCRIPTION")
    fi
    CREATE_ARGS+=(-f value -c id "$P_USERNAME")

    if ! USER_ID="$(osc "${CREATE_ARGS[@]}")"; then
        log "Échec de la création du compte : retrait du projet devenu orphelin"
        osc project delete "$P_PROJECT" >/dev/null 2>&1 || true
        fail "création du compte impossible"
    fi

    log "Attribution du rôle ${P_ROLE}"
    if ! osc role add --project "$PROJECT_ID" --user "$USER_ID" "$P_ROLE"; then
        log "Échec du rôle : retrait du compte et du projet"
        osc user delete "$USER_ID" >/dev/null 2>&1 || true
        osc project delete "$PROJECT_ID" >/dev/null 2>&1 || true
        fail "attribution du rôle impossible"
    fi

    log "Attribution du rôle ${P_ADMIN_ROLE} à ${P_ADMIN_USER} sur le nouveau projet"
    ADMIN_USER_ID="$(osc user show --domain "$P_DOMAIN" -f value -c id "$P_ADMIN_USER")" \
        || fail "utilisateur administrateur ${P_ADMIN_USER} introuvable"
    if ! osc role add --project "$PROJECT_ID" --user "$ADMIN_USER_ID" "$P_ADMIN_ROLE"; then
        log "Échec de l'accès administrateur : retrait du compte et du projet"
        osc user delete "$USER_ID" >/dev/null 2>&1 || true
        osc project delete "$PROJECT_ID" >/dev/null 2>&1 || true
        fail "attribution de l'accès administrateur au projet impossible"
    fi

    log "Application des quotas"
    osc quota set --instances "${MSK_QUOTA_INSTANCES:-4}" \
                  --cores        "${MSK_QUOTA_CORES:-4}" \
                  --ram          "${MSK_QUOTA_RAM:-8192}" \
                  --volumes      "${MSK_QUOTA_VOLUMES:-4}" \
                  --floating-ips "${MSK_QUOTA_FIPS:-2}" \
                  "$PROJECT_ID" >/dev/null 2>&1 \
        || log "Quotas non appliqués (service absent) — création poursuivie"

    log "Relecture depuis Keystone pour vérification"
    PROJECT_JSON="$(osc project show -f json "$PROJECT_ID")" || fail "projet non relisible après création"
    USER_JSON="$(osc user show -f json "$USER_ID")" || fail "compte non relisible après création"
    ROLES_JSON="$(osc role assignment list --user "$USER_ID" --project "$PROJECT_ID" --names -f json 2>/dev/null)" || ROLES_JSON='[]'
    ADMIN_ROLES_JSON="$(osc role assignment list --user "$ADMIN_USER_ID" --project "$PROJECT_ID" --names -f json 2>/dev/null)" || ADMIN_ROLES_JSON='[]'
    export PROJECT_JSON USER_JSON ROLES_JSON ADMIN_ROLES_JSON
    export MSK_ROLE="$P_ROLE" MSK_ADMIN_ROLE="$P_ADMIN_ROLE" MSK_ADMIN_USER="$P_ADMIN_USER" \
           MSK_AUTH_URL="$OS_AUTH_URL" MSK_REGION="${OS_REGION_NAME:-RegionOne}" MSK_DOMAIN="$P_DOMAIN"

    python3 <<'PY'
import json, os, sys

project = json.loads(os.environ["PROJECT_JSON"])
user    = json.loads(os.environ["USER_JSON"])
try:
    roles = json.loads(os.environ["ROLES_JSON"])
    admin_roles = json.loads(os.environ["ADMIN_ROLES_JSON"])
except Exception:
    roles, admin_roles = [], []

granted = sorted({r.get("Role") for r in roles if isinstance(r, dict) and r.get("Role")})
admin_granted = sorted({r.get("Role") for r in admin_roles if isinstance(r, dict) and r.get("Role")})
wanted = os.environ["MSK_ROLE"]
admin_wanted = os.environ["MSK_ADMIN_ROLE"]
if granted and wanted not in granted:
    print(json.dumps({"ok": False,
                      "error": "le rôle %s n'apparaît pas dans les attributions" % wanted}))
    raise SystemExit(1)
if admin_granted and admin_wanted not in admin_granted:
    print(json.dumps({"ok": False,
                      "error": "l'accès de l'administrateur au projet n'est pas vérifiable"}))
    raise SystemExit(1)

print(json.dumps({
    "ok": True,
    "project": {"id": project.get("id"), "name": project.get("name")},
    "user": {"id": user.get("id"), "name": user.get("name"),
             "email": user.get("email") or ""},
    "roles": granted or [wanted],
    "admin_access": {"user": os.environ["MSK_ADMIN_USER"],
                     "roles": admin_granted or [admin_wanted]},
    "domain": os.environ["MSK_DOMAIN"],
    "auth_url": os.environ["MSK_AUTH_URL"],
    "region": os.environ["MSK_REGION"],
}, ensure_ascii=False))
PY
    exit $?
fi

# ------------------------------------------------------------------ console

if [ "$ACTION" = "console" ]; then
    [ -n "$P_PROJECT" ]   || fail "project manquant"
    [ -n "$P_SERVER_ID" ] || fail "server_id manquant"

    PROJECT_ID="$(osc project show -f value -c id "$P_PROJECT")" \
        || fail "projet ${P_PROJECT} introuvable"
    osc_project() {
        env -u OS_PROJECT_NAME OS_PROJECT_ID="$PROJECT_ID" "${OSC[@]}" "$@"
    }

    SERVER_JSON="$(osc_project server show -f json "$P_SERVER_ID" 2>/dev/null)" \
        || fail "instance ${P_SERVER_ID} introuvable dans ${P_PROJECT}"
    CONSOLE_LOG="$(osc_project console log show --lines 200 "$P_SERVER_ID" 2>/dev/null || true)"
    CONSOLE_URL="$(osc_project console url show --novnc -f value -c url "$P_SERVER_ID" 2>/dev/null \
        || osc_project console url show -f value -c url "$P_SERVER_ID" 2>/dev/null || true)"
    export SERVER_JSON CONSOLE_LOG CONSOLE_URL

    python3 <<'PY'
import json, os
server = json.loads(os.environ["SERVER_JSON"])
print(json.dumps({
    "ok": True,
    "status": server.get("status") or server.get("Status") or "",
    "console_log": os.environ.get("CONSOLE_LOG", ""),
    "console_url": os.environ.get("CONSOLE_URL", ""),
}, ensure_ascii=False))
PY
    exit $?
fi

# --------------------------------------------------------------- deploy-lab

if [ "$ACTION" = "deploy-lab" ]; then
    [ -n "$P_PROJECT" ] || fail "project manquant"
    [ -n "$P_PREFIX" ] || P_PREFIX="lab"
    [ -n "$P_CIDR1" ]  || P_CIDR1="10.0.10.0/24"
    [ -n "$P_CIDR2" ]  || P_CIDR2="10.0.20.0/24"
    DNS="${MSK_LAB_DNS:-1.1.1.1}"

    osc project show "$P_PROJECT" >/dev/null 2>&1 || fail "projet ${P_PROJECT} introuvable"
    PROJECT_ID="$(osc project show -f value -c id "$P_PROJECT")"
    # env -u retire OS_PROJECT_NAME plutôt que de le vider : un nom vide
    # peut être rejeté par keystoneauth alors qu'un ID seul suffit.
    osc_project() {
        env -u OS_PROJECT_NAME OS_PROJECT_ID="$PROJECT_ID" "${OSC[@]}" "$@"
    }

    EXT="$P_EXTERNAL_NET"
    if [ -z "$EXT" ]; then
        EXT="$(osc network list --external -f value -c Name 2>/dev/null | head -n1 || true)"
    fi
    [ -n "$EXT" ] || fail "aucun réseau externe trouvé : précisez-le explicitement"
    log "Réseau externe retenu : ${EXT}"

    R="${P_PREFIX}-router"
    N1="lan-net"; S1="lan-subnet"
    N2="dmz-net"; S2="dmz-subnet"
    SG="${P_PREFIX}-sg"

    # Chaque ressource est reprise si elle existe déjà : un déploiement tué
    # par un délai ou une coupure laisse le projet à moitié construit, et la
    # relance doit pouvoir reprendre là où il s'est arrêté. Les recherches
    # sont bornées au projet pour ne pas confondre une ressource du tenant
    # avec une ressource du projet admin qui porterait le même nom.
    N1_ID="$(osc network list --project "$PROJECT_ID" --name "$N1" -f value -c ID | head -n1)"
    if [ -n "$N1_ID" ]; then
        log "Réseau ${N1} déjà présent, repris"
    else
        log "Création du réseau interne ${N1}"
        N1_ID="$(osc network create --project "$PROJECT_ID" -f value -c id "$N1")" \
            || fail "création de ${N1} impossible"
    fi
    N2_ID="$(osc network list --project "$PROJECT_ID" --name "$N2" -f value -c ID | head -n1)"
    if [ -n "$N2_ID" ]; then
        log "Réseau ${N2} déjà présent, repris"
    else
        log "Création du réseau interne ${N2}"
        N2_ID="$(osc network create --project "$PROJECT_ID" -f value -c id "$N2")" \
            || fail "création de ${N2} impossible"
    fi

    S1_ID="$(osc subnet list --project "$PROJECT_ID" --name "$S1" -f value -c ID | head -n1)"
    if [ -n "$S1_ID" ]; then
        log "Sous-réseau ${S1} déjà présent, repris"
    else
        log "Création du sous-réseau ${S1} (${P_CIDR1})"
        S1_ID="$(osc subnet create --project "$PROJECT_ID" --network "$N1_ID" \
            --subnet-range "$P_CIDR1" --dns-nameserver "$DNS" -f value -c id "$S1")" \
            || fail "création de ${S1} impossible"
    fi
    S2_ID="$(osc subnet list --project "$PROJECT_ID" --name "$S2" -f value -c ID | head -n1)"
    if [ -n "$S2_ID" ]; then
        log "Sous-réseau ${S2} déjà présent, repris"
    else
        log "Création du sous-réseau ${S2} (${P_CIDR2})"
        S2_ID="$(osc subnet create --project "$PROJECT_ID" --network "$N2_ID" \
            --subnet-range "$P_CIDR2" --dns-nameserver "$DNS" -f value -c id "$S2")" \
            || fail "création de ${S2} impossible"
    fi

    R_ID="$(osc router list --project "$PROJECT_ID" --name "$R" -f value -c ID | head -n1)"
    if [ -n "$R_ID" ]; then
        log "Routeur ${R} déjà présent, repris"
    else
        log "Création du routeur ${R}"
        R_ID="$(osc router create --project "$PROJECT_ID" -f value -c id "$R")" \
            || fail "création du routeur impossible"
    fi
    # La passerelle externe se pose avant les interfaces internes : sans elle le
    # routeur n'a pas de SNAT, et les instances resteraient sans sortie même une
    # fois les sous-réseaux raccordés.
    osc router set --external-gateway "$EXT" "$R_ID" >/dev/null || fail "passerelle externe impossible"
    # « router add subnet » échoue quand l'interface existe déjà : on vérifie
    # alors sa présence réelle plutôt que de faire confiance au code retour.
    router_has_subnet() {
        osc router show -f json "$R_ID" | python3 -c \
            'import json,sys
info = json.load(sys.stdin).get("interfaces_info") or []
sys.exit(0 if any(i.get("subnet_id") == sys.argv[1] for i in info) else 1)' "$1"
    }
    osc router add subnet "$R_ID" "$S1_ID" >/dev/null 2>&1 || router_has_subnet "$S1_ID" \
        || fail "raccordement de ${S1} impossible"
    osc router add subnet "$R_ID" "$S2_ID" >/dev/null 2>&1 || router_has_subnet "$S2_ID" \
        || fail "raccordement de ${S2} impossible"

    SG_ID="$(osc security group list --project "$PROJECT_ID" -f value -c ID -c Name \
        | awk -v n="$SG" '$2 == n {print $1; exit}')"
    if [ -n "$SG_ID" ]; then
        log "Groupe de sécurité ${SG} déjà présent, repris"
    else
        log "Création du groupe de sécurité ${SG}"
        SG_ID="$(osc security group create -f value -c id \
            --project "$PROJECT_ID" --description "lab-${P_PREFIX}" "$SG")" \
            || fail "création du groupe de sécurité impossible"
    fi
    osc security group rule create --ingress --protocol tcp --dst-port 22 \
        --remote-ip 0.0.0.0/0 "$SG_ID" >/dev/null 2>&1 || log "règle SSH déjà présente"
    osc security group rule create --ingress --protocol icmp \
        --remote-ip 0.0.0.0/0 "$SG_ID" >/dev/null 2>&1 || log "règle ICMP déjà présente"

    [ -n "$P_VM_NAME" ] || P_VM_NAME="${P_PREFIX}-debian-01"
    [ -n "$P_KEYPAIR_NAME" ] || P_KEYPAIR_NAME="${P_PREFIX}-cyberlab-key"
    [ -n "$P_SSH_PUBLIC_KEY_B64" ] || fail "clé publique SSH manquante"
    [ -n "$P_FLAVOR_NAME" ] || P_FLAVOR_NAME="kiwi-concombre"
    [ -n "$P_FLAVOR_RAM" ] || P_FLAVOR_RAM=1024
    [ -n "$P_FLAVOR_VCPUS" ] || P_FLAVOR_VCPUS=2
    [ -n "$P_FLAVOR_DISK" ] || P_FLAVOR_DISK=20
    [ -n "$P_CLOUD_INIT_B64" ] || fail "cloud-init manquant"

    if [ "${OSC[0]}" = "microstack.openstack" ]; then
        SNAP_SHARED_DIR="${MSK_SHARED_DIR:-/var/snap/microstack/common/var/cyberlab-portal}"
        install -d -m 0700 -o root -g root "$SNAP_SHARED_DIR"
    else
        SNAP_SHARED_DIR="${TMPDIR:-/tmp}"
    fi
    CLOUD_INIT_FILE="$(mktemp "${SNAP_SHARED_DIR%/}/cyberlab-cloud-init.XXXXXX.yaml")"
    PUBLIC_KEY_FILE="$(mktemp "${SNAP_SHARED_DIR%/}/cyberlab-key.XXXXXX.pub")"
    IMAGE_FILE=""
    SERVER_ERROR_FILE="$(mktemp)"
    cleanup_files() {
        rm -f "$CLOUD_INIT_FILE" "$PUBLIC_KEY_FILE" "$SERVER_ERROR_FILE" \
            ${IMAGE_FILE:+"$IMAGE_FILE"}
    }
    trap cleanup_files EXIT
    chmod 0600 "$CLOUD_INIT_FILE" "$PUBLIC_KEY_FILE"
    printf '%s' "$P_CLOUD_INIT_B64" | base64 -d > "$CLOUD_INIT_FILE" \
        || fail "cloud-init invalide"
    printf '%s' "$P_SSH_PUBLIC_KEY_B64" | base64 -d > "$PUBLIC_KEY_FILE" \
        || fail "clé publique SSH invalide"
    grep -Eq '^ssh-ed25519 [A-Za-z0-9+/=]+( .*)?$' "$PUBLIC_KEY_FILE" \
        || fail "format de clé publique SSH invalide"

    IMAGE="${MSK_LAB_IMAGE:-Debian12}"
    if command -v flock >/dev/null 2>&1; then
        exec 9>/run/lock/microstack-tenant-image.lock
        # Borné : un déploiement précédent tué en plein import ne doit pas
        # figer tous les suivants derrière un verrou resté posé.
        flock -w 300 9 \
            || fail "verrou d'import d'image indisponible : un autre déploiement est en cours"
    fi
    if ! osc image show "$IMAGE" >/dev/null 2>&1; then
        IMAGE_URL="${MSK_LAB_IMAGE_URL:-https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2}"
        IMAGE_FILE="$(mktemp "${SNAP_SHARED_DIR%/}/cyberlab-image.XXXXXX.qcow2")"
        chmod 0600 "$IMAGE_FILE"
        log "Téléchargement de l'image Debian 12"
        if command -v curl >/dev/null 2>&1; then
            curl -fL --retry 3 --connect-timeout 15 "$IMAGE_URL" -o "$IMAGE_FILE" \
                || fail "téléchargement de l'image Debian impossible"
        elif command -v wget >/dev/null 2>&1; then
            wget -q "$IMAGE_URL" -O "$IMAGE_FILE" \
                || fail "téléchargement de l'image Debian impossible"
        else
            fail "curl ou wget est requis pour importer l'image Debian"
        fi
        log "Import de l'image ${IMAGE} dans Glance"
        osc image create --public --disk-format qcow2 --container-format bare \
            --file "$IMAGE_FILE" "$IMAGE" >/dev/null \
            || fail "import de l'image Debian impossible"
    fi
    command -v flock >/dev/null 2>&1 && flock -u 9
    log "Image retenue : ${IMAGE}"

    log "Vérification du flavor public ${P_FLAVOR_NAME}"
    FLAVOR_ID="$(osc flavor show -f value -c id "$P_FLAVOR_NAME")" \
        || fail "flavor ${P_FLAVOR_NAME} introuvable"
    [ -n "$FLAVOR_ID" ] || fail "identifiant du flavor ${P_FLAVOR_NAME} introuvable"

    # Les versions MicroStack/OpenStack utilisées ici ne prennent pas --user
    # pour keypair create. Le projet est déjà sélectionné par osc_project.
    if osc_project keypair show "$P_KEYPAIR_NAME" >/dev/null 2>&1; then
        log "Keypair ${P_KEYPAIR_NAME} déjà présente : remplacement par la nouvelle clé"
        osc_project keypair delete "$P_KEYPAIR_NAME" >/dev/null 2>&1 || true
    fi
    log "Import de la keypair Nova ${P_KEYPAIR_NAME}"
    osc_project keypair create --public-key "$PUBLIC_KEY_FILE" "$P_KEYPAIR_NAME" >/dev/null \
        || fail "création de la keypair Nova impossible"

    # Une VM relancée porte le même nom : on la supprime pour que la clé et
    # le mot de passe affichés correspondent bien à l'instance livrée.
    EXISTING_SERVER="$(osc_project server list --name "$P_VM_NAME" -f value -c ID | head -n1)"
    if [ -n "$EXISTING_SERVER" ]; then
        log "Instance ${P_VM_NAME} déjà présente : suppression avant recréation"
        osc_project server delete --wait "$EXISTING_SERVER" >/dev/null 2>&1 \
            || fail "suppression de l'instance ${P_VM_NAME} existante impossible"
    fi

    log "Création de l'instance Debian ${P_VM_NAME} dans le projet ${P_PROJECT}"
    if ! SERVER_ID="$(osc_project server create --image "$IMAGE" \
        --flavor "$FLAVOR_ID" --network "$N1_ID" --security-group "$SG_ID" \
        --key-name "$P_KEYPAIR_NAME" --config-drive true \
        --user-data "$CLOUD_INIT_FILE" -f value -c id "$P_VM_NAME" \
        2>"$SERVER_ERROR_FILE")"; then
        while IFS= read -r error_line; do
            [ -n "$error_line" ] && log "Nova : ${error_line}"
        done < "$SERVER_ERROR_FILE"
        fail "création de l'instance Debian impossible"
    fi
    [ -n "$SERVER_ID" ] || fail "Nova n'a renvoyé aucun identifiant d'instance"

    # Pas de --wait : la VM doit être visible dans Horizon dès que Nova a
    # accepté la demande. On surveille seulement quelques secondes pour
    # détecter immédiatement un état ERROR, sans attendre le boot complet.
    SERVER_STATUS="BUILD"
    for _ in $(seq 1 6); do
        SERVER_STATUS="$(osc_project server show -f value -c status "$SERVER_ID" 2>/dev/null || true)"
        case "$SERVER_STATUS" in
            ERROR)
                FAULT="$(osc_project server show -f value -c fault "$SERVER_ID" 2>/dev/null | head -c 400 || true)"
                [ -n "$FAULT" ] && log "Nova : ${FAULT}"
                fail "l'instance est passée en ERROR pendant le démarrage" ;;
            ACTIVE) log "Instance ${P_VM_NAME} active"; break ;;
            *) log "Instance ${P_VM_NAME} : état ${SERVER_STATUS:-inconnu}, démarrage en cours" ;;
        esac
        sleep 5
    done

    log "Création et association de l'IP flottante"
    FIP_ADDRESS="$(osc floating ip create --project "$PROJECT_ID" \
        -f value -c floating_ip_address "$EXT")" \
        || fail "création de l'IP flottante impossible"
    osc_project server add floating ip "$SERVER_ID" "$FIP_ADDRESS" \
        || fail "association de l'IP flottante impossible"

    # La VM et son IP sont maintenant disponibles dans Horizon. Ne pas attendre
    # cloud-init ici : l'installation des paquets peut prendre plusieurs minutes
    # et empêcherait l'administrateur d'ouvrir immédiatement la console Horizon.
    SSH_PORT_READY=false
    CLOUD_INIT_READY=false
    SSH_READY=false
    log "VM disponible dans Horizon ; le démarrage SSH sera suivi par le portail"

    log "Vérification de la topologie et de l'instance"
    ROUTER_JSON="$(osc router show -f json "$R_ID")" || fail "routeur non relisible"
    SERVER_JSON="$(osc_project server show -f json "$SERVER_ID")" || fail "instance non relisible"
    # La fin du journal de console et l'URL novnc remontent dans le résultat :
    # la page peut ainsi afficher le démarrage de la VM et un lien direct
    # vers la console quand l'onglet Console d'Horizon ne répond pas.
    CONSOLE_TAIL="$(osc_project console log show --lines 80 "$SERVER_ID" 2>/dev/null || true)"
    CONSOLE_URL="$(osc_project console url show --novnc -f value -c url "$SERVER_ID" 2>/dev/null \
        || osc_project console url show -f value -c url "$SERVER_ID" 2>/dev/null || true)"
    export ROUTER_JSON SERVER_JSON CONSOLE_TAIL CONSOLE_URL
    export MSK_R="$R" MSK_N1="$N1" MSK_N2="$N2" MSK_S1="$S1" MSK_S2="$S2" \
           MSK_SG="$SG" MSK_EXT="$EXT" MSK_C1="$P_CIDR1" MSK_C2="$P_CIDR2" \
           MSK_FIP="$FIP_ADDRESS" MSK_IMAGE="$IMAGE" MSK_FLAVOR="$P_FLAVOR_NAME" \
           MSK_FLAVOR_RAM="$P_FLAVOR_RAM" MSK_FLAVOR_VCPUS="$P_FLAVOR_VCPUS" \
           MSK_FLAVOR_DISK="$P_FLAVOR_DISK" MSK_KEYPAIR="$P_KEYPAIR_NAME" \
           MSK_CLOUD_INIT_READY="$CLOUD_INIT_READY" MSK_SSH_PORT_READY="$SSH_PORT_READY" \
           MSK_SSH_READY="$SSH_READY"

    python3 <<'PY'
import json, os

router = json.loads(os.environ["ROUTER_JSON"])
server = json.loads(os.environ["SERVER_JSON"]) if os.environ.get("SERVER_JSON") else None
gw = router.get("external_gateway_info")
if isinstance(gw, str):
    gw = gw.strip() and gw.strip().lower() != "none"

print(json.dumps({
    "ok": True,
    "router": {"name": os.environ["MSK_R"], "id": router.get("id"),
               "gateway": bool(gw), "status": router.get("status")},
    "networks": [
        {"name": os.environ["MSK_N1"], "subnet": os.environ["MSK_S1"], "cidr": os.environ["MSK_C1"]},
        {"name": os.environ["MSK_N2"], "subnet": os.environ["MSK_S2"], "cidr": os.environ["MSK_C2"]},
    ],
    "security_group": os.environ["MSK_SG"],
    "external_network": os.environ["MSK_EXT"],
    "flavor": {"name": os.environ["MSK_FLAVOR"],
               "ram_mb": int(os.environ["MSK_FLAVOR_RAM"]),
               "vcpus": int(os.environ["MSK_FLAVOR_VCPUS"]),
               "disk_gb": int(os.environ["MSK_FLAVOR_DISK"])},
    "image": os.environ["MSK_IMAGE"],
    "floating_ip": os.environ["MSK_FIP"],
    "keypair": os.environ["MSK_KEYPAIR"],
    "cloud_init_ready": os.environ["MSK_CLOUD_INIT_READY"] == "true",
    "ssh_port_ready": os.environ["MSK_SSH_PORT_READY"] == "true",
    "ssh_ready": os.environ["MSK_SSH_READY"] == "true",
    "console_log": os.environ.get("CONSOLE_TAIL", ""),
    "console_url": os.environ.get("CONSOLE_URL", ""),
    "server": ({"id": server.get("id") or server.get("ID"),
                "name": server.get("name") or server.get("Name"),
                "status": server.get("status") or server.get("Status"),
                "addresses": server.get("addresses") or server.get("Addresses")} if server else None),
}, ensure_ascii=False))
PY
    exit $?
fi
