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
