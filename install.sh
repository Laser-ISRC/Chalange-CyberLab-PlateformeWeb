#!/usr/bin/env bash
#
# install.sh — installation complète du portail de provisionnement MicroStack
# sur la VM Debian qui l'héberge.
#
# Le script se débrouille seul : il retrouve ses fichiers que le dossier soit
# rangé en sous-répertoires (web/, backend/, scripts/, remote/, config/) ou
# entièrement à plat, crée l'arborescence du site sous /var/www/html, installe
# les dépendances, écrit la configuration nginx, génère le certificat TLS et
# démarre le service.
#
#   sudo ./install.sh --fqdn portail.cyberlab.lan --ip 10.20.20.163 \
#                     --openstack-host 172.21.10.99 --ssh-user dembouz --hosts-entry
#
# L'appairage peut être inclus avec --setup-remote (il demande alors VOS
# identifiants d'administration) ou lancé séparément :
#   sudo ./setup-remote.sh --host 172.21.10.99 --user dembouz
#
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------- paramètres

FQDN="portal.cyberlab.local"
IP=""
OPENSTACK_HOST=""
SSH_USER=""
EXTERNAL_NET=""
HORIZON_URL=""
INVITE_CODE=""
DAYS=397
BACKEND_PORT=8000
WEBROOT="/var/www/html/microstack-portal"
FORCE_CERT=0
ENABLE_HSTS=0
SKIP_INSTALL=0
ADD_HOSTS=1
SETUP_REMOTE=1
ADMIN_IDENTITY=""
LAB_IMAGE="Debian12"
LAB_FLAVOR="kiwi-concombre"
UNINSTALL=0

APPDIR="/opt/microstack-portal"
ETCDIR="/etc/microstack-portal"
HOMEDIR="/var/lib/microstack-portal"
SSL_DIR="/etc/nginx/ssl"
SVCUSER="mspportal"
SERVICE="microstack-portal"

usage() {
    cat <<'USAGE'
Usage : install.sh [options]

  Sans option : demande l'hôte OpenStack et lance l'appairage SSH.

  --fqdn <nom>            Nom DNS du portail (défaut : portal.cyberlab.local).
  --ip <adresse>          IP de cette VM, ajoutée au subjectAltName.
  --openstack-host <ip>   IP de l'hôte MicroStack à joindre en SSH.
  --ssh-user <compte>     Compte Linux avec sudo sur l'hôte MicroStack.
                          Demandé dans le terminal si cette option est absente.
  --external-net <nom>    Réseau externe utilisé par deployLab.sh.
  --horizon-url <url>     URL de connexion Horizon (défaut : https://<hôte>).
  --invite-code <chaîne>  Code exigé dans le formulaire. « none » pour ouvrir le
                          portail. Par défaut, un code est tiré au hasard.
  --webroot <chemin>      Racine du site (défaut : /var/www/html/microstack-portal).
  --days <n>              Validité du certificat (défaut : 397).
  --backend-port <n>      Port d'écoute local du backend (défaut : 8000).
  --hsts                  Active HSTS (après import du certificat côté clients).
  --hosts-entry           Ajoute <ip> <fqdn> dans /etc/hosts de cette VM.
  --setup-remote          Appaire l'hôte MicroStack (activé par défaut).
  --skip-remote-setup     Installe le portail sans effectuer l'appairage SSH.
  --admin-identity <clé>  Clé SSH d'administration utilisée pour l'appairage.
  --lab-image <nom>       Image Debian du lab (défaut : Debian12).
  --lab-flavor <nom>      Flavor existant (défaut : kiwi-concombre).
  --force-cert            Régénère le certificat existant.
  --skip-install          N'installe aucun paquet.
  --uninstall             Retire le service, les fichiers et le vhost.
  -h, --help
USAGE
}

while [ $# -gt 0 ]; do
    case "$1" in
        --fqdn)           FQDN="${2:?}"; shift 2 ;;
        --ip)             IP="${2:?}"; shift 2 ;;
        --openstack-host) OPENSTACK_HOST="${2:?}"; shift 2 ;;
        --ssh-user)       SSH_USER="${2:?}"; shift 2 ;;
        --external-net)   EXTERNAL_NET="${2:?}"; shift 2 ;;
        --horizon-url)    HORIZON_URL="${2:?}"; shift 2 ;;
        --invite-code)    INVITE_CODE="${2:?}"; shift 2 ;;
        --webroot)        WEBROOT="${2:?}"; shift 2 ;;
        --days)           DAYS="${2:?}"; shift 2 ;;
        --backend-port)   BACKEND_PORT="${2:?}"; shift 2 ;;
        --hsts)           ENABLE_HSTS=1; shift ;;
        --hosts-entry)    ADD_HOSTS=1; shift ;;
        --setup-remote)      SETUP_REMOTE=1; shift ;;
        --skip-remote-setup) SETUP_REMOTE=0; shift ;;
        --admin-identity)    ADMIN_IDENTITY="${2:?}"; shift 2 ;;
        --lab-image)      LAB_IMAGE="${2:?}"; shift 2 ;;
        --lab-flavor)     LAB_FLAVOR="${2:?}"; shift 2 ;;
        --force-cert)     FORCE_CERT=1; shift ;;
        --skip-install)   SKIP_INSTALL=1; shift ;;
        --uninstall)      UNINSTALL=1; shift ;;
        -h|--help)        usage; exit 0 ;;
        *) echo "Option inconnue : $1" >&2; usage; exit 2 ;;
    esac
done

step() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
info() { printf '   %s\n' "$*"; }
warn() { printf '   \033[33m! %s\033[0m\n' "$*" >&2; }
die()  { printf '\n\033[31mÉchec : %s\033[0m\n' "$*" >&2; exit 1; }

# Toute sortie prématurée doit se voir. Un arrêt silencieux au milieu de
# l'installation laisse un système à moitié configuré sans que rien ne le dise.
on_exit() {
    local rc=$?
    if [ "$rc" -ne 0 ] && [ "${FINISHED:-0}" -ne 1 ]; then
        printf '\n\033[31mInterruption à l%stape « %s » (code %s).\033[0m\n' \
               "'é" "${CURRENT_STEP:-démarrage}" "$rc" >&2
        printf 'Le script est relançable : corrigez la cause et rejouez la même commande.\n' >&2
    fi
}
trap on_exit EXIT

mark() { CURRENT_STEP="$1"; step "$1"; }

[ "$(id -u)" -eq 0 ] || die "à exécuter en root (sudo)."

if [ -d /etc/nginx/sites-available ]; then
    VHOST="/etc/nginx/sites-available/${SERVICE}.conf"
    VHOST_LINK="/etc/nginx/sites-enabled/${SERVICE}.conf"
else
    VHOST="/etc/nginx/conf.d/${SERVICE}.conf"
    VHOST_LINK=""
fi
LIMITS="/etc/nginx/conf.d/${SERVICE}-limits.conf"
UNIT="/etc/systemd/system/${SERVICE}.service"

# --------------------------------------------------------------- désinstaller

if [ "$UNINSTALL" -eq 1 ]; then
    mark "Désinstallation"
    systemctl disable --now "$SERVICE" 2>/dev/null || true
    rm -f "$UNIT"; systemctl daemon-reload 2>/dev/null || true
    [ -n "$VHOST_LINK" ] && rm -f "$VHOST_LINK"
    rm -f "$VHOST" "$LIMITS"
    rm -rf "$APPDIR" "$WEBROOT"
    info "service, fichiers et vhost supprimés."
    info "conservés : ${ETCDIR} (clé SSH, known_hosts) et ${SSL_DIR}."
    nginx -t >/dev/null 2>&1 && systemctl reload nginx 2>/dev/null || true
    FINISHED=1
    exit 0
fi

# ------------------------------------------------------------ pré-conditions

mark "Contrôle des paramètres et des sources"

if [ -z "$IP" ]; then
    IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
    [ -n "$IP" ] && info "adresse IP locale détectée : ${IP}"
fi
if [ -z "$OPENSTACK_HOST" ]; then
    [ -r /dev/tty ] || die "précisez l'adresse IP de l'hôte OpenStack avec --openstack-host."
    printf "Adresse IP ou nom DNS de l'hôte Ubuntu/MicroStack : " > /dev/tty
    IFS= read -r OPENSTACK_HOST < /dev/tty
fi
if [ -z "$SSH_USER" ]; then
    [ -r /dev/tty ] || die "précisez le compte SSH administrateur avec --ssh-user."
    printf 'Compte Linux SSH avec accès sudo sur %s : ' "$OPENSTACK_HOST" > /dev/tty
    IFS= read -r SSH_USER < /dev/tty
fi
[ -n "$SSH_USER" ] || die "le compte SSH administrateur est obligatoire."
[ -n "$FQDN" ] || { usage; die "--fqdn est obligatoire."; }
[ -n "$OPENSTACK_HOST" ] || { usage; die "--openstack-host est obligatoire."; }
printf '%s' "$FQDN" | grep -Eq '^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$' \
    || die "FQDN invalide : $FQDN"
if [ -n "$IP" ]; then
    printf '%s' "$IP" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$' || die "IP invalide : $IP"
    IFS=. read -r IP1 IP2 IP3 IP4 <<< "$IP"
    for octet in "$IP1" "$IP2" "$IP3" "$IP4"; do
        [ "$octet" -le 255 ] || die "IP invalide : $IP"
    done
fi
printf '%s' "$BACKEND_PORT" | grep -Eq '^[0-9]{2,5}$' || die "port backend invalide."
[ "$BACKEND_PORT" -le 65535 ] || die "port backend hors plage."
printf '%s' "$DAYS" | grep -Eq '^[1-9][0-9]{0,4}$' || die "durée du certificat invalide."
[ -z "$ADMIN_IDENTITY" ] || [ -r "$ADMIN_IDENTITY" ] || die "clé d'administration illisible."
printf '%s' "$OPENSTACK_HOST" | grep -Eq '^[A-Za-z0-9.-]{1,253}$' || die "hôte OpenStack invalide."
printf '%s' "$SSH_USER" | grep -Eq '^[a-z_][a-z0-9_-]*[$]?$' || die "compte SSH invalide."
[ -z "$EXTERNAL_NET" ] || printf '%s' "$EXTERNAL_NET" | grep -Eq '^[A-Za-z0-9._-]{1,64}$' \
    || die "nom de réseau externe invalide."
[ -z "$INVITE_CODE" ] || [ "$INVITE_CODE" = "none" ] \
    || printf '%s' "$INVITE_CODE" | grep -Eq '^[A-Za-z0-9._-]{1,128}$' \
    || die "code d'invitation invalide."
for value in "$LAB_IMAGE" "$LAB_FLAVOR"; do
    [ -z "$value" ] || printf '%s' "$value" | grep -Eq '^[A-Za-z0-9._-]{1,128}$' \
        || die "nom d'image, de flavor ou de keypair invalide."
done
[ -n "$HORIZON_URL" ] || HORIZON_URL="https://${OPENSTACK_HOST}"
printf '%s' "$HORIZON_URL" | grep -Eq '^https?://[A-Za-z0-9.-]+(:[0-9]{1,5})?(/[A-Za-z0-9._~/-]*)?$' \
    || die "URL Horizon invalide."
case "$WEBROOT" in /*) ;; *) die "--webroot doit être un chemin absolu." ;; esac

KEY="${SSL_DIR}/${FQDN}.key"
CRT="${SSL_DIR}/${FQDN}.crt"

# Les fichiers sont cherchés dans leur sous-dossier d'origine puis à plat :
# une archive décompressée sans arborescence reste utilisable telle quelle.
locate_file() {
    local subdir="$1" name="$2" candidate
    for candidate in "${SRC}/${subdir}/${name}" "${SRC}/${name}"; do
        if [ -r "$candidate" ]; then printf '%s' "$candidate"; return 0; fi
    done
    return 1
}

declare -A SRCFILE
MISSING=""
for entry in "web:index.html" "web:styles.css" "web:app.js" \
             "backend:app.py" "cloud:cloud-init.yaml" \
             "scripts:createTenant.sh" "scripts:deployLab.sh" "scripts:remote-call.sh" \
             "scripts:consoleLog.sh" \
             "remote:microstack-tenant.sh" "setup:setup-remote.sh" \
             "admin:deleteTenant.sh"; do
    subdir="${entry%%:*}"; name="${entry##*:}"
    if path="$(locate_file "$subdir" "$name")"; then
        SRCFILE["$name"]="$path"
    else
        MISSING="${MISSING}\n   - ${name} (attendu dans ${subdir}/ ou à la racine)"
    fi
done

if [ -n "$MISSING" ]; then
    printf 'Fichiers introuvables :%b\n' "$MISSING" >&2
    die "placez tous les fichiers du projet dans ${SRC}."
fi

# app.js et app.py se ressemblent assez pour être intervertis lors d'un
# rangement manuel. On vérifie le contenu, pas seulement le nom.
grep -q "sendPrompt\|addEventListener" "${SRCFILE[app.js]}" \
    || die "${SRCFILE[app.js]} ne ressemble pas au script de la page."
grep -q "^import \|Flask" "${SRCFILE[app.py]}" \
    || die "${SRCFILE[app.py]} ne ressemble pas au backend Flask."

info "12 fichiers de l'application localisés."

# Les gabarits de configuration sont embarqués dans ce script : ceux du dossier
# config/ sont utilisés s'ils existent, sinon la copie interne prend le relais.
# L'installation ne peut donc pas échouer faute d'un fichier .tpl.
for entry in "config:nginx-vhost.conf.tpl" "config:portal.env.tpl" \
             "config:microstack-portal.service.tpl"; do
    subdir="${entry%%:*}"; name="${entry##*:}"
    if path="$(locate_file "$subdir" "$name")"; then
        SRCFILE["$name"]="$path"
        info "gabarit externe : ${name}"
    else
        SRCFILE["$name"]=""
    fi
done

# --------------------------------------------------------------- dépendances

mark "Dépendances"

if   command -v apt-get >/dev/null 2>&1; then PKG=apt
elif command -v dnf     >/dev/null 2>&1; then PKG=dnf
else PKG=""; fi
info "gestionnaire de paquets : ${PKG:-aucun détecté}"

if [ "$SKIP_INSTALL" -eq 1 ]; then
    info "installation ignorée (--skip-install)."
else
    case "$PKG" in
        apt)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -qq
            apt-get install -y -qq \
                nginx openssl ca-certificates curl openssh-client sudo \
                python3 python3-venv python3-flask gunicorn \
                || die "installation des paquets impossible."
            ;;
        dnf)
            dnf install -y -q nginx openssl ca-certificates curl openssh-clients sudo \
                python3 python3-flask python3-gunicorn \
                || die "installation des paquets impossible."
            ;;
        *) die "installez nginx, openssl, python3, flask et gunicorn puis relancez avec --skip-install." ;;
    esac
    info "paquets installés."
fi

for binary in nginx openssl ssh ssh-keygen python3; do
    command -v "$binary" >/dev/null 2>&1 || die "$binary introuvable."
done

if python3 -c "import flask" >/dev/null 2>&1 && command -v gunicorn >/dev/null 2>&1; then
    GUNICORN="$(command -v gunicorn)"
    info "flask et gunicorn fournis par la distribution."
else
    warn "flask ou gunicorn absent des paquets : création d'un environnement virtuel."
    install -d -m 0755 "$APPDIR"
    python3 -m venv "${APPDIR}/venv" 2>/dev/null || die "python3-venv indisponible."
    "${APPDIR}/venv/bin/pip" install --quiet --upgrade pip >/dev/null 2>&1 || true
    "${APPDIR}/venv/bin/pip" install --quiet flask gunicorn \
        || die "installation de flask/gunicorn dans le venv impossible (accès réseau ?)."
    GUNICORN="${APPDIR}/venv/bin/gunicorn"
    info "environnement virtuel prêt."
fi

# ------------------------------------------------------------- compte système

mark "Compte de service"

if ! id -u "$SVCUSER" >/dev/null 2>&1; then
    useradd --system --home-dir "$HOMEDIR" --create-home \
            --shell /usr/sbin/nologin --comment "Portail MicroStack" "$SVCUSER" \
        || die "création du compte ${SVCUSER} impossible."
    info "compte ${SVCUSER} créé."
else
    install -d -m 0750 -o "$SVCUSER" -g "$SVCUSER" "$HOMEDIR"
    info "compte ${SVCUSER} déjà présent."
fi

# ------------------------------------------------------------------ fichiers

mark "Arborescence du site et de l'application"

install -d -m 0755 "$(dirname "$WEBROOT")"
install -d -m 0755 "$WEBROOT"
install -m 0644 "${SRCFILE[index.html]}" "${WEBROOT}/index.html"
install -m 0644 "${SRCFILE[styles.css]}" "${WEBROOT}/styles.css"
install -m 0644 "${SRCFILE[app.js]}"     "${WEBROOT}/app.js"
chown -R root:root "$WEBROOT"
info "site  : ${WEBROOT}"

install -d -m 0755 "$APPDIR" "${APPDIR}/backend" "${APPDIR}/scripts" "${APPDIR}/remote"
install -d -m 0750 "${APPDIR}/admin"
install -m 0644 "${SRCFILE[app.py]}" "${APPDIR}/backend/app.py"
install -m 0644 "${SRCFILE[cloud-init.yaml]}" "${APPDIR}/cloud-init.yaml"
install -m 0755 "${SRCFILE[createTenant.sh]}" "${APPDIR}/scripts/createTenant.sh"
install -m 0755 "${SRCFILE[deployLab.sh]}"    "${APPDIR}/scripts/deployLab.sh"
install -m 0755 "${SRCFILE[consoleLog.sh]}"   "${APPDIR}/scripts/consoleLog.sh"
install -m 0644 "${SRCFILE[remote-call.sh]}"  "${APPDIR}/scripts/remote-call.sh"
install -m 0644 "${SRCFILE[microstack-tenant.sh]}" "${APPDIR}/remote/microstack-tenant.sh"
install -m 0750 "${SRCFILE[deleteTenant.sh]}" "${APPDIR}/admin/deleteTenant.sh"
[ -r "${SRC}/README.md" ] && install -m 0644 "${SRC}/README.md" "${APPDIR}/README.md"
chown -R root:root "${APPDIR}/backend" "${APPDIR}/scripts" "${APPDIR}/remote" "${APPDIR}/admin"
info "application : ${APPDIR}"

# Le code appartient à root, le service ne fait que le lire : un backend
# compromis ne peut pas réécrire ses propres scripts.

# Le fichier d'accueil de Debian traîne dans /var/www/html et n'a plus lieu
# d'être si le site vit juste en dessous.
[ -f /var/www/html/index.nginx-debian.html ] && rm -f /var/www/html/index.nginx-debian.html

# ------------------------------------------------------------------- clé SSH

mark "Clé SSH du portail"

install -d -m 0750 -o root -g "$SVCUSER" "$ETCDIR"

if [ ! -f "${ETCDIR}/id_ed25519" ]; then
    ssh-keygen -t ed25519 -N "" -C "portail-microstack@${FQDN}" \
        -f "${ETCDIR}/id_ed25519" >/dev/null \
        || die "génération de la clé SSH impossible."
    info "paire de clés créée."
else
    info "paire de clés déjà présente, conservée."
fi
chown "$SVCUSER":"$SVCUSER" "${ETCDIR}/id_ed25519"
chmod 0600 "${ETCDIR}/id_ed25519"
chown root:root "${ETCDIR}/id_ed25519.pub"
chmod 0644 "${ETCDIR}/id_ed25519.pub"

if [ ! -s "${ETCDIR}/known_hosts" ] && [ -n "$OPENSTACK_HOST" ]; then
    if ssh-keyscan -T 5 -H "$OPENSTACK_HOST" > "${ETCDIR}/known_hosts.new" 2>/dev/null \
       && [ -s "${ETCDIR}/known_hosts.new" ]; then
        mv "${ETCDIR}/known_hosts.new" "${ETCDIR}/known_hosts"
        info "empreinte de ${OPENSTACK_HOST} enregistrée."
        info "à comparer sur cet hôte avec : ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub"
    else
        rm -f "${ETCDIR}/known_hosts.new"
        warn "hôte ${OPENSTACK_HOST} injoignable : known_hosts sera écrit par setup-remote.sh."
        touch "${ETCDIR}/known_hosts"
    fi
elif [ ! -e "${ETCDIR}/known_hosts" ]; then
    touch "${ETCDIR}/known_hosts"
fi
chmod 0644 "${ETCDIR}/known_hosts"

# --------------------------------------------------------------- portal.env

mark "Configuration du backend"

if [ -z "$INVITE_CODE" ]; then
    # openssl et non « tr </dev/urandom | head » : head ferme le tube dès qu'il
    # a ses octets, tr reçoit SIGPIPE et sort en 141, ce que pipefail transforme
    # en arrêt silencieux du script.
    INVITE_CODE="$(openssl rand -hex 5 | tr '[:lower:]' '[:upper:]')"
    GENERATED_CODE=1
elif [ "$INVITE_CODE" = "none" ]; then
    INVITE_CODE=""
fi

tpl_env() {
    if [ -n "${SRCFILE[portal.env.tpl]}" ]; then
        cat "${SRCFILE[portal.env.tpl]}"
    else
        cat <<'EMBED_ENV'
# Configuration du portail de provisionnement MicroStack.
# Fichier écrit par install.sh, lu par systemd (EnvironmentFile) puis hérité par
# createTenant.sh et deployLab.sh. Droits attendus : 0640 root:@@SVCUSER@@.
#
# Syntaxe systemd : pas d'espaces autour du =, pas de guillemets superflus.

# ---- accès à l'hôte MicroStack ---------------------------------------------
# Adresse joignable depuis cette VM : l'IP flottante du serveur Ubuntu qui porte
# MicroStack, ou son adresse d'administration si la VM est sur le même réseau.
OPENSTACK_HOST=@@OPENSTACK_HOST@@
OPENSTACK_SSH_USER=@@SSH_USER@@
OPENSTACK_SSH_PORT=22
OPENSTACK_SSH_KEY=@@ETCDIR@@/id_ed25519
OPENSTACK_KNOWN_HOSTS=@@ETCDIR@@/known_hosts
SSH_CONNECT_TIMEOUT=10

# ---- portail ----------------------------------------------------------------
PORTAL_SCRIPTS_DIR=@@APPDIR@@/scripts
PORTAL_WEB_DIR=@@WEBROOT@@
PORTAL_CLOUD_INIT=@@APPDIR@@/cloud-init.yaml
PORTAL_SERVE_STATIC=0
PORTAL_VM_USER=labuser
PORTAL_FLAVOR_NAME=@@LAB_FLAVOR@@
PORTAL_FLAVOR_RAM=1024
PORTAL_FLAVOR_VCPUS=2
PORTAL_FLAVOR_DISK=20

# Code exigé dans le formulaire. Vide = portail ouvert à quiconque atteint la
# page. Sur un réseau de lab partagé, laissez-le renseigné.
PORTAL_INVITE_CODE=@@INVITE_CODE@@

# Rôle attribué sur le projet créé, et suffixe du nom de projet.
PORTAL_ROLE=admin
PORTAL_ADMIN_USER=admin
PORTAL_ADMIN_ROLE=member
PORTAL_PROJECT_SUFFIX=-project
OS_DOMAIN=Default

# Délai maximal par script : création du tenant, déploiement du lab (import
# d'image + boot + cloud-init) et lecture de console. Puis durée de
# conservation du mot de passe en mémoire et limite de demandes par adresse.
PORTAL_TIMEOUT=600
PORTAL_LAB_TIMEOUT=1500
PORTAL_CONSOLE_TIMEOUT=60
PORTAL_RESULT_TTL=900
PORTAL_RATE_MAX=5
PORTAL_RATE_WINDOW=600
PORTAL_MAX_ACTIVE=4

# ---- infrastructure déployée par deployLab.sh -------------------------------
# Réseau externe de MicroStack. Vide = premier réseau marqué external trouvé.
PORTAL_LAB_EXTERNAL_NET=@@EXTERNAL_NET@@
PORTAL_LAB_CIDR1=10.0.10.0/24
PORTAL_LAB_CIDR2=10.0.20.0/24
PORTAL_HORIZON_URL=@@HORIZON_URL@@
EMBED_ENV
    fi
}

[ -f "${ETCDIR}/portal.env" ] && cp -a "${ETCDIR}/portal.env" \
    "${ETCDIR}/portal.env.bak.$(date +%Y%m%d%H%M%S)" && info "ancien portal.env sauvegardé."

TMP_ENV="$(mktemp)"
tpl_env > "$TMP_ENV"
sed -i \
    -e "s|@@OPENSTACK_HOST@@|${OPENSTACK_HOST}|g" \
    -e "s|@@SSH_USER@@|${SSH_USER}|g" \
    -e "s|@@ETCDIR@@|${ETCDIR}|g" \
    -e "s|@@APPDIR@@|${APPDIR}|g" \
    -e "s|@@WEBROOT@@|${WEBROOT}|g" \
    -e "s|@@INVITE_CODE@@|${INVITE_CODE}|g" \
    -e "s|@@EXTERNAL_NET@@|${EXTERNAL_NET}|g" \
    -e "s|@@HORIZON_URL@@|${HORIZON_URL}|g" \
    -e "s|@@LAB_FLAVOR@@|${LAB_FLAVOR}|g" \
    -e "s|@@SVCUSER@@|${SVCUSER}|g" \
    "$TMP_ENV"
grep -q '@@' "$TMP_ENV" && { grep -n '@@' "$TMP_ENV" >&2; die "gabarit portal.env incomplètement substitué."; }
install -m 0640 -o root -g "$SVCUSER" "$TMP_ENV" "${ETCDIR}/portal.env"
rm -f "$TMP_ENV"
info "écrit : ${ETCDIR}/portal.env"

# ------------------------------------------------------------------- service

mark "Service systemd"

tpl_service() {
    if [ -n "${SRCFILE[microstack-portal.service.tpl]}" ]; then
        cat "${SRCFILE[microstack-portal.service.tpl]}"
    else
        cat <<'EMBED_SERVICE'
[Unit]
Description=Portail de provisionnement MicroStack (backend)
Documentation=file://@@APPDIR@@/README.md
After=network-online.target
Wants=network-online.target

[Service]
# Type=simple et non notify : la prise en charge sd_notify dépend de la version
# de gunicorn empaquetée, et un échec de notification bloquerait le démarrage.
Type=simple
User=@@SVCUSER@@
Group=@@SVCUSER@@
WorkingDirectory=@@APPDIR@@/backend
EnvironmentFile=@@ETCDIR@@/portal.env

# Un seul worker, plusieurs threads : l'état des travaux vit dans la mémoire du
# processus. Avec deux workers, une requête de suivi tomberait une fois sur deux
# sur le processus qui ne connaît pas l'identifiant du travail.
ExecStart=@@GUNICORN@@ \
    --workers 1 \
    --threads 8 \
    --bind 127.0.0.1:@@BACKEND_PORT@@ \
    --timeout 330 \
    --graceful-timeout 30 \
    --access-logfile - \
    --error-logfile - \
    app:application

Restart=on-failure
RestartSec=5s

# Durcissement : le service n'a besoin que de lire son code, sa configuration et
# sa clé SSH. Rien à écrire sur le disque.
NoNewPrivileges=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectSystem=strict
ProtectHome=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictSUIDSGID=yes
RestrictNamespaces=yes
LockPersonality=yes
MemoryDenyWriteExecute=no
ReadOnlyPaths=@@APPDIR@@ @@ETCDIR@@
ReadWritePaths=@@HOMEDIR@@
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
SystemCallFilter=@system-service
SystemCallErrorNumber=EPERM

[Install]
WantedBy=multi-user.target
EMBED_SERVICE
    fi
}

TMP_UNIT="$(mktemp)"
tpl_service > "$TMP_UNIT"
sed -i \
    -e "s|@@APPDIR@@|${APPDIR}|g" \
    -e "s|@@ETCDIR@@|${ETCDIR}|g" \
    -e "s|@@HOMEDIR@@|${HOMEDIR}|g" \
    -e "s|@@SVCUSER@@|${SVCUSER}|g" \
    -e "s|@@GUNICORN@@|${GUNICORN}|g" \
    -e "s|@@BACKEND_PORT@@|${BACKEND_PORT}|g" \
    "$TMP_UNIT"
install -m 0644 "$TMP_UNIT" "$UNIT"
rm -f "$TMP_UNIT"
systemctl daemon-reload
info "unité : ${UNIT}"

# ----------------------------------------------------------------- certificat

mark "Certificat TLS auto-signé"

install -d -m 0755 "$SSL_DIR"

if [ -f "$CRT" ] && [ -f "$KEY" ] && [ "$FORCE_CERT" -eq 0 ]; then
    info "certificat existant conservé (--force-cert pour le régénérer)."
else
    SAN="DNS:${FQDN}"
    [ -n "$IP" ] && SAN="${SAN},IP:${IP}"

    # Fichier de configuration plutôt que -addext : cette option n'existe qu'à
    # partir d'OpenSSL 1.1.1 et produirait ailleurs un certificat sans SAN,
    # rejeté par les navigateurs même après import dans le magasin local.
    CNF="$(mktemp)"
    cat > "$CNF" <<CNFEOF
[req]
distinguished_name = dn
prompt             = no
[dn]
C  = FR
O  = CyberLab
OU = Infrastructure
CN = ${FQDN}
[v3]
subjectAltName       = ${SAN}
basicConstraints     = critical,CA:FALSE
keyUsage             = critical,digitalSignature
extendedKeyUsage     = serverAuth
subjectKeyIdentifier = hash
CNFEOF

    openssl req -x509 -nodes \
        -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -sha256 -days "$DAYS" \
        -keyout "$KEY" -out "$CRT" \
        -config "$CNF" -extensions v3 2>/dev/null \
        || { rm -f "$CNF"; die "génération du certificat impossible."; }
    rm -f "$CNF"
    info "certificat généré pour ${SAN}, ${DAYS} jours."
fi

chmod 0600 "$KEY"; chmod 0644 "$CRT"; chown root:root "$KEY" "$CRT"
openssl x509 -in "$CRT" -noout -ext subjectAltName >/dev/null 2>&1 \
    || die "le certificat ne porte pas de subjectAltName."

# ---------------------------------------------------------------------- nginx

mark "Configuration nginx"

NGINX_VER="$(nginx -v 2>&1 | sed -n 's#.*nginx/\([0-9.]*\).*#\1#p')"
info "nginx ${NGINX_VER:-version inconnue}"

# La directive http2 autonome existe depuis 1.25.1 ; avant, HTTP/2 se déclare
# sur la ligne listen. Servir la mauvaise forme empêche nginx de démarrer.
if [ -n "$NGINX_VER" ] && [ "$(printf '%s\n1.25.1\n' "$NGINX_VER" | sort -V | head -1)" = "1.25.1" ]; then
    HTTP2_LINE="    http2       on;"
    LISTEN_LEGACY=0
else
    HTTP2_LINE="    # HTTP/2 déclaré sur la ligne listen (nginx < 1.25.1)"
    LISTEN_LEGACY=1
fi

cat > "$LIMITS" <<'LIMEOF'
# Zone partagée déclarée au niveau http : limit_req_zone ne peut pas vivre dans
# un bloc server. 60 requêtes par minute et par adresse couvrent largement le
# rythme d'interrogation de la page (une toutes les 1,5 s pendant la création).
limit_req_zone $binary_remote_addr zone=portal_api:10m rate=60r/m;
LIMEOF
chmod 0644 "$LIMITS"
info "zone de limitation : ${LIMITS}"

tpl_vhost() {
    if [ -n "${SRCFILE[nginx-vhost.conf.tpl]}" ]; then
        cat "${SRCFILE[nginx-vhost.conf.tpl]}"
    else
        cat <<'EMBED_VHOST'
# Vhost généré par install.sh — toute modification manuelle sera écrasée.

server {
    listen      80;
    listen      [::]:80;
    server_name @@FQDN@@;

    # Rien n'est servi en clair : le portail restitue un mot de passe.
    return 301 https://$host$request_uri;
}

server {
    listen      443 ssl;
    listen      [::]:443 ssl;
@@HTTP2@@
    server_name @@FQDN@@;

    root  @@WEBROOT@@;
    index index.html;

    ssl_certificate     @@CRT@@;
    ssl_certificate_key @@KEY@@;

    ssl_protocols             TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;
    ssl_ciphers               ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305;
    ssl_session_cache         shared:portal_tls:10m;
    ssl_session_timeout       1d;
    ssl_session_tickets       off;
    # Pas d'agrafage OCSP : un certificat auto-signé n'a pas de répondeur.

    # HSTS : à n'activer qu'une fois le certificat importé sur les postes clients,
    # sinon plus aucune exception manuelle n'est possible sur ce nom d'hôte.
@@HSTS@@    add_header Strict-Transport-Security "max-age=31536000" always;

    add_header X-Content-Type-Options      "nosniff"     always;
    add_header X-Frame-Options             "DENY"        always;
    add_header Referrer-Policy             "no-referrer" always;
    add_header Cross-Origin-Opener-Policy  "same-origin" always;

    # connect-src 'self' est nécessaire : la page interroge /api/ en fetch.
    # form-action 'none' : aucune soumission de formulaire classique n'a lieu,
    # tout passe par fetch, donc un script injecté ne pourrait pas exfiltrer
    # les champs vers un tiers par un simple <form>.
    add_header Content-Security-Policy "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self'; font-src 'self'; form-action 'none'; base-uri 'none'; frame-ancestors 'none'" always;

    # La page porte un mot de passe en clair dans le DOM : aucun cache.
    add_header Cache-Control "no-store" always;

    server_tokens off;
    charset utf-8;

    location / {
        try_files $uri $uri/ =404;
        limit_except GET HEAD { deny all; }
    }

    location /api/ {
        # Fenêtre étroite : une création de tenant dure une à deux minutes et
        # personne n'en lance dix par minute. Le backend applique en plus sa
        # propre limite par adresse, qui elle survit à un rechargement de nginx.
        limit_req zone=portal_api burst=10 nodelay;
        limit_req_status 429;

        proxy_pass         http://127.0.0.1:@@BACKEND_PORT@@;
        proxy_http_version 1.1;
        proxy_set_header   Host              $host;
        proxy_set_header   X-Real-IP         $remote_addr;
        proxy_set_header   X-Forwarded-Proto https;
        proxy_set_header   Connection        "";

        # Le backend attend la fin des scripts distants : la lecture doit
        # tolérer plus que les 60 s par défaut, sinon nginx coupe la requête
        # de création avant que l'hôte MicroStack ait répondu.
        proxy_connect_timeout 10s;
        proxy_send_timeout    330s;
        proxy_read_timeout    330s;
        proxy_buffering       off;
    }

    location ~ /\. { deny all; }

    access_log /var/log/nginx/microstack-portal.access.log;
    error_log  /var/log/nginx/microstack-portal.error.log;
}
EMBED_VHOST
    fi
}

[ -f "$VHOST" ] && cp -a "$VHOST" "${VHOST}.bak.$(date +%Y%m%d%H%M%S)" && info "ancien vhost sauvegardé."

TMP_VHOST="$(mktemp)"
tpl_vhost > "$TMP_VHOST"
sed -i \
    -e "s|@@FQDN@@|${FQDN}|g" \
    -e "s|@@WEBROOT@@|${WEBROOT}|g" \
    -e "s|@@CRT@@|${CRT}|g" \
    -e "s|@@KEY@@|${KEY}|g" \
    -e "s|@@BACKEND_PORT@@|${BACKEND_PORT}|g" \
    -e "s|@@HTTP2@@|${HTTP2_LINE}|" \
    "$TMP_VHOST"

if [ "$LISTEN_LEGACY" -eq 1 ]; then
    sed -i -e 's|^    listen      443 ssl;|    listen      443 ssl http2;|' \
           -e 's|^    listen      \[::\]:443 ssl;|    listen      [::]:443 ssl http2;|' "$TMP_VHOST"
fi

if [ "$ENABLE_HSTS" -eq 1 ]; then
    sed -i -e 's|@@HSTS@@||' "$TMP_VHOST"; info "HSTS activé."
else
    sed -i -e 's|@@HSTS@@|    # |' "$TMP_VHOST"; info "HSTS inactif (--hsts pour l'activer)."
fi

grep -q '@@' "$TMP_VHOST" && { grep -n '@@' "$TMP_VHOST" >&2; die "gabarit nginx incomplètement substitué."; }

install -m 0644 "$TMP_VHOST" "$VHOST"
rm -f "$TMP_VHOST"
info "vhost : ${VHOST}"

if [ -n "$VHOST_LINK" ]; then
    ln -sfn "$VHOST" "$VHOST_LINK"
    info "site activé."
    # Le site par défaut occupe le port 80 en default_server et capterait les
    # requêtes dont l'en-tête Host ne correspond à aucun vhost.
    if [ -e /etc/nginx/sites-enabled/default ]; then
        rm -f /etc/nginx/sites-enabled/default
        info "site par défaut désactivé."
    fi
fi

# ----------------------------------------------------- SELinux, pare-feu, DNS

mark "Système"

if command -v getenforce >/dev/null 2>&1 && [ "$(getenforce)" = "Enforcing" ]; then
    command -v semanage >/dev/null 2>&1 && \
        semanage fcontext -a -t httpd_sys_content_t "${WEBROOT}(/.*)?" 2>/dev/null || true
    restorecon -R "$WEBROOT" "$SSL_DIR" 2>/dev/null || true
    # Sans ce booléen, nginx ne peut pas ouvrir de socket vers le backend local.
    setsebool -P httpd_can_network_connect 1 2>/dev/null || true
    info "contextes SELinux appliqués."
else
    info "SELinux inactif ou absent."
fi

if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "^Status: active"; then
    ufw allow 80/tcp >/dev/null 2>&1 || true
    ufw allow 443/tcp >/dev/null 2>&1 || true
    info "ufw : 80/tcp et 443/tcp ouverts."
elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --add-service=http >/dev/null 2>&1 || true
    firewall-cmd --permanent --add-service=https >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
    info "firewalld : http et https autorisés."
else
    info "aucun pare-feu local actif détecté."
fi

if [ "$ADD_HOSTS" -eq 1 ]; then
    TARGET_IP="${IP:-127.0.0.1}"
    if grep -qE "[[:space:]]${FQDN}([[:space:]]|$)" /etc/hosts; then
        info "/etc/hosts contient déjà ${FQDN}."
    else
        printf '%s\t%s\n' "$TARGET_IP" "$FQDN" >> /etc/hosts
        info "/etc/hosts : ${TARGET_IP} ${FQDN}"
    fi
fi

# ------------------------------------------------------ démarrage et contrôle

mark "Démarrage et vérification"

systemctl enable "$SERVICE" >/dev/null 2>&1 || true
systemctl restart "$SERVICE" || {
    journalctl -u "$SERVICE" -n 20 --no-pager >&2 || true
    die "le backend n'a pas démarré."
}

BACKEND_OK=0
for _ in $(seq 1 20); do
    if curl -fsS --max-time 2 "http://127.0.0.1:${BACKEND_PORT}/api/health" >/dev/null 2>&1; then
        BACKEND_OK=1; break
    fi
    sleep 1
done
if [ "$BACKEND_OK" -ne 1 ]; then
    journalctl -u "$SERVICE" -n 20 --no-pager >&2 || true
    die "backend injoignable sur 127.0.0.1:${BACKEND_PORT}."
fi
info "backend en écoute sur 127.0.0.1:${BACKEND_PORT}"

nginx -t || die "configuration nginx invalide, rien n'a été rechargé."
systemctl enable nginx >/dev/null 2>&1 || true
if systemctl is-active --quiet nginx; then systemctl reload nginx; else systemctl start nginx; fi
info "nginx rechargé."

CHECK_OK=1
if curl -fsS --max-time 5 --cacert "$CRT" --resolve "${FQDN}:443:127.0.0.1" \
        "https://${FQDN}/api/health" >/dev/null; then
    info "API accessible en HTTPS."
else
    warn "l'API ne répond pas en HTTPS — /var/log/nginx/${SERVICE}.error.log"; CHECK_OK=0
fi

if PAGE_BODY="$(curl -fsS --max-time 5 --cacert "$CRT" \
        --resolve "${FQDN}:443:127.0.0.1" "https://${FQDN}/")" \
        && grep -q "Demande d'un tenant MicroStack" <<< "$PAGE_BODY"; then
    info "la page du formulaire est bien servie."
else
    warn "la page servie n'est pas celle attendue — vérifiez ${WEBROOT}/index.html"; CHECK_OK=0
fi

if curl -fsSI --max-time 5 "http://127.0.0.1/" -H "Host: ${FQDN}" 2>/dev/null | grep -q "301"; then
    info "redirection HTTP vers HTTPS active."
fi

if [ "$SETUP_REMOTE" -eq 1 ]; then
    mark "Appairage de l'hôte MicroStack"
    SETUP_SCRIPT="${SRCFILE[setup-remote.sh]}"
    SETUP_ARGS=(--host "$OPENSTACK_HOST" --user "$SSH_USER"
                --lab-image "$LAB_IMAGE" --lab-flavor "$LAB_FLAVOR")
    [ -n "$ADMIN_IDENTITY" ] && SETUP_ARGS+=(--identity "$ADMIN_IDENTITY")
    bash "$SETUP_SCRIPT" "${SETUP_ARGS[@]}" || die "appairage de l'hôte MicroStack impossible."
fi

# -------------------------------------------------------------------- résumé

FINISHED=1
mark "Terminé"

cat <<SUMEOF
   Portail (DNS) : https://${FQDN}/
   Portail (IP)  : https://${IP:-$FQDN}/
   Horizon       : ${HORIZON_URL}
   Racine du site: ${WEBROOT}
   Application   : ${APPDIR}
   Configuration : ${ETCDIR}/portal.env
   Service       : systemctl status ${SERVICE}
   Certificat    : ${CRT}
SUMEOF

if [ -n "${GENERATED_CODE:-}" ] && [ -n "$INVITE_CODE" ]; then
    printf '\n   Code d%s invitation tiré au hasard : \033[1m%s\033[0m\n' "'" "$INVITE_CODE"
    printf '   Modifiable dans %s/portal.env (PORTAL_INVITE_CODE).\n' "$ETCDIR"
elif [ -z "$INVITE_CODE" ]; then
    warn "aucun code d'invitation : quiconque atteint la page peut créer un tenant."
fi

openssl x509 -in "$CRT" -noout -fingerprint -sha256 | sed 's/^/   /'

if [ "$SETUP_REMOTE" -eq 1 ]; then
    info "hôte MicroStack appairé et VM Debian configurée (${LAB_IMAGE}, ${LAB_FLAVOR})."
else
    cat <<SUMEOF

Étape suivante — appairer l'hôte MicroStack. Elle reste séparée parce qu'elle
demande VOS identifiants d'administration sur cet hôte, que ce script n'a pas :

   sudo ${SRC}/setup-remote.sh --host ${OPENSTACK_HOST} --user ${SSH_USER} \\
        --lab-image ${LAB_IMAGE} --lab-flavor ${LAB_FLAVOR}

Ou relancez install.sh avec --setup-remote et éventuellement --admin-identity.
Tant que l'appairage n'est pas fait, les demandes échouent sur la connexion SSH.

Clé publique du portail, autorisée par cette étape :

$(sed 's/^/   /' "${ETCDIR}/id_ed25519.pub")
SUMEOF
fi

if [ "$CHECK_OK" -ne 1 ]; then
    printf '\n\033[33mInstallation terminée avec des réserves : relisez les avertissements.\033[0m\n'
fi
