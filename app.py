"""
Backend du portail de provisionnement MicroStack.

Rôle : valider la demande, générer le mot de passe, exécuter createTenant.sh puis
éventuellement deployLab.sh, et exposer l'avancement à la page web.

Ce module ne parle jamais directement à OpenStack. Il ne connaît ni l'URL de
Keystone ni les identifiants admin : ils vivent sur l'hôte MicroStack, derrière
la commande SSH forcée. Le portail ne peut donc rien faire d'autre que les deux
actions prévues, même s'il est compromis.

Modèle d'exécution : gunicorn DOIT tourner avec un seul worker et plusieurs
threads. Les travaux sont conservés en mémoire du processus ; avec deux workers,
un client qui interroge l'avancement tomberait une fois sur deux sur le processus
qui ne connaît pas son identifiant de travail.
"""

import base64
import ipaddress
import json
import logging
import os
import re
import secrets
import socket
import subprocess
import tempfile
import threading
import time
import uuid

from flask import Flask, jsonify, request, send_from_directory

# --------------------------------------------------------------- configuration

def _env(name, default=""):
    return os.environ.get(name, default).strip()


def _int_env(name, default):
    try:
        return int(_env(name) or default)
    except ValueError:
        return default


CONF = {
    "scripts_dir":    _env("PORTAL_SCRIPTS_DIR", "/opt/microstack-portal/scripts"),
    "web_dir":        _env("PORTAL_WEB_DIR", "/var/www/microstack-portal"),
    "serve_static":   _env("PORTAL_SERVE_STATIC", "0") == "1",
    "domain":         _env("OS_DOMAIN", "Default"),
    "role":           _env("PORTAL_ROLE", "admin"),
    "admin_user":     _env("PORTAL_ADMIN_USER", "admin"),
    "admin_role":     _env("PORTAL_ADMIN_ROLE", "member"),
    "project_suffix": _env("PORTAL_PROJECT_SUFFIX", "-project"),
    "invite_code":    _env("PORTAL_INVITE_CODE"),
    # Un déploiement complet (import d'image, boot, cloud-init) dépasse
    # largement 5 minutes : le délai est par script, pas global.
    "timeout":        _int_env("PORTAL_TIMEOUT", 600),
    "lab_timeout":    _int_env("PORTAL_LAB_TIMEOUT", 1500),
    "console_timeout": _int_env("PORTAL_CONSOLE_TIMEOUT", 60),
    "result_ttl":     _int_env("PORTAL_RESULT_TTL", 900),
    "rate_max":       _int_env("PORTAL_RATE_MAX", 5),
    "rate_window":    _int_env("PORTAL_RATE_WINDOW", 600),
    "max_active":     _int_env("PORTAL_MAX_ACTIVE", 4),
    "lab_cidr1":      _env("PORTAL_LAB_CIDR1", "10.0.10.0/24"),
    "lab_cidr2":      _env("PORTAL_LAB_CIDR2", "10.0.20.0/24"),
    "lab_external":   _env("PORTAL_LAB_EXTERNAL_NET"),
    "horizon_url":    _env("PORTAL_HORIZON_URL", "https://172.21.10.99"),
    "cloud_init":     _env("PORTAL_CLOUD_INIT", "/opt/microstack-portal/cloud-init.yaml"),
    "vm_user":        _env("PORTAL_VM_USER", "labuser"),
    "flavor_name":    _env("PORTAL_FLAVOR_NAME", "kiwi-concombre"),
    "flavor_ram":     _int_env("PORTAL_FLAVOR_RAM", 1024),
    "flavor_vcpus":   _int_env("PORTAL_FLAVOR_VCPUS", 2),
    "flavor_disk":    _int_env("PORTAL_FLAVOR_DISK", 20),
}

RE_USERNAME = re.compile(r"^[a-z][a-z0-9._-]{2,31}$")
RE_EMAIL = re.compile(r"^[^\s@]+@[^\s@]+\.[^\s@]{2,}$")
RE_DESCRIPTION = re.compile(r"^[^\x00-\x1f]{0,200}$")

PASSWORD_ALPHABET = ("abcdefghijkmnopqrstuvwxyz"
                     "ABCDEFGHJKLMNPQRSTUVWXYZ"
                     "23456789"
                     "!@#%^*-_=+:.?")

logging.basicConfig(level=logging.INFO,
                    format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("portal")

application = Flask(__name__, static_folder=None)
app = application

# ------------------------------------------------------------------- travaux

_jobs = {}
_jobs_lock = threading.Lock()
_rate = {}
_rate_lock = threading.Lock()


def new_password(length=20):
    """Mot de passe tiré du CSPRNG du système, jamais journalisé."""
    return "".join(secrets.choice(PASSWORD_ALPHABET) for _ in range(length))


def new_ssh_keypair(label):
    with tempfile.TemporaryDirectory(prefix="cyberlab-key-") as directory:
        path = os.path.join(directory, "id_ed25519")
        subprocess.run(
            ["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", label, "-f", path],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=15,
        )
        with open(path, encoding="utf-8") as private_file:
            private_key = private_file.read()
        with open(path + ".pub", encoding="utf-8") as public_file:
            public_key = public_file.read().strip()
    return private_key, public_key


def hash_password(password):
    result = subprocess.run(
        ["openssl", "passwd", "-6", "-stdin"],
        input=password + "\n",
        text=True,
        check=True,
        capture_output=True,
        timeout=15,
    )
    value = result.stdout.strip()
    if not value.startswith("$6$"):
        raise ValueError("hachage du mot de passe VM invalide")
    return value


def render_cloud_init(hostname, username, password_hash, public_key):
    with open(CONF["cloud_init"], encoding="utf-8") as template_file:
        content = template_file.read()
    values = {
        "@@VM_HOSTNAME@@": hostname,
        "@@VM_USERNAME@@": username,
        "@@VM_PASSWORD_HASH@@": password_hash,
        "@@SSH_PUBLIC_KEY@@": public_key,
    }
    for marker, value in values.items():
        content = content.replace(marker, value)
    if "@@" in content or len(content.encode("utf-8")) > 65536:
        raise ValueError("modèle cloud-init invalide")
    return content


def _purge_jobs():
    """Les mots de passe ne restent en mémoire que le temps de l'affichage."""
    now = time.time()
    with _jobs_lock:
        for job_id in [j for j, v in _jobs.items()
                       if v.get("finished") and now - v["finished"] > CONF["result_ttl"]]:
            _jobs.pop(job_id, None)


def _rate_limited(ip):
    now = time.time()
    with _rate_lock:
        hits = [t for t in _rate.get(ip, []) if now - t < CONF["rate_window"]]
        if len(hits) >= CONF["rate_max"]:
            _rate[ip] = hits
            return True
        hits.append(now)
        _rate[ip] = hits
        return False


def _job_push(job_id, line):
    with _jobs_lock:
        job = _jobs.get(job_id)
        if job is not None:
            job["steps"].append(line)
            job["steps"] = job["steps"][-200:]


def _job_set(job_id, **fields):
    with _jobs_lock:
        job = _jobs.get(job_id)
        if job is not None:
            job.update(fields)


def _expire_job(job_id):
    with _jobs_lock:
        _jobs.pop(job_id, None)


def run_script(script, payload, job_id, timeout=None):
    """Exécute un script du portail.

    La charge utile part sur stdin — jamais en argument — donc aucune valeur
    saisie par l'utilisateur ne peut être interprétée comme une option ou un
    fragment de commande. stderr est lu ligne à ligne pour alimenter la page
    pendant l'exécution ; stdout porte le JSON de résultat.
    """
    if timeout is None:
        timeout = CONF["timeout"]
    path = os.path.join(CONF["scripts_dir"], script)
    if not os.access(path, os.X_OK):
        return {"ok": False, "error": "script %s absent ou non exécutable" % script}

    env = os.environ.copy()
    env["LC_ALL"] = "C.UTF-8"

    try:
        proc = subprocess.Popen(
            [path],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=env,
            text=True,
            bufsize=1,
        )
    except OSError as exc:
        return {"ok": False, "error": "exécution de %s impossible : %s" % (script, exc)}

    def drain_stderr():
        for line in proc.stderr:
            line = line.rstrip("\n")
            if line:
                _job_push(job_id, line)

    watcher = threading.Thread(target=drain_stderr, daemon=True)
    watcher.start()

    try:
        proc.stdin.write(json.dumps(payload))
        proc.stdin.close()
        proc.wait(timeout=timeout)
    except (BrokenPipeError, OSError) as exc:
        proc.kill()
        proc.wait()
        watcher.join(timeout=2)
        return {"ok": False, "error": "transmission à %s impossible : %s" % (script, exc)}
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait()
        watcher.join(timeout=2)
        return {"ok": False,
                "error": "délai dépassé (%ss) : l'hôte MicroStack n'a pas répondu"
                         % timeout}

    watcher.join(timeout=2)
    stdout = proc.stdout.read()

    try:
        result = json.loads(stdout.strip() or "{}")
    except ValueError:
        return {"ok": False, "error": "réponse illisible de %s" % script}

    if not isinstance(result, dict) or "ok" not in result:
        return {"ok": False, "error": "réponse inattendue de %s" % script}
    if proc.returncode and result.get("ok"):
        return {"ok": False, "error": "%s a échoué (code %s)" % (script, proc.returncode)}
    return result


def _monitor_ssh(job_id, address):
    """Suit l'ouverture de SSH après que Nova a déjà créé la VM."""
    for attempt in range(1, 61):
        try:
            with socket.create_connection((address, 22), timeout=2):
                with _jobs_lock:
                    job = _jobs.get(job_id)
                    if job and job.get("lab"):
                        job["lab"]["ssh_port_ready"] = True
                        job["lab"]["ssh_ready"] = True
                _job_push(job_id, "SSH joignable sur %s:22" % address)
                return
        except OSError:
            if attempt == 1 or attempt % 6 == 0:
                _job_push(job_id, "Attente de SSH sur %s:22 (%s/60)" %
                          (address, attempt))
        time.sleep(5)
    _job_push(job_id, "SSH non joignable après 5 minutes ; la VM reste disponible dans Horizon")


def _worker(job_id, req):
    """Déroulé complet d'une demande, dans un thread dédié."""
    project = req["username"] + CONF["project_suffix"]

    _job_set(job_id, state="running")
    _job_push(job_id, "Demande acceptée pour %s" % req["username"])

    create_payload = {
        "username": req["username"],
        "password": req["password"],
        "email": req["email"],
        "description": req["description"],
        "project": project,
        "role": CONF["role"],
        "admin_user": CONF["admin_user"],
        "admin_role": CONF["admin_role"],
        "domain": CONF["domain"],
    }

    result = run_script("createTenant.sh", create_payload, job_id)

    if not result.get("ok"):
        _job_set(job_id, state="error",
                 error=result.get("error", "création du tenant impossible"))
        _job_push(job_id, "Échec : %s" % result.get("error", "cause inconnue"))
        return

    # Le mot de passe n'est ajouté au résultat qu'ici : il n'a jamais transité
    # par les journaux ni par la sortie des scripts.
    user = result.get("user") or {}
    proj = result.get("project") or {}
    tenant = {
        "username": user.get("name", req["username"]),
        "user_id": user.get("id", ""),
        "email": user.get("email", ""),
        "project": proj.get("name", project),
        "project_id": proj.get("id", ""),
        "roles": result.get("roles", []),
        "admin_access": result.get("admin_access", {}),
        "domain": result.get("domain", CONF["domain"]),
        "auth_url": result.get("auth_url", ""),
        "region": result.get("region", "RegionOne"),
        "password": req["password"],
    }
    _job_set(job_id, tenant=tenant)
    _job_push(job_id, "Tenant %s vérifié dans Keystone" % tenant["project"])

    if not req["deploy_lab"]:
        _job_set(job_id, state="done")
        return

    _job_push(job_id, "Déploiement de l'infrastructure de base")
    vm_prefix = re.sub(r"[^a-z0-9-]", "-", req["username"])
    vm_name = "%s-debian-01" % vm_prefix
    vm_password = new_password()
    try:
        private_key, public_key = new_ssh_keypair("%s@cyberlab" % req["username"])
        vm_password_hash = hash_password(vm_password)
        cloud_init = render_cloud_init(
            vm_name, CONF["vm_user"], vm_password_hash, public_key
        )
    except (OSError, subprocess.SubprocessError, ValueError) as exc:
        log.error("préparation des accès VM impossible job=%s: %s", job_id, exc)
        _job_set(job_id, state="partial", error="Préparation cloud-init/SSH impossible.")
        _job_push(job_id, "Compte créé, préparation de la VM impossible")
        return

    lab_payload = {
        "project": tenant["project"],
        "prefix": req["username"],
        "external_net": CONF["lab_external"],
        "cidr1": req["cidr1"],
        "cidr2": req["cidr2"],
        "vm_name": vm_name,
        "user_id": tenant["user_id"],
        "keypair_name": "%s-cyberlab-key" % req["username"],
        "ssh_public_key_b64": base64.b64encode(public_key.encode("utf-8")).decode("ascii"),
        "flavor_name": CONF["flavor_name"],
        "flavor_ram": CONF["flavor_ram"],
        "flavor_vcpus": CONF["flavor_vcpus"],
        "flavor_disk": CONF["flavor_disk"],
        "cloud_init_b64": base64.b64encode(cloud_init.encode("utf-8")).decode("ascii"),
    }
    lab = run_script("deployLab.sh", lab_payload, job_id,
                     timeout=CONF["lab_timeout"])

    if lab.get("ok"):
        lab["access"] = {
            "username": CONF["vm_user"],
            "password": vm_password,
            "private_key": private_key,
            "public_key": public_key,
            "cloud_init": cloud_init,
        }
        lab["ssh_ready"] = False
        _job_set(job_id, lab=lab, state="done")
        _job_push(job_id, "VM créée et disponible dans Horizon (SSH en cours de démarrage)")
        if lab.get("floating_ip"):
            threading.Thread(target=_monitor_ssh,
                             args=(job_id, lab["floating_ip"]), daemon=True).start()
    else:
        # Le compte existe : c'est un succès partiel, pas un échec global.
        # Le résultat partiel est conservé : si une VM a été créée avant
        # l'échec, la page peut encore en afficher le journal de console.
        _job_set(job_id, lab=lab, state="partial",
                 error=lab.get("error", "déploiement de l'infrastructure impossible"))
        _job_push(job_id, "Compte créé, déploiement incomplet : %s"
                  % lab.get("error", "cause inconnue"))


def worker(job_id, req):
    try:
        _worker(job_id, req)
    except Exception:
        log.exception("échec interne du travail %s", job_id)
        _job_set(job_id, state="error", error="Erreur interne pendant le provisionnement.")
        _job_push(job_id, "Échec interne du provisionnement")
    finally:
        _job_set(job_id, finished=time.time())
        expiry = threading.Timer(CONF["result_ttl"], _expire_job, args=(job_id,))
        expiry.daemon = True
        expiry.start()


# ------------------------------------------------------------------ endpoints

@app.after_request
def no_store(response):
    response.headers["Cache-Control"] = "no-store"
    return response


@app.get("/api/health")
def health():
    return jsonify(status="ok")


@app.get("/api/config")
def config():
    return jsonify(
        invite_required=bool(CONF["invite_code"]),
        project_suffix=CONF["project_suffix"],
        role=CONF["role"],
        domain=CONF["domain"],
        horizon_url=CONF["horizon_url"],
        lab_cidr1=CONF["lab_cidr1"],
        lab_cidr2=CONF["lab_cidr2"],
    )


@app.post("/api/provision")
def provision():
    _purge_jobs()

    data = request.get_json(silent=True) or {}
    username = str(data.get("username", "")).strip().lower()
    email = str(data.get("email", "")).strip()
    description = str(data.get("description", "")).strip()
    invite = str(data.get("invite_code", "")).strip()
    deploy_lab = data.get("deploy_lab", False)
    cidr1 = str(data.get("cidr1", CONF["lab_cidr1"])).strip()
    cidr2 = str(data.get("cidr2", CONF["lab_cidr2"])).strip()

    if not isinstance(deploy_lab, bool):
        return jsonify(error="Option de déploiement invalide."), 400

    if CONF["invite_code"]:
        # compare_digest : la comparaison ne fuit pas la position du premier
        # caractère faux par sa durée.
        if not secrets.compare_digest(invite, CONF["invite_code"]):
            return jsonify(error="Code d'invitation invalide."), 403

    if not RE_USERNAME.match(username):
        return jsonify(error="Identifiant invalide : 3 à 32 caractères, "
                             "minuscules, chiffres, . _ - ; commence par une lettre."), 400
    if email and not RE_EMAIL.match(email):
        return jsonify(error="Adresse e-mail invalide."), 400
    if not RE_DESCRIPTION.match(description):
        return jsonify(error="Description invalide."), 400
    try:
        network1 = ipaddress.ip_network(cidr1, strict=True)
        network2 = ipaddress.ip_network(cidr2, strict=True)
        if network1.version != 4 or network2.version != 4:
            raise ValueError
        if network1.overlaps(network2):
            return jsonify(error="Les deux réseaux internes ne doivent pas se chevaucher."), 400
    except ValueError:
        return jsonify(error="CIDR invalide : utilisez deux réseaux IPv4 distincts, par exemple 10.0.10.0/24."), 400

    client_ip = request.headers.get("X-Real-IP", request.remote_addr or "?")
    if _rate_limited(client_ip):
        return jsonify(error="Trop de demandes depuis cette adresse. "
                             "Réessayez plus tard."), 429

    job_id = uuid.uuid4().hex
    with _jobs_lock:
        active = sum(j["state"] in ("queued", "running") for j in _jobs.values())
        if active >= CONF["max_active"]:
            return jsonify(error="Le service traite déjà plusieurs labs. Réessayez plus tard."), 503
        _jobs[job_id] = {
            "state": "queued",
            "steps": [],
            "tenant": None,
            "lab": None,
            "error": None,
            "created": time.time(),
            "finished": None,
        }

    req = {
        "username": username,
        "email": email,
        "description": description,
        "deploy_lab": deploy_lab,
        "cidr1": cidr1,
        "cidr2": cidr2,
        "password": new_password(),
    }

    log.info("demande de provisionnement user=%s lab=%s ip=%s job=%s",
             username, deploy_lab, client_ip, job_id)

    threading.Thread(target=worker, args=(job_id, req), daemon=True).start()
    return jsonify(job_id=job_id), 202


@app.get("/api/job/<job_id>")
def job_status(job_id):
    if not re.match(r"^[0-9a-f]{32}$", job_id or ""):
        return jsonify(error="Identifiant de travail invalide."), 400
    with _jobs_lock:
        job = _jobs.get(job_id)
        if job is None:
            return jsonify(error="Travail inconnu ou expiré."), 404
        lab = job["lab"]
        if lab and lab.get("access"):
            lab = dict(lab)
            access = dict(lab["access"])
            access.pop("private_key", None)
            access.pop("cloud_init", None)
            lab["access"] = access
        payload = {
            "state": job["state"],
            "steps": list(job["steps"]),
            "error": job["error"],
            "tenant": job["tenant"],
            "lab": lab,
            "expires_in": max(0, int(CONF["result_ttl"] -
                                     (time.time() - (job["finished"] or time.time())))),
        }
    return jsonify(payload)


@app.get("/api/job/<job_id>/openrc")
def job_openrc(job_id):
    """Fichier openrc du compte créé.

    Servi par le backend plutôt que fabriqué dans le navigateur : un
    téléchargement construit à partir d'une URL blob: se heurte selon les
    navigateurs à la politique de sécurité de contenu, alors qu'une navigation
    de même origine passe sans exception à ajouter.

    Le mot de passe n'y figure pas — il est demandé à l'exécution.
    """
    if not re.match(r"^[0-9a-f]{32}$", job_id or ""):
        return jsonify(error="Identifiant de travail invalide."), 400
    with _jobs_lock:
        job = _jobs.get(job_id)
        tenant = job["tenant"] if job else None
    if not tenant:
        return jsonify(error="Travail inconnu, expiré ou sans résultat."), 404

    def shq(value):
        return "'" + str(value or "").replace("'", "'\\''") + "'"

    body = "\n".join([
        "#!/bin/sh",
        "# source ./%s-openrc.sh" % tenant["username"],
        "export OS_AUTH_URL=%s" % shq(tenant["auth_url"]),
        "export OS_IDENTITY_API_VERSION=3",
        "export OS_INTERFACE=public",
        "export OS_REGION_NAME=%s" % shq(tenant.get("region", "RegionOne")),
        "export OS_USERNAME=%s" % shq(tenant["username"]),
        "export OS_USER_DOMAIN_NAME=%s" % shq(tenant["domain"]),
        "export OS_PROJECT_NAME=%s" % shq(tenant["project"]),
        "export OS_PROJECT_DOMAIN_NAME=%s" % shq(tenant["domain"]),
        "",
        "# Le mot de passe est demandé à l'exécution plutôt qu'écrit dans le",
        "# fichier : un openrc finit souvent dans un dépôt ou une sauvegarde.",
        'printf "Mot de passe %s : " "$OS_USERNAME"',
        "stty -echo; read OS_PASSWORD; stty echo; echo",
        "export OS_PASSWORD",
        "",
    ])

    return (body, 200, {
        "Content-Type": "text/x-shellscript; charset=utf-8",
        "Content-Disposition": 'attachment; filename="%s-openrc.sh"' % tenant["username"],
        "Cache-Control": "no-store",
    })


def _job_lab_access(job_id):
    if not re.match(r"^[0-9a-f]{32}$", job_id or ""):
        return None
    with _jobs_lock:
        job = _jobs.get(job_id)
        # job["lab"] vaut None tant que le déploiement n'a rien renvoyé :
        # .get("lab", {}) seul planterait sur None.get.
        return (job.get("lab") or {}).get("access") if job else None


@app.get("/api/job/<job_id>/ssh-key")
def job_ssh_key(job_id):
    access = _job_lab_access(job_id)
    if not access or not access.get("private_key"):
        return jsonify(error="Clé SSH inconnue, expirée ou indisponible."), 404
    return (access["private_key"], 200, {
        "Content-Type": "application/x-pem-file",
        "Content-Disposition": 'attachment; filename="cyberlab-id_ed25519"',
        "Cache-Control": "no-store",
    })


@app.get("/api/job/<job_id>/cloud-init")
def job_cloud_init(job_id):
    access = _job_lab_access(job_id)
    if not access or not access.get("cloud_init"):
        return jsonify(error="Cloud-init inconnu, expiré ou indisponible."), 404
    return (access["cloud_init"], 200, {
        "Content-Type": "text/yaml; charset=utf-8",
        "Content-Disposition": 'attachment; filename="cloud-init.yaml"',
        "Cache-Control": "no-store",
    })


@app.get("/api/job/<job_id>/console")
def job_console(job_id):
    """Journal de console et URL novnc de la VM du travail.

    Sert de console de secours quand l'onglet Console d'Horizon ne répond
    pas, et donne un visuel sur le démarrage de la VM sans rien installer.
    """
    if not re.match(r"^[0-9a-f]{32}$", job_id or ""):
        return jsonify(error="Identifiant de travail invalide."), 400
    with _jobs_lock:
        job = _jobs.get(job_id)
        tenant = job.get("tenant") if job else None
        server = (job.get("lab") or {}).get("server") if job else None
    if not tenant or not server or not server.get("id"):
        return jsonify(error="Aucune VM associée à ce travail."), 404

    result = run_script("consoleLog.sh", {
        "project": tenant["project"],
        "server_id": server["id"],
    }, job_id, timeout=CONF["console_timeout"])
    if not result.get("ok"):
        return jsonify(error=result.get("error", "console indisponible")), 502
    return jsonify(console_log=result.get("console_log", ""),
                   console_url=result.get("console_url", ""),
                   status=result.get("status", ""))


# Servir les fichiers statiques depuis Flask n'a d'intérêt qu'en développement :
# en production nginx s'en charge et le backend n'écoute que sur la boucle locale.
if CONF["serve_static"]:
    @app.get("/")
    def index():
        return send_from_directory(CONF["web_dir"], "index.html")

    @app.get("/<path:filename>")
    def static_files(filename):
        return send_from_directory(CONF["web_dir"], filename)


if __name__ == "__main__":
    application.run(host="127.0.0.1", port=8000, threaded=True)
