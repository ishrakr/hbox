# Shared proxy settings. Each location sets Host and X-Forwarded-For itself:
# nginx sends a header twice if it is set both here and there.
proxy_set_header X-Real-IP $remote_addr;
proxy_set_header X-Forwarded-Proto $scheme;
proxy_set_header X-Forwarded-Host $http_host;
proxy_http_version 1.1;
proxy_set_header Upgrade $http_upgrade;
proxy_set_header Connection $connection_upgrade;
proxy_redirect off;
proxy_read_timeout 600s;
proxy_send_timeout 600s;
send_timeout 600s;
