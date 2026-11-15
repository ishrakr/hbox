"""Optional real nginx smoke tests, using loopback-only stub applications.

Run with NGINX_BINARY=/path/to/nginx make check. No Docker daemon, real data,
deployment certificate, privileged port, or network outside localhost is used.
"""

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import http.client
import json
import os
from pathlib import Path
import shutil
import socket
import socketserver
import ssl
import struct
import subprocess
import tempfile
import threading
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]
NGINX = os.environ.get("NGINX_BINARY") or shutil.which("nginx")


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


class StubApplication(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.headers.get("Upgrade", "").lower() == "websocket":
            self.send_response(101)
            self.send_header("Upgrade", "websocket")
            self.send_header("Connection", "upgrade")
            self.end_headers()
            return
        data = json.dumps({
            "service": self.server.app_name,
            "path": self.path,
            "host": self.headers.get("Host"),
            "host_headers": len(self.headers.get_all("Host") or []),
            "forwarded_for_headers": len(self.headers.get_all("X-Forwarded-For") or []),
            "proto": self.headers.get("X-Forwarded-Proto"),
            "real_ip": self.headers.get("X-Real-IP"),
            "forwarded_for": self.headers.get("X-Forwarded-For"),
        }).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *_args):
        pass


class DockerDNSStub(socketserver.BaseRequestHandler):
    def handle(self):
        # nginx sends one standard A query; answer with loopback, while keeping
        # the original question/transaction ID. Unknown names return NXDOMAIN.
        packet, sock = self.request
        cursor = 12
        labels = []
        while packet[cursor]:
            length = packet[cursor]
            cursor += 1
            labels.append(packet[cursor:cursor + length].decode())
            cursor += length
        end = cursor + 5  # zero byte + QTYPE + QCLASS
        name = ".".join(labels)
        known = name in {"immich-server", "nextcloud-web", "hbox-dockge", "hbox-status-kuma"}
        header = packet[:2] + struct.pack("!HHHHH", 0x8180 if known else 0x8183,
                                           1, 1 if known else 0, 0, 0)
        answer = b"\xc0\x0c" + struct.pack("!HHIH", 1, 1, 0, 4) + socket.inet_aton("127.0.0.1")
        sock.sendto(header + packet[12:end] + (answer if known else b""), self.client_address)


@unittest.skipUnless(NGINX and shutil.which("openssl"), "Set NGINX_BINARY for live proxy checks")
class NginxSmokeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="hbox-nginx-test-")
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.directory = Path(cls.temporary.name)
        cls.certs = cls.directory / "certs"
        subprocess.run(["sh", str(ROOT / "scripts/generate-certs.sh"), str(cls.certs),
                        str(cls.directory / "ca")],
                       capture_output=True, text=True, timeout=30, check=True)
        tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        tls.load_cert_chain(cls.certs / "selfsigned.crt", cls.certs / "selfsigned.key")
        ports = {}
        for name in ("immich-server", "nextcloud-web", "hbox-dockge", "hbox-status-kuma", "backrest"):
            server = ThreadingHTTPServer(("127.0.0.1", 0), StubApplication)
            server.app_name = name
            if name.startswith("nextcloud"):
                server.socket = tls.wrap_socket(server.socket, server_side=True)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            cls.addClassCleanup(cls.stop_server, server, thread)
            ports[name] = server.server_port
        dns = socketserver.UDPServer(("127.0.0.1", 0), DockerDNSStub)
        dns_thread = threading.Thread(target=dns.serve_forever, daemon=True)
        dns_thread.start()
        cls.addClassCleanup(cls.stop_server, dns, dns_thread)
        cls.http_port, cls.https_port = free_port(), free_port()
        config = (ROOT / "config/nginx/default.conf").read_text()
        # Only remap deployment paths and ports. All virtual-host logic, DNS
        # service names, TLS, headers and redirects remain the actual config.
        config = config.replace("/etc/nginx/ssl", str(cls.certs))
        # Every test connects from 127.0.0.1. Keying the actions' rate limit on
        # a test header too gives each test its own budget; rate and burst stay
        # exactly as configured (test_action_login_is_rate_limited).
        zone = "limit_req_zone $binary_remote_addr zone=hbox_actions"
        assert zone in config
        config = config.replace(zone, "limit_req_zone $binary_remote_addr$http_x_test_client zone=hbox_actions")
        # The mounted dashboard, plus files the host writes.
        config = config.replace("/usr/share/nginx/hbox-dashboard", str(ROOT / "config/dashboard"))
        cls.status = cls.directory / "status"
        cls.status.mkdir()
        (cls.status / "status.json").write_text('{"disk": {"total": 1000, "used": 250}}')
        (cls.status / "apps.json").write_text('{"sections": []}')
        config = config.replace("/var/lib/hbox-dashboard", str(cls.status))
        # One optional app, rendered the way `hbox apps enable status` does.
        cls.app_port = free_port()
        cls.apps_dir = cls.directory / "nginx-apps"
        cls.apps_dir.mkdir()
        render = subprocess.run(
            ["bash", "-c", 'set -e; . scripts/lib/common.sh; . scripts/lib/apps.sh; '
             'HBOX_NGINX_APPS_DIR="$1"; app_validate status; app_render_nginx status', "_",
             str(cls.apps_dir)],
            cwd=ROOT, capture_output=True, text=True, timeout=30,
            env={**os.environ, "HBOX_HOME": str(ROOT), "HBOX_ENV_FILE": "/nonexistent"})
        if render.returncode:
            raise AssertionError(f"rendering the status app failed: {render.stderr}")
        app_port = json.loads((ROOT / "apps/status/app.json").read_text())["port"]
        for generated in cls.apps_dir.iterdir():
            text = generated.read_text().replace(f"listen {app_port} ", f"listen 127.0.0.1:{cls.app_port} ")
            text = text.replace("/etc/nginx/conf.d/hbox-proxy.inc", str(ROOT / "config/nginx/hbox-proxy.inc"))
            text = text.replace("hbox-status-kuma:3001", f"hbox-status-kuma:{ports['hbox-status-kuma']}")
            generated.write_text(text)
        config = config.replace("/etc/nginx/hbox-apps", str(cls.apps_dir))
        # Dashboard buttons: a request folder and the admin login (user:secret).
        cls.requests = cls.directory / "requests"
        cls.requests.mkdir()
        cls.auth = cls.directory / "auth"
        cls.auth.mkdir()
        hashed = subprocess.run(["openssl", "passwd", "-apr1", "-stdin"], input="secret",
                                capture_output=True, text=True, check=True).stdout.strip()
        (cls.auth / "htpasswd").write_text(f"admin:{hashed}\n")
        config = config.replace("/var/lib/hbox-requests", str(cls.requests))
        config = config.replace("/etc/nginx/hbox-auth", str(cls.auth))
        config = config.replace("/etc/nginx/conf.d/hbox-proxy.inc",
                                str(ROOT / "config/nginx/hbox-proxy.inc"))
        config = config.replace("listen 80 ", f"listen 127.0.0.1:{cls.http_port} ")
        config = config.replace("listen 443 ", f"listen 127.0.0.1:{cls.https_port} ")
        cls.photos_port, cls.files_port, cls.admin_port = free_port(), free_port(), free_port()
        config = config.replace("listen 2443 ", f"listen 127.0.0.1:{cls.photos_port} ")
        config = config.replace("listen 3443 ", f"listen 127.0.0.1:{cls.files_port} ")
        config = config.replace("listen 5443 ", f"listen 127.0.0.1:{cls.admin_port} ")
        config = config.replace("127.0.0.11", f"127.0.0.1:{dns.server_address[1]}")
        # Backrest on the host (hbox-host is an extra_hosts entry in the container).
        config = config.replace("hbox-host:9898", f"127.0.0.1:{ports['backrest']}")
        cls.backups_port = free_port()
        config = config.replace("listen 6443 ", f"listen 127.0.0.1:{cls.backups_port} ")
        for name, old_port in (("immich-server", 2283), ("nextcloud-web", 443), ("hbox-dockge", 5001)):
            config = config.replace(f"{name}:{old_port}", f"{name}:{ports[name]}")
        path = cls.directory / "nginx.conf"
        path.write_text(
            f"daemon off;\nmaster_process off;\npid {cls.directory}/nginx.pid;\n"
            "error_log stderr;\nevents {}\nhttp {\naccess_log off;\n"

            # The image's main nginx.conf includes mime.types; these are the ones used.
            "types { text/html html; text/css css; application/javascript js;"
            " application/json json; image/svg+xml svg; }\ndefault_type application/octet-stream;\n"
            # Distro binaries may default to root-owned /var/lib/nginx paths.
            + "\n".join(f"{directive}_temp_path {cls.directory}/{directive};"
                        for directive in ("client_body", "proxy", "fastcgi", "uwsgi", "scgi"))
            + "\n" + config + "\n}\n"
        )
        command = [NGINX, "-p", str(cls.directory) + "/", "-c", str(path)]
        result = subprocess.run([*command, "-t"], capture_output=True, text=True, timeout=10)
        if result.returncode:
            raise AssertionError(f"nginx -t failed: {result.stderr}")
        cls.log = (cls.directory / "nginx.log").open("w+")
        cls.addClassCleanup(cls.log.close)
        cls.process = subprocess.Popen(command, stdout=cls.log, stderr=cls.log)
        cls.addClassCleanup(cls.stop_nginx)
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if cls.process.poll() is not None:
                cls.log.seek(0)
                raise AssertionError(f"nginx exited: {cls.log.read()}")
            try:
                with socket.create_connection(("127.0.0.1", cls.http_port), timeout=0.1):
                    return
            except OSError:
                time.sleep(0.02)
        raise AssertionError("nginx did not start")

    @staticmethod
    def stop_server(server, thread):
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)

    @classmethod
    def stop_nginx(cls):
        if cls.process.poll() is None:
            cls.process.terminate()
            try:
                cls.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                cls.process.kill()
                cls.process.wait(timeout=5)

    def request(self, host, path="/", *, secure=True, headers=None, port=None, method="GET", body=None):
        if secure:
            # Trust precisely the generated test certificate, not arbitrary TLS.
            context = ssl.create_default_context(cafile=str(self.certs / "hbox-ca.crt"))
            context.check_hostname = False  # stubs are reached by 127.0.0.1
            connection = http.client.HTTPSConnection("127.0.0.1", port or self.https_port,
                                                     context=context, timeout=5)
        else:
            connection = http.client.HTTPConnection("127.0.0.1", self.http_port, timeout=5)
        try:
            connection.request(method, path, body=body, headers={"Host": host, **(headers or {})})
            response = connection.getresponse()
            return response.status, dict(response.getheaders()), response.read()
        finally:
            connection.close()

    def test_http_to_https_redirect_preserves_path_and_query(self):
        status, headers, _ = self.request("hbox.local", "/some/path?x=1", secure=False)
        self.assertEqual(status, 302)
        self.assertEqual(headers["Location"], "https://hbox.local/some/path?x=1")

    def test_all_hostnames_proxy_to_correct_backend_with_headers(self):
        for host, service in (
            ("photos.hbox.local", "immich-server"),
            ("files.hbox.local", "nextcloud-web"),
            ("admin.hbox.local", "hbox-dockge"),
        ):
            with self.subTest(host=host):
                status, _, body = self.request(host, "/api/check?name=hbox&x=1")
                self.assertEqual(status, 200, body.decode())
                data = json.loads(body)
                self.assertEqual(data["service"], service)
                self.assertEqual(data["host"], host)
                self.assertEqual(data["path"], "/api/check?name=hbox&x=1")
                self.assertEqual(data["proto"], "https")
                self.assertEqual(data["real_ip"], "127.0.0.1")
                self.assertEqual(data["forwarded_for"], "127.0.0.1")
                self.assertEqual(data["host_headers"], 1)
                self.assertEqual(data["forwarded_for_headers"], 1)

    def test_retired_names_show_the_dashboard(self):
        # photos.local, photos, ... are no longer HBOX's: they reach the
        # dashboard like any unknown name, never an app.
        index = (ROOT / "config/dashboard/index.html").read_bytes()
        for host in ("photos.local", "photos", "files.local", "files", "admin.local", "admin"):
            with self.subTest(host=host):
                status, _, body = self.request(host, "/")
                self.assertEqual(status, 200)
                self.assertEqual(body, index)

    def test_ca_certificate_is_served_over_plain_http(self):
        for secure in (False, True):
            status, headers, body = self.request("hbox.local", "/hbox-ca.crt", secure=secure)
            self.assertEqual(status, 200)
            self.assertEqual(headers["Content-Type"], "application/x-x509-ca-cert")
            self.assertEqual(body, (self.certs / "hbox-ca.crt").read_bytes())
        # The iPhone profile, with the type Safari offers to install.
        for secure in (False, True):
            status, headers, body = self.request("hbox.local", "/hbox-ca.mobileconfig", secure=secure)
            self.assertEqual(status, 200)
            self.assertEqual(headers["Content-Type"], "application/x-apple-aspen-config")
            self.assertEqual(body, (self.certs / "hbox-ca.mobileconfig").read_bytes())
        # Nothing else in the certificate directory is reachable.
        status, _, _ = self.request("hbox.local", "/selfsigned.key", secure=False)
        self.assertEqual(status, 302)

    def test_any_name_or_address_reaches_the_dashboard(self):
        index = (ROOT / "config/dashboard/index.html").read_bytes()
        for host in ("hbox.local", "hbox", "192.168.1.20", "100.101.102.103", "hbox.tail1234.ts.net", "server.local"):
            with self.subTest(host=host):
                status, headers, body = self.request(host, "/")
                self.assertEqual((status, body), (200, index))
                self.assertIn("script-src 'self'", headers["Content-Security-Policy"])
        # Unknown paths fall back to the dashboard; its files are served as-is.
        self.assertEqual(self.request("hbox.local", "/no/such/page")[2], index)
        for name, kind in (("app.js", "javascript"), ("style.css", "css"), ("favicon.svg", "svg")):
            with self.subTest(file=name):
                status, headers, body = self.request("hbox.local", f"/{name}")
                self.assertEqual(status, 200)
                self.assertIn(kind, headers["Content-Type"])
                self.assertEqual(body, (ROOT / "config/dashboard" / name).read_bytes())

    def test_status_and_health_endpoints(self):
        status, headers, body = self.request("100.101.102.103", "/status.json")
        self.assertEqual(status, 200)
        self.assertEqual(headers["Cache-Control"], "no-store")
        self.assertEqual(json.loads(body)["disk"]["used"], 250)
        for path, service, upstream_path in (("/health/photos", "immich-server", "/api/server/ping"),
                                             ("/health/files", "nextcloud-web", "/status.php"),
                                             ("/health/admin", "hbox-dockge", "/"),
                                             ("/health/backups", "backrest", "/")):
            with self.subTest(path=path):
                status, _, body = self.request("hbox.local", path)
                self.assertEqual(status, 200)
                data = json.loads(body)
                self.assertEqual((data["service"], data["path"]), (service, upstream_path))
                self.assertEqual((data["host_headers"], data["forwarded_for_headers"]), (1, 1))

    def test_paths_redirect_to_each_apps_port(self):
        for host in ("hbox.local", "100.101.102.103", "hbox.tail1234.ts.net"):
            for path, port in (("/photos", 2443), ("/photos/x", 2443), ("/files", 3443),
                               ("/files/apps/files", 3443), ("/admin", 5443), ("/admin/", 5443),
                               ("/backups", 6443), ("/backups/x", 6443)):
                with self.subTest(host=host, path=path):
                    status, headers, _ = self.request(host, path)
                    self.assertEqual(status, 302)
                    self.assertEqual(headers["Location"], f"https://{host}:{port}/")
        status, headers, _ = self.request("hbox.local", "/.well-known/caldav")
        self.assertEqual((status, headers["Location"]), (301, "https://hbox.local:3443/remote.php/dav"))

    def test_files_port_keeps_host_and_port_for_nextcloud(self):
        for host in ("192.168.1.20", "hbox.tail1234.ts.net", "100.101.102.103"):
            with self.subTest(host=host):
                status, _, body = self.request(f"{host}:3443", "/remote.php/dav?x=1", port=self.files_port)
                self.assertEqual(status, 200)
                data = json.loads(body)
                self.assertEqual(data["service"], "nextcloud-web")
                self.assertEqual(data["path"], "/remote.php/dav?x=1")
                # Nextcloud builds its links from Host, so the port must stay in it.
                self.assertEqual(data["host"], f"{host}:3443")
                self.assertEqual(data["forwarded_for"], "127.0.0.1")
                self.assertEqual((data["host_headers"], data["forwarded_for_headers"]), (1, 1))
        status, headers, _ = self.request("192.168.1.20:3443", "/.well-known/carddav", port=self.files_port)
        self.assertEqual(headers["Location"], "https://192.168.1.20:3443/remote.php/dav")

    def test_optional_app_on_its_own_port_with_health_check(self):
        status, _, body = self.request("192.168.1.20:4443", "/dashboard", port=self.app_port)
        self.assertEqual(status, 200)
        data = json.loads(body)
        self.assertEqual((data["service"], data["path"], data["host"]),
                         ("hbox-status-kuma", "/dashboard", "192.168.1.20:4443"))
        status, _, body = self.request("hbox.local", "/health/status")
        self.assertEqual((status, json.loads(body)["service"]), (200, "hbox-status-kuma"))

    def test_backups_port_proxies_to_backrest_on_the_host(self):
        for host in ("192.168.1.20", "hbox.tail1234.ts.net"):
            with self.subTest(host=host):
                status, _, body = self.request(f"{host}:6443", "/v1.Backrest/GetConfig", port=self.backups_port)
                self.assertEqual(status, 200)
                data = json.loads(body)
                self.assertEqual((data["service"], data["path"], data["host"]),
                                 ("backrest", "/v1.Backrest/GetConfig", f"{host}:6443"))
                self.assertEqual((data["host_headers"], data["forwarded_for_headers"]), (1, 1))

    def test_photos_and_admin_ports_serve_any_name(self):
        for port_name, service, port in (("photos_port", "immich-server", 2443),
                                         ("admin_port", "hbox-dockge", 5443)):
            for host in ("100.101.102.103", "hbox.tail1234.ts.net", "192.168.1.20"):
                with self.subTest(service=service, host=host):
                    status, _, body = self.request(f"{host}:{port}", "/api/x", port=getattr(self, port_name))
                    self.assertEqual(status, 200)
                    data = json.loads(body)
                    self.assertEqual(data["service"], service)
                    self.assertEqual(data["host"], f"{host}:{port}")

    def test_action_login_is_rate_limited(self):
        import base64
        bad = "Basic " + base64.b64encode(b"admin:wrong").decode()
        headers = {"X-HBOX-Action": "1", "Authorization": bad, "X-Test-Client": "rate"}
        codes = [self.request("hbox.local", "/api/power/restart", method="PUT", body="1", headers=headers)[0]
                 for _ in range(10)]
        # One allowed plus a burst of 5, then refused while guessing continues.
        self.assertEqual(codes[:6], [403] * 6)
        self.assertEqual(codes[6:], [503] * 4)
        self.assertFalse((self.requests / "restart").exists())

    def test_dashboard_buttons_request_actions_safely(self):
        import base64
        good = "Basic " + base64.b64encode(b"admin:secret").decode()
        bad = "Basic " + base64.b64encode(b"admin:wrong").decode()
        action = {"X-HBOX-Action": "1", "X-Test-Client": "buttons"}
        # Without the custom header (e.g. a form on another site): refused.
        self.assertEqual(self.request("hbox.local", "/api/check", method="PUT", body="1")[0], 403)
        # Only PUT is allowed; GET never reads the folder.
        self.assertEqual(self.request("hbox.local", "/api/check", headers=action)[0], 403)
        # Check needs no login.
        status, _, _ = self.request("hbox.local", "/api/check", method="PUT", body="1", headers=action)
        self.assertIn(status, (201, 204))
        self.assertTrue((self.requests / "check").exists())
        # Update needs the admin login. Failures are 403 (browsers only show
        # their password popup for 401), so the dashboard's form is used.
        for auth in (None, bad):
            with self.subTest(auth=bool(auth)):
                headers = {**action, **({"Authorization": auth} if auth else {})}
                status, _, body = self.request("hbox.local", "/api/update",
                                               method="PUT", body="1", headers=headers)
                self.assertEqual(status, 403)
                self.assertEqual(json.loads(body), {"error": "login"})
                self.assertFalse((self.requests / "update").exists())
        status, _, _ = self.request("hbox.local", "/api/update", method="PUT", body="1",
                                    headers={**action, "Authorization": good})
        self.assertIn(status, (201, 204))
        self.assertTrue((self.requests / "update").exists())
        # Power actions: the same header and login, one fixed file each.
        powers = ["apps-restart", "apps-start", "apps-stop", "restart", "shutdown"]
        refused = [("/api/power/restart", {"Authorization": good, "X-Test-Client": "refused"}),  # no header
                   ("/api/power/shutdown", {**action, "X-Test-Client": "refused"}),             # no login
                   ("/api/power/shutdown", {**action, "Authorization": bad, "X-Test-Client": "refused"})]
        for path, headers in refused:
            with self.subTest(refused=path, headers=sorted(headers)):
                self.assertEqual(self.request("hbox.local", path, method="PUT", body="1", headers=headers)[0], 403)
        self.assertFalse((self.requests / "restart").exists())
        self.assertFalse((self.requests / "shutdown").exists())
        for name in powers:
            with self.subTest(power=name):
                status, _, _ = self.request("hbox.local", f"/api/power/{name}", method="PUT", body="1",
                                            headers={**action, "Authorization": good, "X-Test-Client": name})
                self.assertIn(status, (201, 204))
                self.assertTrue((self.requests / name).exists())
        # Nothing else can be written there.
        # (A path like /api/power/../update is normalised by nginx to
        # /api/update, the update button itself.)
        for path in ("/api/other", "/api/power/other", "/api/power/restart/x", "/api/power/%2e%2e%2fescape",
                     "/api/power/..%2f..%2fescape", "/api/power/restart%00"):
            with self.subTest(path=path):
                status, _, _ = self.request("hbox.local", path, method="PUT", body="1",
                                            headers={**action, "Authorization": good, "X-Test-Client": path})
                self.assertNotIn(status, (201, 204))
        self.assertEqual(sorted(p.name for p in self.requests.iterdir()), sorted(["check", "update", *powers]))
        self.assertFalse((self.directory / "escape").exists())
        # Progress is readable and never cached.
        (self.status / "power.json").write_text('{"state": "idle"}')
        status, headers, _ = self.request("hbox.local", "/power.json")
        self.assertEqual(status, 200)
        self.assertEqual(headers["Cache-Control"], "no-store")

    def test_nextcloud_discovery_redirects(self):
        for path in ("carddav", "caldav"):
            with self.subTest(path=path):
                status, headers, _ = self.request("files.hbox.local", f"/.well-known/{path}")
                self.assertEqual(status, 301)
                self.assertEqual(headers["Location"], "https://files.hbox.local/remote.php/dav")
        status, headers, _ = self.request("files.hbox.local", "/.well-known/webfinger?resource=abc")
        self.assertEqual(status, 301)
        self.assertEqual(headers["Location"],
                         "https://files.hbox.local/index.php/.well-known/webfinger?resource=abc")

    def test_websocket_upgrade(self):
        status, headers, _ = self.request("photos.hbox.local", "/socket", headers={
            "Upgrade": "websocket", "Connection": "Upgrade",
        })
        self.assertEqual(status, 101)
        self.assertEqual(headers["Upgrade"].lower(), "websocket")


if __name__ == "__main__":
    unittest.main()
