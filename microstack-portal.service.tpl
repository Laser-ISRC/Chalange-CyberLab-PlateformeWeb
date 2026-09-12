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
