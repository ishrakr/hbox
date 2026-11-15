"""Offline checks: never start containers or read the deployment's .env file."""

import json
import os
import re
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
STACKS = {
    "hbox-core": ROOT / "stacks/hbox-core/compose.yaml",
    "hbox-photos": ROOT / "stacks/hbox-photos/compose.yaml",
    "hbox-files": ROOT / "stacks/hbox-files/compose.yaml",
    "hbox-tailscale": ROOT / "stacks/hbox-tailscale/compose.yaml",
    "hbox-dockge": ROOT / "manager/compose.yaml",
}
EXPECTED_SERVICES = {
    "hbox-core": {"hbox-nginx"},
    "hbox-photos": {"immich-server", "immich-machine-learning", "immich-redis", "immich-postgres"},
    "hbox-files": {"nextcloud", "nextcloud-db"},
    "hbox-tailscale": {"tailscale"},
    "hbox-dockge": {"dockge"},
}


def compose_environment():
    """Don't let shell/deployment variables override the test fixture."""
    env = os.environ.copy()
    for line in (ROOT / ".env.example").read_text().splitlines():
        if line and not line.startswith("#") and "=" in line:
            env.pop(line.split("=", 1)[0], None)
    for key in tuple(env):
        if key.startswith("COMPOSE_") or key in ("NGINX_IMAGE", "HBOX_STATUS_DIR"):
            env.pop(key)
    return env


def compose_config(stack, env=None):
    path = STACKS[stack]
    return subprocess.run(
        ["docker", "compose", "--project-directory", str(path.parent), "-f", str(path),
         "--env-file", str(ROOT / ".env.example"), "config", "--format", "json"],
        cwd=path.parent, env=env if env is not None else compose_environment(),
        capture_output=True, text=True, timeout=30,
    )


@unittest.skipUnless(shutil.which("docker"), "Docker Compose CLI is required")
class ComposeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.configs = {}
        for stack in STACKS:
            result = compose_config(stack)
            if result.returncode:
                raise AssertionError(f"{stack} configuration failed: {result.stderr}")
            cls.configs[stack] = json.loads(result.stdout)
        cls.services = {}
        for config in cls.configs.values():
            cls.services.update(config["services"])

    def test_each_stack_has_its_services_and_project_name(self):
        for stack, expected in EXPECTED_SERVICES.items():
            with self.subTest(stack=stack):
                self.assertEqual(self.configs[stack]["name"], stack)
                self.assertEqual(set(self.configs[stack]["services"]), expected)
        for name, service in self.services.items():
            self.assertEqual(service["restart"], "unless-stopped", name)

    def test_files_networks(self):
        self.assertEqual(self.services["nextcloud"]["networks"]["frontend"]["aliases"], ["nextcloud-web"])
        self.assertEqual(set(self.services["nextcloud"]["networks"]), {"frontend", "nextcloud"})
        for stack in STACKS:
            self.assertNotIn("files-path", self.configs[stack].get("networks", {}))

    def test_dashboard_links_apps_by_port(self):
        apps = json.loads((ROOT / "config/dashboard/apps.json").read_text())
        items = {i["name"]: i for s in apps["sections"] for i in s["items"]}
        self.assertEqual({n: i.get("port") for n, i in items.items()},
                         {"Photos": 2443, "Files": 3443, "Admin": 5443, "Backups": 6443})
        # Each shipped app shows its logo, which must exist and be inert SVG.
        for item in items.values():
            logo = ROOT / "config/dashboard/icons" / item["logo"]
            self.assertTrue(logo.is_file(), logo)
            svg = logo.read_text().lower()
            self.assertTrue(svg.lstrip().startswith("<svg"))
            for bad in ("<script", "javascript:", "onload", "<foreignobject"):
                self.assertNotIn(bad, svg)
        script = (ROOT / "config/dashboard/app.js").read_text()
        self.assertIn("`https://${location.hostname}:${item.port}", script)
        self.assertIn("/health/${encodeURIComponent(name)}", script)
        # Text from apps.json is never inserted as HTML.
        self.assertNotIn("innerHTML = item", script)

    def test_all_stacks_share_the_external_frontend_network(self):
        for stack in ("hbox-core", "hbox-photos", "hbox-files", "hbox-dockge"):
            networks = self.configs[stack]["networks"]
            self.assertEqual(networks["frontend"]["name"], "hbox-frontend")
            self.assertTrue(networks["frontend"]["external"])
        # Each database lives on its own private network.
        self.assertEqual(self.configs["hbox-photos"]["networks"]["immich"]["name"], "hbox-immich")
        self.assertEqual(self.configs["hbox-files"]["networks"]["nextcloud"]["name"], "hbox-nextcloud")

    def test_tailscale_uses_host_networking(self):
        ts = self.services["tailscale"]
        self.assertEqual(ts["network_mode"], "host")
        self.assertEqual(ts["environment"]["TS_STATE_DIR"], "/var/lib/tailscale")
        self.assertEqual(ts["environment"]["TS_USERSPACE"], "false")

    def test_only_dockge_mounts_the_docker_socket_and_nothing_is_privileged(self):
        for name, service in self.services.items():
            self.assertFalse(service.get("privileged", False), name)
            sockets = [v for v in service.get("volumes", []) if "docker.sock" in v["source"]]
            self.assertEqual(bool(sockets), name == "dockge", name)

    def test_dockge_stacks_dir_is_mounted_at_the_same_path(self):
        dockge = self.services["dockge"]
        self.assertEqual(dockge["environment"]["DOCKGE_STACKS_DIR"], "/opt/hbox/stacks")
        mounts = {v["source"]: v["target"] for v in dockge["volumes"]}
        self.assertEqual(mounts["/opt/hbox"], "/opt/hbox")
        self.assertEqual(mounts["/DATA/dockge"], "/app/data")
        self.assertEqual(dockge["ports"][0]["host_ip"], "127.0.0.1")

    def test_original_data_bind_mounts_preserved(self):
        expected = {
            "immich-server": {"/DATA/immich/upload": "/usr/src/app/upload"},
            "immich-machine-learning": {"/DATA/immich/model-cache": "/cache"},
            "immich-postgres": {"/DATA/immich/pgdata": "/var/lib/postgresql/data"},
            "nextcloud": {"/DATA/nextcloud/config": "/config", "/DATA/nextcloud/data": "/data"},
            "nextcloud-db": {"/DATA/nextcloud/pgdata": "/var/lib/postgresql"},
            "tailscale": {"/DATA/tailscale": "/var/lib/tailscale"},
        }
        for name, mounts in expected.items():
            with self.subTest(service=name):
                actual = {v["source"]: v["target"] for v in self.services[name]["volumes"]}
                self.assertEqual(actual, mounts)
        for name, service in self.services.items():
            for volume in service.get("volumes", []):
                if volume["type"] == "bind" and "docker.sock" not in volume["source"]:
                    self.assertFalse(volume.get("bind", {}).get("create_host_path", False), name)

    def test_database_versions_not_upgraded(self):
        self.assertEqual(self.services["nextcloud-db"]["image"], "postgres:18")
        self.assertEqual(
            self.services["immich-postgres"]["image"],
            "ghcr.io/immich-app/postgres:14-vectorchord0.4.3-pgvectors0.2.0"
            "@sha256:bcf63357191b76a916ae5eb93464d65c07511da41e3bf7a8416db519b40b1c23",
        )
        self.assertTrue(self.services["immich-redis"]["image"].startswith("docker.io/valkey/valkey:8@sha256:"))

    def test_app_versions_are_pinned(self):
        for name, prefix in (
            ("immich-server", "ghcr.io/immich-app/immich-server:v3."),
            ("immich-machine-learning", "ghcr.io/immich-app/immich-machine-learning:v3."),
            ("nextcloud", "lscr.io/linuxserver/nextcloud:35."),
            ("dockge", "louislam/dockge:1."),
            ("tailscale", "tailscale/tailscale:v1."),
        ):
            self.assertTrue(self.services[name]["image"].startswith(prefix), self.services[name]["image"])
            self.assertNotIn("latest", self.services[name]["image"])

    def test_databases_are_never_exposed(self):
        for name, network in (("immich-postgres", "immich"), ("immich-redis", "immich"),
                              ("nextcloud-db", "nextcloud")):
            with self.subTest(service=name):
                self.assertFalse(self.services[name].get("ports"))
                self.assertEqual(set(self.services[name]["networks"]), {network})

    def test_direct_app_ports_bind_only_to_loopback(self):
        for name, port in (("immich-server", 2283),
                           ("nextcloud", 443), ("dockge", 5001)):
            with self.subTest(service=name):
                ports = self.services[name]["ports"]
                self.assertEqual(len(ports), 1)
                self.assertEqual(ports[0]["host_ip"], "127.0.0.1")
                self.assertEqual(ports[0]["target"], port)
        self.assertEqual({p["target"] for p in self.services["hbox-nginx"]["ports"]}, {80, 443, 2443, 3443, 5443, 6443})

    def test_nginx_is_stock_with_config_mounted_from_git(self):
        service = self.services["hbox-nginx"]
        self.assertRegex(service["image"], r"^nginx:1\.28-alpine@sha256:[0-9a-f]{64}$")
        self.assertNotIn("build", service)
        mounts = [(v["source"], v["target"], v.get("read_only")) for v in service["volumes"]]
        self.assertEqual(mounts, [
            (str(ROOT / "config/nginx"), "/etc/nginx/conf.d", True),
            (str(ROOT / "config/dashboard"), "/usr/share/nginx/hbox-dashboard", True),
            (str(ROOT / "certs"), "/etc/nginx/ssl", True),
            ("/var/lib/hbox/dashboard", "/var/lib/hbox-dashboard", True),
            # The only writable mount: request files for the dashboard buttons.
            ("/var/lib/hbox/requests", "/var/lib/hbox-requests", None),
            ("/var/lib/hbox/nginx-auth", "/etc/nginx/hbox-auth", True),
            ("/var/lib/hbox/nginx-apps", "/etc/nginx/hbox-apps", True),
        ])
        self.assertIn("https://127.0.0.1/", service["healthcheck"]["test"])
        # Only *.conf in conf.d is loaded by nginx; the shared snippet must not be.
        self.assertEqual(sorted(p.name for p in (ROOT / "config/nginx").glob("*.conf")), ["default.conf"])
        self.assertFalse((ROOT / "images").exists())

    def test_immich_ml_avoids_gunicorn_control_socket(self):
        env = self.services["immich-machine-learning"]["environment"]
        self.assertEqual(env["GUNICORN_CMD_ARGS"], "--no-control-socket")

    def test_waits_for_database_and_cache_readiness(self):
        for service, deps in (("immich-server", ["immich-postgres", "immich-redis"]),
                              ("nextcloud", ["nextcloud-db"])):
            for dependency in deps:
                self.assertEqual(self.services[service]["depends_on"][dependency]["condition"],
                                 "service_healthy")
        for name in ("immich-postgres", "nextcloud-db"):
            test = self.services[name]["healthcheck"]["test"][1]
            self.assertIn("$POSTGRES_USER", test)

    def test_passwords_required(self):
        for stack, key in (("hbox-photos", "IMMICH_DB_PASSWORD"), ("hbox-files", "NEXTCLOUD_DB_PASSWORD")):
            with self.subTest(variable=key):
                env = compose_environment()
                env[key] = ""
                result = compose_config(stack, env=env)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(key, result.stderr)

    def test_custom_data_root_and_home(self):
        env = compose_environment()
        env.update({"DATA_ROOT": "/srv/hbox data", "HBOX_HOME": "/srv/hbox-app", "PUID": "1234"})
        photos = json.loads(compose_config("hbox-photos", env=env).stdout)["services"]
        self.assertEqual(photos["immich-server"]["volumes"][0]["source"], "/srv/hbox data/immich/upload")
        dockge = json.loads(compose_config("hbox-dockge", env=env).stdout)["services"]["dockge"]
        self.assertEqual(dockge["environment"]["DOCKGE_STACKS_DIR"], "/srv/hbox-app/stacks")
        files = json.loads(compose_config("hbox-files", env=env).stdout)["services"]
        self.assertEqual(files["nextcloud"]["environment"]["PUID"], "1234")


class AppsAndPatchesTests(unittest.TestCase):
    def test_shipped_apps_are_valid(self):
        reserved = {80, 443, 2443, 3443, 5443, 6443}
        ports = {}
        for app in sorted((ROOT / "apps").iterdir()):
            with self.subTest(app=app.name):
                self.assertRegex(app.name, r"^[a-z0-9][a-z0-9-]{0,30}$")
                meta = json.loads((app / "app.json").read_text())
                self.assertIsInstance(meta["port"], int)
                self.assertNotIn(meta["port"], reserved)
                self.assertNotIn(meta["port"], ports, f"port shared with {ports.get(meta['port'])}")
                ports[meta["port"]] = app.name
                self.assertRegex(meta["upstream"], r"^https?://[A-Za-z0-9._-]+:[0-9]+$")
                compose = (app / "compose.yaml").read_text()
                self.assertIn("name: hbox-frontend", compose)
                self.assertNotIn("ports:", compose)  # reached only through nginx
                self.assertNotIn(":latest", compose)

    @unittest.skipUnless(shutil.which("docker"), "Docker Compose CLI is required")
    def test_shipped_apps_compose_and_declare_their_data(self):
        for app in sorted((ROOT / "apps").iterdir()):
            with self.subTest(app=app.name):
                meta = json.loads((app / "app.json").read_text())
                env = compose_environment()
                for key in meta.get("secrets", []):
                    env[key] = "test-secret"
                result = subprocess.run(
                    ["docker", "compose", "--project-directory", str(app), "-f", str(app / "compose.yaml"),
                     "--env-file", str(ROOT / ".env.example"), "config", "--format", "json"],
                    env=env, capture_output=True, text=True, timeout=30)
                self.assertEqual(result.returncode, 0, result.stderr)
                services = json.loads(result.stdout)["services"]
                host = meta["upstream"].split("//")[1].split(":")[0]
                self.assertIn(host, [s.get("container_name") for s in services.values()])
                database = meta.get("database")
                if database:
                    self.assertEqual(services[database["service"]]["container_name"], database["container"])
                # Every bind mount lives under the app's own data folder.
                for service in services.values():
                    for volume in service.get("volumes", []):
                        if volume.get("type") == "bind":
                            self.assertTrue(volume["source"].startswith(f"/DATA/apps/{app.name}"), volume["source"])

    def test_migrations_are_numbered_and_unique(self):
        names = sorted(p.name for p in (ROOT / "migrations").glob("*.sh"))
        numbers = [n[:4] for n in names]
        for name in names:
            self.assertRegex(name, r"^[0-9]{4}-[a-z0-9-]+\.sh$")
        self.assertEqual(len(numbers), len(set(numbers)))


class ProxyAndRepositoryTests(unittest.TestCase):
    def test_every_dashboard_action_is_locked_down(self):
        config = (ROOT / "config/nginx/default.conf").read_text()
        self.assertIn("limit_req_zone $binary_remote_addr zone=hbox_actions:1m rate=10r/m;", config)
        blocks = re.findall(r"location [^{]*/api/[^{]*\{(.*?)\n    \}", config, re.S)
        self.assertEqual(len(blocks), 3)  # check, update, power
        for block in blocks:
            with self.subTest(block=block.strip().splitlines()[0]):
                self.assertIn("limit_except PUT { deny all; }", block)
                self.assertIn('if ($http_x_hbox_action != "1") { return 403; }', block)
                self.assertIn("limit_req zone=hbox_actions", block)
                self.assertIn("client_max_body_size 1k;", block)
        for block in blocks[1:]:  # everything except the update check needs the login
            self.assertIn("auth_basic_user_file /etc/nginx/hbox-auth/htpasswd;", block)

    def test_hostnames_and_service_dns(self):
        config = (ROOT / "config/nginx/default.conf").read_text()
        for directive in (
            "listen 443 ssl default_server;", "server_name photos.hbox.local _;",
            "server_name files.hbox.local _;", "server_name admin.hbox.local _;",
            "listen 2443 ssl;", "listen 3443 ssl;", "listen 5443 ssl;",
            "root /usr/share/nginx/hbox-dashboard;", "alias /var/lib/hbox-dashboard/status.json;",
            "alias /var/lib/hbox-dashboard/apps.json;",
            "location = /health/photos", "location = /health/files", "location = /health/admin",
            "include /etc/nginx/hbox-apps/*.conf;", "include /etc/nginx/hbox-apps/*.health;",
            "http://immich-server:2283", "https://nextcloud-web:443", "http://hbox-dockge:5001",
            "resolver 127.0.0.11 valid=30s ipv6=off;",
            "location = /hbox-ca.crt", "location = /hbox-ca.mobileconfig",
        ):
            self.assertIn(directive, config)
        self.assertNotIn("localhost:", config)

    def test_shared_proxy_has_forwarded_headers_and_websockets(self):
        config = (ROOT / "config/nginx/hbox-proxy.inc").read_text()
        for header in ("X-Real-IP", "X-Forwarded-Proto", "Upgrade", "Connection"):
            self.assertIn(f"proxy_set_header {header} ", config)
        # Set per location; also setting them here would send them twice.
        for header in ("Host", "X-Forwarded-For"):
            self.assertNotIn(f"proxy_set_header {header} ", config)
        site = (ROOT / "config/nginx/default.conf").read_text()
        self.assertEqual(site.count("include /etc/nginx/conf.d/hbox-proxy.inc;"),
                         site.count("proxy_set_header X-Forwarded-For "))

    def test_local_secrets_ignored(self):
        ignored = (ROOT / ".gitignore").read_text().splitlines()
        for entry in (".env", "/certs/*", "/ca/", "/data/", "/stacks/*/.env", "/manager/.env",
                      "/local/", "/stacks/hbox-core/compose.override.yaml", "/stacks/hbox-app-*"):
            self.assertIn(entry, ignored)

    def test_systemd_units_reference_the_cli(self):
        for unit in ("hbox-backrest.service", "hbox-maintenance.service"):
            text = (ROOT / "systemd" / unit).read_text()
            self.assertIn("ExecStart=/usr/local/bin/hbox ", text)
        for timer in ("hbox-maintenance.timer", "hbox-update.timer"):
            text = (ROOT / "systemd" / timer).read_text()
            self.assertIn("Persistent=true", text)
            self.assertIn("WantedBy=timers.target", text)
        path = (ROOT / "systemd/hbox-dashboard.path").read_text()
        self.assertIn("DirectoryNotEmpty=/var/lib/hbox/requests", path)
        self.assertIn("ExecStart=/usr/local/bin/hbox dashboard-actions",
                      (ROOT / "systemd/hbox-dashboard.service").read_text())
        self.assertIn("hbox-dashboard.path", (ROOT / "scripts/hbox").read_text())
        update = (ROOT / "systemd/hbox-update.service").read_text()
        self.assertIn("ExecStart=/usr/local/bin/hbox update --auto", update)
        self.assertIn("Persistent=true", (ROOT / "systemd/hbox-update.timer").read_text())
        status = (ROOT / "systemd/hbox-status.service").read_text()
        self.assertIn("ExecStart=/usr/local/bin/hbox status-update", status)
        self.assertIn("OnUnitActiveSec=1min", (ROOT / "systemd/hbox-status.timer").read_text())
        self.assertIn("hbox-status.timer", (ROOT / "scripts/hbox").read_text())

    def test_shell_scripts_parse(self):
        for script in ("install.sh", "scripts/hbox", "scripts/hbox-mdns", "scripts/lib/common.sh",
                       "scripts/lib/backup.sh", "scripts/lib/apps.sh", "scripts/lib/update.sh",
                       "scripts/lib/dashboard.sh", "scripts/lib/backrest.sh", "scripts/lib/disk.sh",
                       *(str(p.relative_to(ROOT)) for p in (ROOT / "migrations").glob("*.sh"))):
            result = subprocess.run(["bash", "-n", str(ROOT / script)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, f"{script}: {result.stderr}")
        result = subprocess.run(["sh", "-n", str(ROOT / "scripts/generate-certs.sh"), str(ROOT / "scripts/ca-profile.sh")],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        for script in ("install.sh", "scripts/hbox", "scripts/hbox-mdns", "scripts/generate-certs.sh",
                       "scripts/ca-profile.sh"):
            self.assertTrue(os.access(ROOT / script, os.X_OK), f"{script} is not executable")

    def test_backrest_is_pinned_and_served_on_6443(self):
        text = (ROOT / "scripts/lib/backrest.sh").read_text()
        self.assertIn("HBOX_BACKREST_VERSION=1.14.1", text)
        self.assertIn("[amd64]=acc7835a9c55b3d254f0fa285cacbe87ac912cb7e069d0211924838020e6921c", text)
        self.assertIn("[arm64]=b53718cd6e042e7d99538cb652968ab966a5c53fabd556785648ceb13320a320", text)
        self.assertIn("sha256sum -c", text)
        unit = (ROOT / "systemd/hbox-backrest.service").read_text()
        self.assertIn("ExecStart=/usr/local/bin/hbox backup backrest-run", unit)
        core = (ROOT / "stacks/hbox-core/compose.yaml").read_text()
        self.assertIn('"6443:6443"', core)
        self.assertIn('"hbox-host:host-gateway"', core)
        self.assertIn("6443", (ROOT / "scripts/lib/apps.sh").read_text().split("HBOX_RESERVED_PORTS=")[1].split("\n")[0])

    def test_installer_pins_restic_checksums(self):
        text = (ROOT / "install.sh").read_text()
        self.assertIn("RESTIC_VERSION=0.19.1", text)
        self.assertIn("[amd64]=f415415624dcc452f2a02b8c33641791a8c6d6d3b65bbb3543fcf9a25151585c", text)
        self.assertIn("[arm64]=a5f64aaab53d51e311fa3829124c5b703f2d14cf187d8640b6be3b2b49376465", text)
        self.assertIn("sha256sum -c", text)


@unittest.skipUnless(shutil.which("openssl"), "OpenSSL is required")
class CertificateTests(unittest.TestCase):
    def run_script(self, dest, ca):
        return subprocess.run(["sh", str(ROOT / "scripts/generate-certs.sh"), str(dest), str(ca)],
                              capture_output=True, text=True, timeout=60)

    def openssl(self, *args):
        return subprocess.run(["openssl", *args], capture_output=True, text=True, check=True).stdout

    def test_ca_signed_certificate_with_sans_and_no_overwrite(self):
        with tempfile.TemporaryDirectory(prefix="hbox cert check ") as directory:
            dest, ca = Path(directory) / "certs", Path(directory) / "ca dir"
            result = self.run_script(dest, ca)
            self.assertEqual(result.returncode, 0, result.stderr)
            key, cert = dest / "selfsigned.key", dest / "selfsigned.crt"
            self.assertEqual(stat.S_IMODE(key.stat().st_mode), 0o600)
            self.assertEqual(stat.S_IMODE((ca / "ca.key").stat().st_mode), 0o600)
            self.assertEqual(stat.S_IMODE((dest / "hbox-ca.crt").stat().st_mode), 0o644)
            self.assertFalse((dest / "ca.key").exists())
            details = self.openssl("x509", "-in", str(cert), "-noout", "-text")
            for hostname in ("hbox.local", "photos.hbox.local", "files.hbox.local", "admin.hbox.local"):
                self.assertIn(f"DNS:{hostname}", details)
            # No public top-level domain ("photos" is one) and no bare
            # app names under .local, which other devices may claim.
            for hostname in ("photos", "files", "admin", "photos.local", "files.local", "admin.local"):
                self.assertNotIn(f"DNS:{hostname},", details + ",")
            # The server certificate verifies against the published HBOX CA.
            verify = subprocess.run(["openssl", "verify", "-CAfile", str(dest / "hbox-ca.crt"), str(cert)],
                                    capture_output=True, text=True)
            self.assertEqual(verify.returncode, 0, verify.stderr)
            original = key.read_bytes()
            result = self.run_script(dest, ca)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Refusing to overwrite", result.stderr)
            self.assertEqual(key.read_bytes(), original)

    def sign_probe(self, ca, san):
        """A certificate for one name, signed by the CA, as an attacker with the key would."""
        with tempfile.TemporaryDirectory(prefix="hbox probe ") as directory:
            work = Path(directory)
            subprocess.run(["openssl", "req", "-new", "-nodes", "-newkey", "ec", "-pkeyopt",
                            "ec_paramgen_curve:P-256", "-keyout", str(work / "k"), "-out", str(work / "csr"),
                            "-subj", "/CN=probe"], capture_output=True, check=True)
            (work / "ext").write_text(f"subjectAltName = {san}\n")
            subprocess.run(["openssl", "x509", "-req", "-in", str(work / "csr"), "-CA", str(ca / "ca.crt"),
                            "-CAkey", str(ca / "ca.key"), "-set_serial", "1", "-days", "1",
                            "-extfile", str(work / "ext"), "-out", str(work / "crt")],
                           capture_output=True, check=True)
            return subprocess.run(["openssl", "verify", "-CAfile", str(ca / "ca.crt"), str(work / "crt")],
                                  capture_output=True, text=True).returncode == 0

    def test_ca_only_vouches_for_hbox_names(self):
        with tempfile.TemporaryDirectory(prefix="hbox constraints ") as directory:
            dest, ca = Path(directory) / "certs", Path(directory) / "ca"
            names = "100.73.132.128,192.168.1.79,hbox,hbox.local,hbox.tail6328e7.ts.net"
            result = subprocess.run(["sh", str(ROOT / "scripts/generate-certs.sh"), str(dest), str(ca)],
                                    capture_output=True, text=True, timeout=60,
                                    env={**os.environ, "HBOX_CERT_NAMES": names})
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("X509v3 Name Constraints: critical", self.openssl("x509", "-in", str(ca / "ca.crt"),
                                                                             "-noout", "-text"))
            for san in ("DNS:hbox.local", "DNS:photos.hbox.local", "DNS:hbox", "DNS:hbox.tail6328e7.ts.net",
                        "DNS:nas.lan", "DNS:hbox.home.arpa", "IP:192.168.1.79", "IP:10.0.0.5",
                        "IP:100.73.132.128", "IP:fd7a:115c:a1e0::1", "IP:127.0.0.1"):
                with self.subTest(allowed=san):
                    self.assertTrue(self.sign_probe(ca, san))
            for san in ("DNS:www.example.com", "DNS:accounts.google.com", "DNS:local.evil.com",
                        "DNS:example.photos", "DNS:photos", "DNS:example.files", "DNS:example.admin",
                        "DNS:other.tail9999.ts.net", "DNS:ts.net", "IP:8.8.8.8", "IP:2001:4860::8888"):
                with self.subTest(refused=san):
                    self.assertFalse(self.sign_probe(ca, san))
            # The real certificate verifies and is unaffected.
            verify = subprocess.run(["openssl", "verify", "-CAfile", str(dest / "hbox-ca.crt"),
                                     str(dest / "selfsigned.crt")], capture_output=True, text=True)
            self.assertEqual(verify.returncode, 0, verify.stderr)
            self.assertFalse((dest / "names-excluded").exists())

            # A name added later that the CA may not vouch for is left out (and
            # listed), instead of making devices reject the whole certificate.
            for name in ("selfsigned.crt", "selfsigned.key"):
                (dest / name).unlink()
            result = subprocess.run(["sh", str(ROOT / "scripts/generate-certs.sh"), str(dest), str(ca)],
                                    capture_output=True, text=True, timeout=60,
                                    env={**os.environ, "HBOX_CERT_NAMES": names + ",nas.example.org,203.0.113.9"})
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual((dest / "names-excluded").read_text().split(), ["nas.example.org", "203.0.113.9"])
            sans = self.openssl("x509", "-in", str(dest / "selfsigned.crt"), "-noout", "-ext", "subjectAltName")
            self.assertNotIn("example.org", sans)
            self.assertIn("hbox.tail6328e7.ts.net", sans)
            verify = subprocess.run(["openssl", "verify", "-CAfile", str(dest / "hbox-ca.crt"),
                                     str(dest / "selfsigned.crt")], capture_output=True, text=True)
            self.assertEqual(verify.returncode, 0, verify.stderr)

    def test_ca_allows_public_names_it_was_created_with(self):
        with tempfile.TemporaryDirectory(prefix="hbox constraints ") as directory:
            dest, ca = Path(directory) / "certs", Path(directory) / "ca"
            result = subprocess.run(["sh", str(ROOT / "scripts/generate-certs.sh"), str(dest), str(ca)],
                                    capture_output=True, text=True, timeout=60,
                                    env={**os.environ, "HBOX_CERT_NAMES": "nas.example.org,203.0.113.9"})
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue(self.sign_probe(ca, "DNS:nas.example.org"))
            self.assertTrue(self.sign_probe(ca, "IP:203.0.113.9"))
            self.assertFalse(self.sign_probe(ca, "IP:203.0.113.10"))
            self.assertFalse(self.sign_probe(ca, "DNS:example.org"))
            # Before Tailscale is connected, any tailnet (enabled later).
            self.assertTrue(self.sign_probe(ca, "DNS:hbox.tail1234.ts.net"))

    def test_ca_profile_for_iphone(self):
        import base64
        import plistlib
        with tempfile.TemporaryDirectory(prefix="hbox profile ") as directory:
            dest, ca = Path(directory) / "certs", Path(directory) / "ca"
            result = self.run_script(dest, ca)
            self.assertEqual(result.returncode, 0, result.stderr)
            path = dest / "hbox-ca.mobileconfig"
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o644)
            profile = plistlib.loads(path.read_bytes())
            self.assertEqual(profile["PayloadType"], "Configuration")
            self.assertEqual(profile["PayloadVersion"], 1)
            [payload] = profile["PayloadContent"]
            self.assertEqual(payload["PayloadType"], "com.apple.security.root")
            # The payload is exactly the published CA, in DER form.
            der = subprocess.run(["openssl", "x509", "-in", str(dest / "hbox-ca.crt"), "-outform", "DER"],
                                 capture_output=True, check=True).stdout
            self.assertEqual(payload["PayloadContent"], der)
            uuid = re.compile(r"^[0-9A-F]{8}-[0-9A-F]{4}-4[0-9A-F]{3}-8[0-9A-F]{3}-[0-9A-F]{12}$")
            self.assertRegex(profile["PayloadUUID"], uuid)
            self.assertRegex(payload["PayloadUUID"], uuid)
            self.assertNotEqual(profile["PayloadUUID"], payload["PayloadUUID"])
            # The same CA always gives the same profile (installing again
            # replaces it on the device instead of adding a second one).
            again = Path(directory) / "again.mobileconfig"
            subprocess.run(["sh", str(ROOT / "scripts/ca-profile.sh"), str(dest / "hbox-ca.crt"), str(again)],
                           check=True, timeout=30)
            self.assertEqual(again.read_bytes(), path.read_bytes())

    def test_renewal_reuses_the_same_ca(self):
        with tempfile.TemporaryDirectory() as directory:
            dest, ca = Path(directory) / "certs", Path(directory) / "ca"
            self.assertEqual(self.run_script(dest, ca).returncode, 0)
            ca_before = (ca / "ca.crt").read_bytes()
            (dest / "selfsigned.crt").unlink()
            (dest / "selfsigned.key").unlink()
            self.assertEqual(self.run_script(dest, ca).returncode, 0)
            self.assertEqual((ca / "ca.crt").read_bytes(), ca_before)
            verify = subprocess.run(["openssl", "verify", "-CAfile", str(ca / "ca.crt"),
                                     str(dest / "selfsigned.crt")], capture_output=True, text=True)
            self.assertEqual(verify.returncode, 0, verify.stderr)

    def test_refuses_symlinks(self):
        with tempfile.TemporaryDirectory() as directory:
            dest = Path(directory) / "certs"
            dest.mkdir()
            (dest / "selfsigned.crt").symlink_to(dest / "missing")
            result = self.run_script(dest, Path(directory) / "ca")
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse((dest / "selfsigned.key").exists())


if __name__ == "__main__":
    unittest.main()
