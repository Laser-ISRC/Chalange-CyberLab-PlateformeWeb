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
