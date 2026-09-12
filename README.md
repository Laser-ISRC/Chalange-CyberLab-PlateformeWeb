# Portail de provisionnement MicroStack

Application web qui permet à un utilisateur de demander lui-même un tenant sur
un MicroStack de test : il saisit un identifiant, le portail crée le projet, le
compte et les droits, vérifie le résultat dans Keystone, puis affiche les accès.
En option, il déploie dans la foulée une infrastructure de base — un routeur,
les réseaux `lan-net` (`10.0.10.0/24`) et `dmz-net` (`10.0.20.0/24`), un groupe
de sécurité et une VM Debian.

## Architecture

```
   navigateur
       │  HTTPS (certificat auto-signé)
       ▼
   ┌──────────────────────── VM Debian ───────────────────────┐
   │  nginx           statique + reverse-proxy /api/          │
   │    │                                                     │
   │    ▼  127.0.0.1:8000                                     │
   │  gunicorn → backend/app.py   (compte mspportal)          │
   │    │                                                     │
   │    ▼  JSON sur stdin                                     │
   │  scripts/createTenant.sh                                 │
   │  scripts/deployLab.sh                                    │
   └────┬─────────────────────────────────────────────────────┘
        │  SSH, clé dédiée, commande forcée
        ▼
   ┌──────────── serveur Ubuntu + MicroStack ─────────────────┐
   │  /usr/local/bin/microstack-tenant   (via sudo, root)     │
   │    → microstack.openstack project/user/role/network...   │
   └──────────────────────────────────────────────────────────┘
```

Le portail ne connaît ni l'URL de Keystone ni le mot de passe admin. Il ne
dispose que d'une clé SSH qui, sur l'hôte MicroStack, ne peut lancer qu'un seul
programme avec trois actions possibles : `ping`, `create`, `deploy-lab`.

## Contenu du dossier

| Chemin | Rôle |
|---|---|
| `install.sh` | Installe tout sur la VM Debian : paquets, fichiers, service, TLS, nginx |
| `setup-remote.sh` | Appaire l'hôte MicroStack : helper, règle sudo, clé autorisée |
| `deleteTenant.sh` | Liste puis supprime manuellement un tenant et ses ressources via le serveur OpenStack |
| `cloud-init.yaml` | Modèle utilisé pour configurer la VM Debian et proposé au téléchargement |
| `web/` | Page déployée dans `/var/www/html/microstack-portal` : `index.html`, `styles.css`, `app.js` |
| `backend/app.py` | API Flask : validation, mot de passe, exécution, suivi |
| `scripts/createTenant.sh` | Création du tenant, par SSH vers l'hôte MicroStack |
| `scripts/deployLab.sh` | Infrastructure de base, même chemin |
| `scripts/remote-call.sh` | Brique SSH commune aux deux scripts |
| `remote/microstack-tenant.sh` | Helper déposé sur l'hôte MicroStack |
| `config/` | Gabarits nginx, systemd et `portal.env` — facultatifs, `install.sh` en a une copie interne |

## Rôle de chaque composant

| Élément | Rôle |
|---|---|
| `index.html` | Structure de l'interface web |
| `styles.css` | Présentation visuelle |
| `app.js` | Validation du formulaire, suivi des travaux et affichage des résultats |
| `app.py` | API Flask, génération des secrets, exécution des scripts et suivi des travaux |
| `createTenant.sh` | Appelle le helper distant pour créer l'utilisateur et le projet |
| `deployLab.sh` | Appelle le helper distant pour créer l'infrastructure d'un tenant |
| `consoleLog.sh` | Récupère le journal série et l'URL de console de la VM |
| `remote-call.sh` | Ouvre la connexion SSH restreinte vers MicroStack |
| `microstack-tenant.sh` | Exécute réellement les commandes OpenStack sur l'hôte Ubuntu |
| `setup-remote.sh` | Installe le helper distant et configure la clé SSH à commande forcée |
| `deleteTenant.sh` | Supprime administrativement un tenant et ses ressources |
| `cloud-init.yaml` | Modèle de configuration initiale des VM |
| `install.sh` | Installe le portail sur la VM Debian qui l'héberge |
| `bootstrap-microstack.sh` | Non présent dans V2 ; ce script appartient à la version dev et prépare le premier environnement MicroStack |
| `portal.env.tpl` | Modèle de configuration du portail |
| `nginx-vhost.conf.tpl` | Modèle de configuration Nginx |
| `microstack-portal.service.tpl` | Modèle du service systemd qui lance Gunicorn |

## Flux fonctionnel

```text
Navigateur
    │
    ▼
index.html + app.js + styles.css
    │
    ▼
API Flask : app.py
    │
    ├── createTenant.sh
    │       └── remote-call.sh
    │               └── SSH à commande forcée
    │                       └── microstack-tenant.sh
    │                               └── OpenStack sur Ubuntu/MicroStack
    │
    └── deployLab.sh
            └── remote-call.sh
                    └── SSH à commande forcée
                            └── microstack-tenant.sh
                                    └── OpenStack sur Ubuntu/MicroStack
```

Le navigateur ne communique jamais directement avec OpenStack. `app.py` reçoit
la demande, lance le script adapté, puis `remote-call.sh` transmet la charge
utile JSON au helper distant. La clé SSH du portail est limitée à ce helper et
ne permet pas d'exécuter une commande libre sur l'hôte MicroStack.

## Installation

Copier ce dossier sur la VM Debian puis lancer, depuis ce dossier :

```bash
sudo ./install.sh
```

Sans option, le script détecte l'adresse de la VM, installe les dépendances,
copie le site, configure gunicorn/systemd, Nginx et TLS, puis appaire en SSH
l'hôte MicroStack `172.21.10.99`. Il demande le nom du compte Linux distant
ayant accès à `sudo`, puis son authentification SSH ou sudo. Le helper élevé en
root charge lui-même les identifiants administrateur OpenStack de MicroStack.
Ensuite, la clé dédiée du portail n'autorise plus que le helper distant restreint.

Les valeurs peuvent être adaptées sur la même commande, notamment avec
`--fqdn`, `--ip`, `--openstack-host`, `--ssh-user`, `--admin-identity`,
`--external-net`, `--lab-image` et `--lab-flavor`. Si `--openstack-host` n'est
pas fourni, l'installation demande l'adresse IP ou le nom DNS de l'hôte Ubuntu
qui porte MicroStack.
`--skip-remote-setup` permet exceptionnellement de différer l'appairage.
Le code d'invitation est généré aléatoirement par défaut ; `--invite-code none`
ouvre le portail.

`setup-remote.sh`, appelé automatiquement, termine par deux contrôles : le
portail doit obtenir un jeton admin, et une commande arbitraire doit être
refusée par la commande forcée. Si le second contrôle passe, quelque chose ne
va pas dans `authorized_keys`.

## À propos de OS_USERNAME et OS_PROJECT_NAME

Une précision qui change la conception : ces variables ne servent pas à créer le
tenant, elles en sont le produit. Créer un projet et un compte demande des
identifiants **administrateur** — sur MicroStack, ceux de
`/var/snap/microstack/common/etc/microstack.rc`, lisibles par root uniquement.
C'est ce fichier que le helper charge côté hôte OpenStack.

`OS_USERNAME=<user>` et `OS_PROJECT_NAME=<user>-project` décrivent le compte
**une fois créé** : ils constituent le fichier openrc remis à l'utilisateur, que
le portail propose au téléchargement à la fin. Ce fichier ne contient pas le mot
de passe, il le demande à l'exécution — un openrc finit souvent dans un dépôt ou
une sauvegarde.

### Utiliser la CLI et changer de projet

Le compte du tenant charge son environnement avec `source ./<user>-openrc.sh`,
puis utilise normalement `openstack server list`, `openstack network list` et
les autres commandes. Avec le compte administrateur, charger `microstack.rc`,
retirer `OS_PROJECT_ID`, remplacer `OS_PROJECT_NAME` par le projet voulu, puis
demander un nouveau token permet de basculer vers ce projet. Recharger
`microstack.rc` restaure ensuite le projet admin.

## Déroulé d'une demande

1. La page valide la saisie, puis `POST /api/provision`.
2. Le backend revalide, tire un mot de passe de 20 caractères avec `secrets`,
   crée un travail et répond immédiatement un identifiant de travail.
3. Un thread exécute `createTenant.sh`, charge utile JSON sur stdin.
4. Le script ouvre une session SSH ; le helper distant crée le projet et le compte,
   attribue le rôle `admin` au nouvel utilisateur et le rôle `member` à l'utilisateur
   OpenStack `admin` sur ce projet, applique les quotas, puis **relit tout depuis
   Keystone** avant de
   répondre. Si la création du compte échoue, le projet déjà créé est supprimé.
5. Si l'option est cochée, `deployLab.sh` enchaîne sur le routeur, `lan-net`,
   `dmz-net`, le groupe de sécurité, le flavor public `kiwi-concombre`, l'image `Debian12`, la VM
   configurée par cloud-init et son IP flottante.
6. La page interroge `/api/job/<id>` toutes les 1,5 s et affiche la progression,
   les ressources, le compte SSH, le mot de passe VM et les téléchargements de
   la clé privée et du fichier cloud-init utilisé. La VM est rendue disponible
   dès qu'elle est ACTIVE ; l'ouverture de SSH est suivie séparément, sans
   bloquer l'accès à Horizon et à sa console.

L'exécution est asynchrone parce qu'une création dure de quelques secondes à
plus d'une minute. Une requête HTTP synchrone dépendrait des délais de nginx et
du navigateur, et un rechargement de page perdrait le résultat.

## Sécurité — ce qui est traité

**Aucune concaténation de saisie utilisateur dans une commande.** Le JSON
traverse stdin de bout en bout : navigateur → backend → script → SSH → helper.
Aucune valeur ne devient un argument de shell. Le test d'injection classique
(`x"; touch /tmp/PWNED; echo "` dans la description) ne produit rien.

**Trois validations successives** : navigateur, backend, helper distant. La
dernière compte : c'est la seule qui précède des commandes exécutées en root.

**Commande forcée SSH.** Même avec la clé privée du portail, on n'obtient sur
l'hôte MicroStack ni shell, ni redirection de port, ni commande libre.

**Règle sudo d'une ligne**, limitée à `/usr/local/bin/microstack-tenant` sans
argument libre. Le compte SSH ne gagne rien d'autre.

**`StrictHostKeyChecking=yes`** avec un `known_hosts` dédié : une empreinte
inconnue fait échouer la connexion au lieu de l'accepter. Sans cela, une
interception sur le chemin récupérerait le mot de passe.

**Le mot de passe** est tiré côté serveur, n'apparaît dans aucun journal,
n'est pas écrit sur disque, et disparaît de la mémoire après
`PORTAL_RESULT_TTL` (15 minutes par défaut).

## Sécurité — ce qui ne l'est pas

**Exposition du mot de passe dans `/proc`.** Le client `openstack` n'accepte pas
de mot de passe par fichier ni par variable, seulement `--password` en argument.
Pendant la seconde que dure la commande, il est donc visible dans la table des
processus de l'hôte MicroStack par tout utilisateur local. Sur un hôte de lab à
administrateur unique, c'est acceptable ; sinon, il faut passer par l'API
Identity v3 en direct plutôt que par le client en ligne de commande.

**Le code d'invitation n'est pas une authentification.** C'est un secret partagé,
comparé en temps constant, qui écarte les curieux — pas un contrôle d'accès. Un
portail réellement exposé demande du mTLS ou un reverse-proxy adossé à un IdP.

**Les travaux vivent en mémoire.** Un redémarrage du service pendant une
création perd le suivi ; le tenant, lui, aura été créé côté OpenStack. C'est
aussi pourquoi le service tourne avec **un seul worker** et plusieurs threads :
avec deux workers, une requête de suivi tomberait une fois sur deux sur le
processus qui ne connaît pas l'identifiant du travail.

**Le certificat est auto-signé.** Tant qu'il n'est pas importé dans le magasin
des postes clients, l'utilisateur voit un avertissement — et prend l'habitude de
cliquer sur « continuer », ce qui est exactement ce qu'on veut éviter.

## Personnaliser la création de VM

Le portail utilise le flavor public existant `kiwi-concombre` de 1 Gio de RAM,
2 vCPU et 20 Gio de disque et l'image existante `Debian12`. Si cette image est
absente, le helper télécharge Debian 12 GenericCloud puis l'importe dans Glance
sous ce nom. Le nom de l'image et celui du flavor se règlent avec `--lab-image`
et `--lab-flavor`.

Le backend génère pour chaque lab une clé Ed25519, un mot de passe VM et une
version personnalisée de `cloud-init.yaml`. La VM reçoit l'utilisateur `labuser`,
la clé publique, un hachage SHA-512 du mot de passe et `sudo`. La même clé
publique est importée comme keypair Nova et un config-drive est attaché à la VM,
afin que l'initialisation fonctionne même si le service metadata réseau est
indisponible. Le mot de passe en clair ne part pas dans les métadonnées OpenStack.
Le YAML est transmis encodé
par SSH, puis décodé avec le mode `0600 root` dans le répertoire Snap partagé
`/var/snap/microstack/common/var/cyberlab-portal/`, nécessaire pour que le client
confiné `microstack.openstack` puisse le lire. Il est supprimé à la fin du helper
et les autres tenants OpenStack ne peuvent pas y accéder. La clé privée et le cloud-init exact
ne sont conservés qu'en mémoire jusqu'à expiration du travail et sont proposés
au téléchargement dans la page de résultat.

`/etc/default/microstack-tenant` permet d'ajuster l'URL de l'image, les quotas
(`MSK_QUOTA_*`) et le résolveur des sous-réseaux (`MSK_LAB_DNS`).

## Dépannage

```bash
systemctl status microstack-portal
journalctl -u microstack-portal -n 50
tail -f /var/log/nginx/microstack-portal.error.log

# le backend seul
curl -s http://127.0.0.1:8000/api/health

# la chaîne complète
curl -s --cacert /etc/nginx/ssl/portail.techfab.lan.crt \
     --resolve portail.techfab.lan:443:127.0.0.1 \
     https://portail.techfab.lan/api/health

# le lien SSH, tel que le voit le portail
sudo -u mspportal ssh -i /etc/microstack-portal/id_ed25519 \
     -o UserKnownHostsFile=/etc/microstack-portal/known_hosts \
     ubuntu@192.168.1.50 ping < /dev/null
```

Sur l'hôte MicroStack :

```bash
sudo -n /usr/local/bin/microstack-tenant ping < /dev/null
sudo journalctl -u ssh -n 30
```

Un `{"ok":false,...}` renvoyé par ce dernier indique où la chaîne casse :
identifiants admin illisibles, client openstack absent, ou Keystone en échec.
