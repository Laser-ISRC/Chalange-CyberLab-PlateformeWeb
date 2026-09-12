"use strict";

const $ = (id) => document.getElementById(id);

const RE_USERNAME = /^[a-z][a-z0-9._-]{2,31}$/;
const RE_EMAIL = /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/;
const RE_CIDR = /^(?:\d{1,3}\.){3}\d{1,3}\/\d{1,2}$/;
const POLL_MS = 1500;
const POLL_MAX = 1400;                // 35 minutes de suivi au maximum

let SUFFIX = "-project";
let HORIZON_URL = "";
let TENANT = null;
let VM_ACCESS = null;
let JOB_ID = null;
let PASSWORD_SHOWN = false;

/* ------------------------------------------------------------ utilitaires */

function show(pane) {
  ["pane-form", "pane-progress", "pane-result", "pane-error"]
    .forEach((id) => { $(id).hidden = (id !== pane); });
}

function setError(id, message) {
  const node = $("err-" + id);
  const input = $(id);
  if (node) { node.textContent = message || ""; node.hidden = !message; }
  if (input) input.setAttribute("aria-invalid", message ? "true" : "false");
  return !message;
}

function renderSteps(lines) {
  const list = $("steps");
  if (list.childElementCount === lines.length) return;
  list.textContent = "";
  lines.forEach((line) => {
    const li = document.createElement("li");
    li.textContent = line;          // textContent, jamais innerHTML :
    list.appendChild(li);           // le journal vient d'un processus distant.
  });
}

async function api(path, options) {
  const response = await fetch(path, Object.assign({
    headers: { "Content-Type": "application/json" },
    cache: "no-store"
  }, options || {}));
  let body = {};
  try { body = await response.json(); } catch (e) { body = {}; }
  if (!response.ok) {
    throw new Error(body.error || "Le serveur a répondu " + response.status + ".");
  }
  return body;
}

/* ------------------------------------------------------------ démarrage */

$("username").addEventListener("input", () => {
  const value = $("username").value.trim().toLowerCase();
  $("preview-project").textContent = (value || "identifiant") + SUFFIX;
});

api("/api/config", { method: "GET" })
  .then((cfg) => {
    SUFFIX = cfg.project_suffix || SUFFIX;
    HORIZON_URL = cfg.horizon_url || "";
    $("preview-project").textContent = "identifiant" + SUFFIX;
    const cidr1 = cfg.lab_cidr1 || "10.0.10.0/24";
    const cidr2 = cfg.lab_cidr2 || "10.0.20.0/24";
    $("cidr-lan").textContent = cidr1;
    $("cidr-dmz").textContent = cidr2;
    $("cidr1").value = cidr1;
    $("cidr2").value = cidr2;
    if (cfg.invite_required) {
      $("field-invite").hidden = false;
      $("invite").required = true;
    }
  })
  .catch(() => {
    $("err-form").textContent = "Le service de provisionnement ne répond pas. "
      + "Réessayez dans quelques instants ou prévenez l'administrateur du lab.";
    $("err-form").hidden = false;
    $("submit").disabled = true;
  });

/* ------------------------------------------------------------ soumission */

$("form").addEventListener("submit", async (event) => {
  event.preventDefault();
  $("err-form").hidden = true;

  const username = $("username").value.trim().toLowerCase();
  const email = $("email").value.trim();

  let valid = true;
  valid = setError("username",
    !username ? "Identifiant requis."
      : !RE_USERNAME.test(username)
        ? "3 à 32 caractères : minuscules, chiffres, . _ - ; commence par une lettre."
        : "") && valid;
  valid = setError("email",
    email && !RE_EMAIL.test(email) ? "Format d'adresse invalide." : "") && valid;
  const cidr1 = $("cidr1").value.trim();
  const cidr2 = $("cidr2").value.trim();
  valid = setError("cidr1", !RE_CIDR.test(cidr1) ? "CIDR IPv4 invalide." : "") && valid;
  valid = setError("cidr2", !RE_CIDR.test(cidr2) ? "CIDR IPv4 invalide." : "") && valid;
  if (!valid) return;

  $("submit").disabled = true;

  const payload = {
    username: username,
    email: email,
    description: $("description").value.trim(),
    deploy_lab: $("deploy-lab").checked,
    cidr1: cidr1,
    cidr2: cidr2
  };
  if (!$("field-invite").hidden) payload.invite_code = $("invite").value.trim();

  try {
    const job = await api("/api/provision", {
      method: "POST",
      body: JSON.stringify(payload)
    });
    JOB_ID = job.job_id;
    $("steps").textContent = "";
    $("spinner").classList.remove("done");
    show("pane-progress");
    poll(JOB_ID, 0);
  } catch (err) {
    $("err-form").textContent = err.message;
    $("err-form").hidden = false;
    $("submit").disabled = false;
  }
});

/* --------------------------------------------------------- interrogation */

async function poll(jobId, attempt) {
  if (attempt > POLL_MAX) {
    return failure("Le suivi a expiré. Le tenant a peut-être été créé : "
      + "vérifiez auprès de l'administrateur avant de relancer une demande.", []);
  }

  let job;
  try {
    job = await api("/api/job/" + jobId, { method: "GET" });
  } catch (err) {
    // Une coupure passagère ne doit pas interrompre le suivi.
    return setTimeout(() => poll(jobId, attempt + 1), POLL_MS * 2);
  }

  renderSteps(job.steps || []);

  if (job.state === "queued" || job.state === "running") {
    return setTimeout(() => poll(jobId, attempt + 1), POLL_MS);
  }

  if (job.state === "error") {
    return failure(job.error || "Cause inconnue.", job.steps || []);
  }

  $("spinner").classList.add("done");
  success(job);
  if (job.lab && job.lab.floating_ip && !job.lab.ssh_ready && attempt < 120) {
    return setTimeout(() => poll(jobId, attempt + 1), POLL_MS * 2);
  }
}

function failure(message, steps) {
  $("error-message").textContent = message;
  if (steps && steps.length) {
    $("error-log").textContent = steps.join("\n");
    $("error-details").hidden = false;
  }
  show("pane-error");
}

$("retry").addEventListener("click", () => {
  $("submit").disabled = false;
  show("pane-form");
  $("username").focus();
});

/* -------------------------------------------------------------- résultat */

function success(job) {
  TENANT = job.tenant || {};
  VM_ACCESS = (job.lab && job.lab.access) || null;
  PASSWORD_SHOWN = false;

  $("result-title").textContent = "Votre tenant est prêt";
  $("once-warning").textContent = "Ce mot de passe est affiché une seule fois et n'est conservé nulle part. Notez-le avant de fermer la page.";
  $("lab-block").hidden = true;
  $("vm-access").hidden = true;
  $("result-log-details").hidden = true;
  $("result-log").textContent = "";
  $("r-password").textContent = "••••••••••••••••";
  $("r-password").classList.add("masked");
  $("reveal").textContent = "Afficher";
  $("r-username").textContent = TENANT.username || "";
  $("r-project").textContent = TENANT.project || "";
  $("r-domain").textContent = TENANT.domain || "";
  $("r-roles").textContent = (TENANT.roles || []).join(", ");
  $("r-authurl").textContent = TENANT.auth_url || "";
  $("r-horizon").textContent = HORIZON_URL;
  $("r-horizon").href = HORIZON_URL;
  $("r-horizon").hidden = !HORIZON_URL;
  $("howto-code").textContent = howto(TENANT);

  const minutes = Math.max(1, Math.round((job.expires_in || 900) / 60));
  $("expiry").textContent = "Mot de passe effacé du serveur dans " + minutes + " minutes.";

  if (job.state === "partial") {
    $("result-title").textContent = "Compte créé, déploiement incomplet";
    $("once-warning").insertAdjacentText("beforeend",
      " L'infrastructure de base n'a pas pu être déployée : " + (job.error || "") );
    $("result-log").textContent = (job.steps || []).join("\n");
    $("result-log-details").hidden = false;
    $("result-log-details").open = true;
  }

  if (job.lab && job.lab.ok) {
    const list = $("lab-list");
    list.textContent = "";
    const items = [];
    if (job.lab.router) {
      items.push("Routeur " + job.lab.router.name
        + (job.lab.router.gateway ? " raccordé à " + job.lab.external_network
                                  : " sans passerelle externe"));
    }
    (job.lab.networks || []).forEach((n) => {
      items.push("Réseau " + n.name + " — " + n.cidr);
    });
    if (job.lab.security_group) {
      items.push("Groupe de sécurité " + job.lab.security_group + " : SSH et ICMP entrants");
    }
    if (job.lab.keypair) items.push("Keypair Nova " + job.lab.keypair);
    if (job.lab.flavor) {
      items.push("Flavor " + job.lab.flavor.name + " — "
        + job.lab.flavor.ram_mb + " Mio RAM, " + job.lab.flavor.vcpus
        + " vCPU, " + job.lab.flavor.disk_gb + " Gio disque");
    }
    if (job.lab.image) items.push("Image " + job.lab.image);
    if (job.lab.server) {
      items.push("VM Debian " + job.lab.server.name + " — état " + job.lab.server.status);
    }
    if (job.lab.floating_ip) {
      items.push("IP flottante " + job.lab.floating_ip
        + (job.lab.ssh_ready ? " — SSH prêt"
          : job.lab.ssh_port_ready ? " — port SSH ouvert, cloud-init non confirmé"
            : " — port SSH non joignable"));
    }
    items.forEach((text) => {
      const li = document.createElement("li");
      li.textContent = text;
      list.appendChild(li);
    });
    $("lab-block").hidden = false;
    if (VM_ACCESS && job.lab.server) {
      $("vm-name").textContent = job.lab.server.name || "";
      $("vm-floating-ip").textContent = job.lab.floating_ip || "";
      $("vm-username").textContent = VM_ACCESS.username || "";
      $("vm-password").textContent = VM_ACCESS.password || "";
      $("vm-public-key").textContent = VM_ACCESS.public_key || "";
      $("vm-ssh-command").textContent = "chmod 600 cyberlab-id_ed25519\nssh -i cyberlab-id_ed25519 "
        + (VM_ACCESS.username || "labuser") + "@" + (job.lab.floating_ip || "IP_FLOTTANTE");
      $("vm-access").hidden = false;
    }
    if (job.lab.server && job.lab.server.id) {
      renderConsole(job.lab.console_log, job.lab.console_url);
    }
  }

  show("pane-result");
}

/* --------------------------------------------------------- console VM */

function renderConsole(logText, url) {
  $("vm-console").hidden = false;
  $("vm-console-log").textContent =
    (logText && logText.trim()) ? logText : "Journal de console indisponible pour l'instant.";
  const link = $("vm-console-url");
  if (url) {
    link.href = url;
    link.hidden = false;
  } else {
    link.hidden = true;
  }
}

async function refreshConsole() {
  if (!JOB_ID) return;
  $("vm-console").hidden = false;
  try {
    const data = await api("/api/job/" + JOB_ID + "/console", { method: "GET" });
    renderConsole(data.console_log, data.console_url);
  } catch (err) {
    $("vm-console-log").textContent = "Lecture de la console impossible : " + err.message;
  }
}

$("vm-console-refresh").addEventListener("click", refreshConsole);

function howto(t) {
  return [
    "source ./" + t.username + "-openrc.sh",
    "openstack server list",
    "",
    "# Console OpenStack : " + (HORIZON_URL || "adresse fournie par l'administrateur"),
    "# Horizon utilise les mêmes identifiants, domaine " + t.domain,
    "# Si le certificat de Keystone est auto-signé, ajouter --insecure",
    "# aux commandes openstack tant qu'il n'est pas dans le magasin local."
  ].join("\n");
}

$("reveal").addEventListener("click", () => {
  PASSWORD_SHOWN = !PASSWORD_SHOWN;
  const node = $("r-password");
  node.textContent = PASSWORD_SHOWN ? (TENANT.password || "") : "••••••••••••••••";
  node.classList.toggle("masked", !PASSWORD_SHOWN);
  $("reveal").textContent = PASSWORD_SHOWN ? "Masquer" : "Afficher";
});

document.querySelectorAll(".copy").forEach((button) => {
  button.addEventListener("click", async () => {
    const source = button.dataset.scope === "vm" ? VM_ACCESS : TENANT;
    const value = source ? source[button.dataset.value] : "";
    if (!value) return;
    const label = button.textContent;
    try {
      if (navigator.clipboard && window.isSecureContext) {
        await navigator.clipboard.writeText(value);
      } else {
        const ta = document.createElement("textarea");
        ta.value = value;
        ta.style.position = "fixed";
        ta.style.opacity = "0";
        document.body.appendChild(ta);
        ta.select();
        document.execCommand("copy");
        document.body.removeChild(ta);
      }
      button.textContent = "Copié";
    } catch (e) {
      button.textContent = "Échec";
    }
    setTimeout(() => { button.textContent = label; }, 1600);
  });
});

$("download-rc").addEventListener("click", () => {
  if (!JOB_ID) return;
  // Navigation de même origine vers l'endpoint du backend : le fichier est
  // produit côté serveur, ce qui évite les blocages de CSP sur les URL blob:.
  window.location.assign("/api/job/" + JOB_ID + "/openrc");
});

$("download-ssh-key").addEventListener("click", () => {
  if (JOB_ID) window.location.assign("/api/job/" + JOB_ID + "/ssh-key");
});

$("download-cloud-init").addEventListener("click", () => {
  if (JOB_ID) window.location.assign("/api/job/" + JOB_ID + "/cloud-init");
});
