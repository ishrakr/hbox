# shellcheck shell=bash
# Documents (Paperless-ngx): runs after each start (hbox apps enable, update,
# restore). Sourced by hbox with HBOX_APP and HBOX_APP_DATA set.

# Its folders, before first use (the container creates the rest).
for folder in consume media data export; do
    install -d -m 775 -o "$(env_get_default PUID 1000)" -g "$(env_get_default PGID 1000)" "$HBOX_APP_DATA/$folder"
done

# Django accepts forms only from origins it trusts: every address of this
# server on Documents' port. Recreates the container when they change (a new
# IP, Tailscale enabled).
origins=$(cert_names | tr ',' '\n' | { cat; printf 'hbox.local\n'; } | sed '/^$/d' | sort -u |
    sed "s#.*#https://&:$(app_get "$HBOX_APP" port)#" | paste -sd, -)
if [ "$origins" != "$(env_get_default PAPERLESS_TRUSTED_ORIGINS '')" ]; then
    env_set PAPERLESS_TRUSTED_ORIGINS "$origins"
    app_compose "$HBOX_APP" up -d --wait --wait-timeout 600 paperless
fi

# The first time: an administrator with HBOX's login, so nobody else can
# claim the account by opening the page first.
if [ ! -f "$HBOX_APP_DATA/data/.hbox-admin-created" ]; then
    wait_until 600 "Documents (Paperless-ngx)" docker exec hbox-paperless \
        python3 manage.py check --database default
    user=$(env_get ADMIN_USER "$HBOX_CREDENTIALS")
    email=$(env_get_default ADMIN_EMAIL "$user@hbox.local" "$HBOX_CREDENTIALS")
    # The password travels in the environment, not on the command line.
    HBOX_PL_USER=$user HBOX_PL_EMAIL=$email HBOX_PL_PASSWORD=$(env_get ADMIN_PASSWORD "$HBOX_CREDENTIALS") \
        docker exec -i -e HBOX_PL_USER -e HBOX_PL_EMAIL -e HBOX_PL_PASSWORD hbox-paperless \
        python3 manage.py shell >/dev/null <<'PY'
import os
from django.contrib.auth import get_user_model
User = get_user_model()
name = os.environ["HBOX_PL_USER"]
if not User.objects.filter(username=name).exists():
    User.objects.create_superuser(name, os.environ["HBOX_PL_EMAIL"], os.environ["HBOX_PL_PASSWORD"])
PY
    touch "$HBOX_APP_DATA/data/.hbox-admin-created"
    log "  Documents: sign in with the HBOX administrator login (sudo hbox credentials)"
fi
