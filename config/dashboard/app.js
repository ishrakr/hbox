// HBOX dashboard: app cards with live status, server facts and updates.
// No dependencies. Apps are linked by port on the address the dashboard was
// opened with, so hbox.local, the LAN IP and Tailscale names all work.
"use strict";

// Fallback line icons for items without a logo file.
const ICONS = {
  link: '<path d="M10 14a4 4 0 0 0 5.66 0l3-3a4 4 0 0 0-5.66-5.66l-1 1"/><path d="M14 10a4 4 0 0 0-5.66 0l-3 3a4 4 0 0 0 5.66 5.66l1-1"/>',
  app: '<rect x="4" y="4" width="7" height="7" rx="1.5"/><rect x="13" y="4" width="7" height="7" rx="1.5"/><rect x="4" y="13" width="7" height="7" rx="1.5"/><rect x="13" y="13" width="7" height="7" rx="1.5"/>',
};

const $ = (id) => document.getElementById(id);
const healthUrl = (name) => `/health/${encodeURIComponent(name)}`;

function element(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

// An item opens a port on this address, or a path/URL ("href").
function itemUrl(item) {
  if (Number.isInteger(item.port) && item.port > 0 && item.port < 65536) {
    return `https://${location.hostname}:${item.port}${item.path || "/"}`;
  }
  return item.href || "#";
}

// "logo" is a file in /icons (shipped) or an https URL; otherwise a line icon.
function logoNode(item) {
  const box = element("span", "logo");
  const logo = typeof item.logo === "string" ? item.logo : "";
  // Shipped logos by file name; optional apps' logos under /app-icons/.
  if (/^[a-z0-9-]+\.(svg|png)$/.test(logo) || /^\/app-icons\/app-[a-z0-9-]+\.(svg|png)$/.test(logo)) {
    const img = element("img");
    img.src = logo.startsWith("/") ? logo : `/icons/${logo}`;
    img.alt = "";
    img.width = 36;
    img.height = 36;
    img.addEventListener("error", () => { img.replaceWith(lineIcon(item.icon)); }, { once: true });
    box.append(img);
  } else {
    box.append(lineIcon(item.icon));
  }
  return box;
}

function lineIcon(name) {
  const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
  svg.setAttribute("viewBox", "0 0 24 24");
  svg.setAttribute("aria-hidden", "true");
  svg.innerHTML = ICONS[name] || ICONS.app; // constants above, never data
  return svg;
}

function renderSections(config) {
  const container = $("sections");
  container.replaceChildren();
  for (const section of config.sections || []) {
    const items = section.items || [];
    if (items.length === 0) continue;
    const wrapper = element("section");
    wrapper.append(element("h2", "", section.name));
    const grid = element("div", "apps");
    for (const item of items) {
      const card = element("a", "app");
      card.href = itemUrl(item);
      card.setAttribute("aria-label", `Open ${item.name}`);

      const text = element("div");
      text.append(element("div", "app-name", item.name));
      if (item.description) text.append(element("div", "app-description", item.description));

      const foot = element("div", "app-foot");
      if (item.health) {
        const status = element("span", "status", "Checking…");
        status.dataset.health = item.health;
        foot.append(status);
      } else {
        foot.append(element("span"));
      }
      foot.append(element("span", "open", "Open →"));

      card.append(logoNode(item), text, foot);
      grid.append(card);
    }
    wrapper.append(grid);
    container.append(wrapper);
  }
}

async function checkHealth() {
  const checks = [...document.querySelectorAll(".status[data-health]")].map(async (node) => {
    let up = false;
    try {
      const response = await fetch(healthUrl(node.dataset.health), { cache: "no-store", redirect: "manual" });
      up = response.type === "opaqueredirect" || response.ok || response.status === 401;
    } catch {
      up = false;
    }
    node.className = `status ${up ? "ok" : "bad"}`;
    node.textContent = up ? "Running" : "Not responding";
    return up;
  });
  const results = await Promise.all(checks);
  if (results.length === 0) return;
  const down = results.filter((up) => !up).length;
  const pill = $("overall");
  pill.hidden = false;
  pill.className = `pill ${down ? "bad" : "ok"}`;
  $("overall-text").textContent = down
    ? `${down} app${down > 1 ? "s" : ""} not responding`
    : "All apps running";
}

function formatBytes(bytes) {
  const units = ["B", "KB", "MB", "GB", "TB", "PB"];
  let value = bytes;
  let unit = 0;
  while (value >= 1000 && unit < units.length - 1) {
    value /= 1000;
    unit += 1;
  }
  return `${value.toFixed(value < 10 && unit > 0 ? 1 : 0)} ${units[unit]}`;
}

function formatAge(iso) {
  const then = new Date(iso);
  if (Number.isNaN(then.getTime())) return "";
  const minutes = Math.round((Date.now() - then.getTime()) / 60000);
  if (minutes < 1) return "just now";
  if (minutes < 60) return `${minutes} min ago`;
  const hours = Math.round(minutes / 60);
  if (hours < 48) return `${hours} h ago`;
  return `${Math.round(hours / 24)} days ago`;
}

function formatWhen(value) {
  const date = new Date(value || "");
  if (Number.isNaN(date.getTime())) return "";
  const today = new Date();
  const tomorrow = new Date(today.getTime() + 86400000);
  const time = date.toLocaleTimeString(undefined, { hour: "2-digit", minute: "2-digit" });
  if (date.toDateString() === today.toDateString()) return `today ${time}`;
  if (date.toDateString() === tomorrow.toDateString()) return `tomorrow ${time}`;
  return date.toLocaleString(undefined, { weekday: "short", hour: "2-digit", minute: "2-digit" });
}

// Bytes per second as bits per second, the unit internet plans use.
function formatRate(bytesPerSecond) {
  const units = ["bit/s", "kbit/s", "Mbit/s", "Gbit/s"];
  let value = Math.max(0, bytesPerSecond) * 8;
  let unit = 0;
  while (value >= 1000 && unit < units.length - 1) {
    value /= 1000;
    unit += 1;
  }
  return `${value.toFixed(value < 10 && unit > 0 ? 1 : 0)} ${units[unit]}`;
}

// Tone of a value: calm until it needs attention.
function level(percent, warn, high) {
  if (percent >= high) return "high";
  if (percent >= warn) return "warn";
  return "";
}

function setVital(id, tone, tooltip) {
  const node = $(id);
  node.classList.toggle("warn", tone === "warn");
  node.classList.toggle("high", tone === "high");
  node.title = tooltip || "";
}

// The status line: one value per resource, details on hover or tap.
function renderVitals(status) {
  const system = status.system || {};
  const history = Array.isArray(system.history) ? system.history : [];
  const latest = history[history.length - 1];
  const minutes = history.length > 1 ? Math.round((latest.t - history[0].t) / 60) : 0;

  if (latest) {
    const cpu = Math.round(latest.cpu);
    const values = history.map((s) => s.cpu);
    const average = Math.round(values.reduce((sum, v) => sum + v, 0) / values.length);
    const peak = Math.round(Math.max(...values));
    $("cpu-text").textContent = `${cpu}%`;
    setVital("vital-cpu", level(cpu, 70, 90), [
      system.cpus ? `${system.cpus} cores` : "",
      minutes > 1 ? `average ${average}%, peak ${peak}% in the last ${minutes} min` : "",
    ].filter(Boolean).join(" · "));

    $("net-rx").textContent = formatRate(latest.rx);
    $("net-tx").textContent = formatRate(latest.tx);
    let totals = "";
    if (minutes > 1) {
      const sum = history.slice(1).reduce((acc, s, i) => {
        const seconds = s.t - history[i].t;
        return { rx: acc.rx + s.rx * seconds, tx: acc.tx + s.tx * seconds };
      }, { rx: 0, tx: 0 });
      totals = `${formatBytes(sum.rx)} down, ${formatBytes(sum.tx)} up in the last ${minutes} min`;
    }
    setVital("vital-net", "", totals);
  } else {
    $("cpu-text").textContent = "–";
    $("net-rx").textContent = "–";
    $("net-tx").textContent = "–";
  }

  const memory = system.memory || {};
  if (memory.total > 0) {
    const percent = Math.round((memory.used / memory.total) * 100);
    $("mem-text").textContent = `${percent}%`;
    setVital("vital-mem", level(percent, 80, 90), [
      `${formatBytes(memory.used)} of ${formatBytes(memory.total)} in use`,
      memory.swap_used > 64e6 ? `${formatBytes(memory.swap_used)} swap` : "",
    ].filter(Boolean).join(" · "));
  }

  const disk = status.disk || {};
  if (disk.total > 0) {
    const percent = Math.round((disk.used / disk.total) * 100);
    $("disk-text").textContent = `${formatBytes(disk.total - disk.used)} free`;
    $("disk-bar").style.width = `${percent}%`;
    setVital("vital-disk", level(percent, 80, 90),
      `${percent}% of ${formatBytes(disk.total)} used`);
  }

  renderHealth(Array.isArray(status.disks) ? status.disks : []);
}

// Drive health as one item: quiet when healthy, a sentence when not.
function renderHealth(disks) {
  const known = disks.filter((d) => ["ok", "warning", "failing"].includes(d.status));
  const item = $("vital-health");
  const alert = $("health-alert");
  item.hidden = known.length === 0;
  if (known.length === 0) {
    alert.hidden = true;
    return;
  }
  const name = (d) => (d.role === "backup" ? "backup disk" : "server disk");
  const describe = (d) => [d.model, typeof d.temperature === "number" ? `${d.temperature} °C` : ""]
    .filter(Boolean).join(", ");
  const bad = known.filter((d) => d.status !== "ok");
  const failing = bad.some((d) => d.status === "failing");
  item.classList.toggle("warn", bad.length > 0 && !failing);
  item.classList.toggle("high", failing);
  $("health-text").textContent = bad.length === 0
    ? (known.length > 1 ? "Disks healthy" : "Disk healthy")
    : `${bad.length > 1 ? "Disks need" : "A disk needs"} attention`;
  item.title = known.map((d) => `${name(d)}: ${d.status === "ok" ? "healthy" : d.status} (${describe(d)})`).join("\n");

  alert.hidden = bad.length === 0;
  alert.className = `health-alert${failing ? " high" : ""}`;
  alert.textContent = bad.map((d) => {
    const what = d.status === "failing" ? "is failing" : "is showing wear";
    const problems = Array.isArray(d.problems) && d.problems.length ? ` (${d.problems.join(", ")})` : "";
    return `The ${name(d)} ${what}${problems}. Copy what matters and plan to replace it; sudo hbox doctor has details.`;
  }).join(" ");
}

let serverStatus = {};

async function loadStatus() {
  try {
    const response = await fetch("/status.json", { cache: "no-store" });
    if (!response.ok) return;
    serverStatus = await response.json();
  } catch {
    return;
  }
  const status = serverStatus;
  $("server").hidden = false;

  renderVitals(status);
  renderPowerMenu();

  const backup = status.backup || {};
  const text = $("backup-text");
  const note = $("backup-next");
  const next = backup.next ? `Next ${formatWhen(backup.next)}` : "";
  const size = backup.protected > 0 ? `${formatBytes(backup.protected)} protected` : "";
  const count = backup.snapshots > 0 ? `${backup.snapshots} backup${backup.snapshots > 1 ? "s" : ""}` : "";
  if (!backup.configured) {
    text.textContent = "Not set up";
    text.className = "tile-value bad";
    note.textContent = "Your data is not backed up. Attach a disk and run: sudo hbox backup disk";
  } else if (backup.connected === false) {
    text.textContent = "Backup disk not connected";
    text.className = "tile-value bad";
    note.textContent = backup.time
      ? `Last backup ${formatAge(backup.time)}. Plug the disk back in; backups resume on their own.`
      : "Plug the backup disk back in; backups resume on their own.";
  } else if (backup.result === "running") {
    text.textContent = "Backing up now…";
    text.className = "tile-value";
    note.textContent = [count, size].filter(Boolean).join(" · ");
  } else if (!backup.time) {
    text.textContent = "No backup yet";
    text.className = "tile-value";
    note.textContent = backup.next ? `First backup ${formatWhen(backup.next)}` : "";
  } else {
    const ok = backup.result === "success" || backup.result === "warning";
    text.textContent = ok ? `Backed up ${formatAge(backup.time)}` : "Last backup failed";
    text.className = ok ? "tile-value" : "tile-value bad";
    note.textContent = ok
      ? [next, count, size].filter(Boolean).join(" · ")
      : `${formatAge(backup.time)}. Open Backups for details.`;
  }

  renderVersion();
  if (status.updated) $("updated").textContent = `Updated ${formatAge(status.updated)}`;
}

// ---------------------------------------------------------------- updates

let action = { state: "idle" };
let pollTimer = null;

function renderVersion() {
  const hbox = serverStatus.hbox || {};
  const busy = action.state === "checking" || action.state === "updating";
  $("version-text").textContent = hbox.version ? `HBOX ${hbox.version}` : "HBOX";
  const note = $("version-note");
  if (hbox.update_available) {
    note.textContent = `Version ${hbox.latest || "update"} is available`;
    note.className = "tile-note attention";
  } else if (hbox.checked) {
    note.textContent = `Up to date · checked ${formatAge(hbox.checked)}`;
    note.className = "tile-note";
  } else {
    note.textContent = "";
    note.className = "tile-note";
  }
  $("update-button").hidden = !hbox.update_available;
  $("update-button").disabled = busy;
  $("check-button").disabled = busy;
}

function renderProgress() {
  const box = $("update-progress");
  const text = $("update-progress-text");
  const shown = { checking: true, updating: true, done: true, failed: true }[action.state];
  box.hidden = !shown;
  box.className = `progress ${action.state}`;
  if (action.state === "checking") text.textContent = "Checking for updates…";
  else if (action.state === "updating") text.textContent = "Updating — backing up, then installing. This can take a few minutes; apps may briefly be unavailable.";
  else if (action.state === "done") text.textContent = action.message || "Update complete.";
  else if (action.state === "failed") text.textContent = `Update failed: ${action.message || "see sudo hbox update on the server"}`;
  renderVersion();
}

async function loadAction() {
  try {
    const response = await fetch("/update.json", { cache: "no-store" });
    if (!response.ok) return;
    const next = await response.json();
    // Ignore results older than this page's own request.
    if (action.since && new Date(next.time) < action.since) return;
    const finished = (action.state === "checking" || action.state === "updating") &&
      !(next.state === "checking" || next.state === "updating");
    action = { ...next, since: action.since };
    if (action.state === "idle" && finished) action.state = "idle";
    renderProgress();
    if (finished) {
      await loadStatus();
      if (action.state === "done") setTimeout(() => location.reload(), 2500);
    }
  } catch {
    // nginx restarts during an update; keep polling.
  }
}

function startPolling() {
  clearInterval(pollTimer);
  pollTimer = setInterval(async () => {
    await loadAction();
    if (!(action.state === "checking" || action.state === "updating")) clearInterval(pollTimer);
  }, 3000);
}

async function request(path, headers = {}) {
  return fetch(path, {
    method: "PUT",
    headers: { "X-HBOX-Action": "1", ...headers },
    body: String(Date.now()),
    cache: "no-store",
  });
}

async function checkForUpdates() {
  action = { state: "checking", since: new Date(Date.now() - 2000) };
  renderProgress();
  try {
    const response = await request("/api/check");
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    startPolling();
  } catch (error) {
    action = { state: "failed", message: `could not reach the server (${error.message})` };
    renderProgress();
  }
}

// The login dialog serves the update and every power action.
const LOGIN_TEXTS = {
  update: ["Install the update", "HBOX backs up first, then updates. Apps may be unavailable for a few minutes.", "Update now", false],
  "apps-restart": ["Restart the apps?", "Photos, Files and optional apps stop and start again. They are unavailable for a minute or two.", "Restart apps", false],
  "apps-stop": ["Stop the apps?", "Photos, Files and optional apps stop until you start them again, also after a restart. The dashboard, Admin, Backups and remote access keep running.", "Stop apps", true],
  "apps-start": ["Start the apps?", "Photos, Files and optional apps start again.", "Start apps", false],
  restart: ["Restart the server?", "Everything is unavailable for a few minutes, including remote access. HBOX waits for a running backup or update to finish first.", "Restart server", true],
  shutdown: ["Shut down the server?", "The server turns off. It cannot be started from here: someone has to press its power button. HBOX waits for a running backup or update to finish first.", "Shut down", true],
};
let loginFor = "update";

function openLogin(what = "update") {
  loginFor = typeof what === "string" ? what : "update";
  const [title, text, submit, danger] = LOGIN_TEXTS[loginFor];
  $("login-title").textContent = title;
  $("login-text").textContent = text;
  $("login-submit").textContent = submit;
  $("login-submit").classList.toggle("danger", danger);
  $("login-error").hidden = true;
  $("login-password").value = "";
  $("login").showModal();
  ($("login-user").value ? $("login-password") : $("login-user")).focus();
}

async function submitLogin(event) {
  event.preventDefault();
  const user = $("login-user").value.trim();
  const password = $("login-password").value;
  const bytes = new TextEncoder().encode(`${user}:${password}`);
  const auth = btoa(String.fromCharCode(...bytes));
  try {
    const path = loginFor === "update" ? "/api/update" : `/api/power/${loginFor}`;
    const response = await request(path, { Authorization: `Basic ${auth}` });
    if (response.status === 403 || response.status === 401) {
      $("login-error").textContent = "That user name or password is not right.";
      $("login-error").hidden = false;
      return;
    }
    if (response.status === 503 || response.status === 429) {
      $("login-error").textContent = "Too many attempts. Wait a minute and try again.";
      $("login-error").hidden = false;
      return;
    }
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    try { localStorage.setItem("hbox-user", user); } catch { /* private mode */ }
    $("login").close();
    if (loginFor !== "update") {
      startPower(loginFor);
      return;
    }
    action = { state: "updating", since: new Date(Date.now() - 2000) };
    renderProgress();
    startPolling();
  } catch (error) {
    $("login-error").textContent = `Could not reach the server (${error.message}).`;
    $("login-error").hidden = false;
  }
}

// ---------------------------------------------------------------- power

let power = { state: "idle" };
let powerTimer = null;
const POWER_BUSY = ["restart", "shutdown", "apps-restart", "apps-stop", "apps-start"];

function toggleMenu(open) {
  const menu = $("power-menu");
  const show = open ?? menu.hidden;
  menu.hidden = !show;
  $("power-button").setAttribute("aria-expanded", String(show));
  if (show) menu.querySelector("button:not([hidden])").focus();
}

function renderPowerMenu() {
  const stopped = serverStatus.apps_stopped === true;
  $("power-apps-stop").hidden = stopped;
  $("power-apps-start").hidden = !stopped;
}

function renderPower() {
  const banner = $("power-banner");
  const text = $("power-banner-text");
  const busy = POWER_BUSY.includes(power.state) || power.state === "waiting";
  banner.hidden = !(busy || ["done", "failed", "off"].includes(power.state)) || power.dismissed;
  banner.className = `banner ${busy ? "busy" : power.state}`;
  if (power.state === "waiting") {
    text.textContent = power.restarting
      ? "The server is restarting. This page reconnects when it is back…"
      : "Waiting for the server…";
  } else {
    text.textContent = power.message || "";
  }
  $("power-button").disabled = busy;
}

async function loadPower() {
  try {
    const response = await fetch("/power.json", { cache: "no-store" });
    if (!response.ok) throw new Error(String(response.status));
    const next = await response.json();
    if (power.since && new Date(next.time) < power.since) return true;
    // Shown only for a while after it happened, and only once per page.
    const age = Date.now() - new Date(next.time).getTime();
    if (!POWER_BUSY.includes(next.state) && age > 10 * 60000 && !power.since) {
      power = { state: "idle" };
    } else {
      power = { ...next, since: power.since, restarting: power.restarting };
    }
    renderPower();
    return true;
  } catch {
    // nginx stops while the server restarts.
    if (power.restarting || power.state === "restart") {
      power = { state: "waiting", restarting: true, since: power.since };
      renderPower();
    }
    return false;
  }
}

function startPower(what, resume = false) {
  power = resume
    ? { ...power, restarting: what === "restart" }
    : { state: what, message: "Sent. Waiting for the server…", since: new Date(Date.now() - 2000),
        restarting: what === "restart" };
  renderPower();
  clearInterval(powerTimer);
  powerTimer = setInterval(async () => {
    const reachable = await loadPower();
    if (power.state === "off") {
      clearInterval(powerTimer);
    } else if (reachable && !POWER_BUSY.includes(power.state) && power.state !== "waiting") {
      clearInterval(powerTimer);
      await loadStatus();
      renderPowerMenu();
      checkHealth();
      if (power.restarting && power.state === "done") setTimeout(() => location.reload(), 3000);
    }
  }, 4000);
}

function greeting() {
  const hour = new Date().getHours();
  if (hour < 5) return "Good night";
  if (hour < 12) return "Good morning";
  if (hour < 18) return "Good afternoon";
  return "Good evening";
}

async function main() {
  $("greeting").textContent = greeting();
  $("address").textContent = location.host;
  $("backup-open").href = `https://${location.hostname}:6443/`;
  try { $("login-user").value = localStorage.getItem("hbox-user") || ""; } catch { /* private mode */ }
  $("check-button").addEventListener("click", checkForUpdates);
  $("update-button").addEventListener("click", () => openLogin("update"));
  $("power-button").addEventListener("click", (event) => { event.stopPropagation(); toggleMenu(); });
  for (const item of document.querySelectorAll("[data-power]")) {
    item.addEventListener("click", () => { toggleMenu(false); openLogin(item.dataset.power); });
  }
  document.addEventListener("click", (event) => {
    if (!event.target.closest(".power")) toggleMenu(false);
  });
  document.addEventListener("keydown", (event) => {
    if (event.key === "Escape" && !$("power-menu").hidden) { toggleMenu(false); $("power-button").focus(); }
  });
  $("power-banner").addEventListener("click", () => {
    if (["done", "failed"].includes(power.state)) { power.dismissed = true; renderPower(); }
  });
  $("login-cancel").addEventListener("click", () => $("login").close());
  $("login-form").addEventListener("submit", submitLogin);

  try {
    const response = await fetch("/apps.json", { cache: "no-store" });
    const config = await response.json();
    if (config.title) {
      $("title").textContent = config.title;
      document.title = config.title;
    }
    renderSections(config);
  } catch {
    $("sections").textContent = "Could not load the app list.";
  }
  checkHealth();
  await loadStatus();
  // Pick up an update that is already running (e.g. started from another device).
  await loadAction();
  if (action.state === "checking" || action.state === "updating") startPolling();
  renderPowerMenu();
  // Pick up a power action that is still running (another device, a reload).
  await loadPower();
  if (POWER_BUSY.includes(power.state)) startPower(power.state, true);
  setInterval(checkHealth, 30000);
  setInterval(loadStatus, 60000);
}

main();
