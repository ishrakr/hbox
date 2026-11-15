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

// A small line chart of the last hour; one or more series of numbers.
function drawChart(svg, series, max) {
  const width = 120;
  const height = 32;
  svg.replaceChildren();
  const count = Math.max(...series.map((s) => s.values.length));
  if (count < 2) return;
  const top = Math.max(max || 0, ...series.flatMap((s) => s.values), 1e-9);
  for (const { values, className } of series) {
    const points = values.map((value, index) => {
      const x = (index / (count - 1)) * width;
      const y = height - 1 - (Math.max(0, value) / top) * (height - 2);
      return `${x.toFixed(1)},${y.toFixed(1)}`;
    });
    const line = document.createElementNS("http://www.w3.org/2000/svg", "polyline");
    line.setAttribute("points", points.join(" "));
    line.setAttribute("class", className);
    line.setAttribute("vector-effect", "non-scaling-stroke");
    svg.append(line);
  }
}

function renderUsage(system) {
  const history = Array.isArray(system.history) ? system.history : [];
  const latest = history[history.length - 1];
  const minutes = history.length > 1
    ? Math.round((latest.t - history[0].t) / 60)
    : 0;
  const span = minutes > 1 ? `last ${minutes} min` : "";

  if (latest) {
    const cpu = Math.round(latest.cpu);
    $("cpu-text").textContent = `${cpu}%`;
    $("cpu-bar").style.width = `${cpu}%`;
    const meter = $("cpu-bar").parentElement;
    meter.setAttribute("aria-valuenow", String(cpu));
    meter.classList.toggle("warn", cpu >= 70 && cpu < 90);
    meter.classList.toggle("full", cpu >= 90);
    $("net-rx").textContent = formatRate(latest.rx);
    $("net-tx").textContent = formatRate(latest.tx);
  } else {
    $("cpu-text").textContent = "Measuring…";
    $("net-rx").textContent = "–";
    $("net-tx").textContent = "–";
  }

  const cpuValues = history.map((s) => s.cpu);
  const average = cpuValues.length ? Math.round(cpuValues.reduce((a, b) => a + b, 0) / cpuValues.length) : null;
  const cores = system.cpus ? `${system.cpus} core${system.cpus > 1 ? "s" : ""}` : "";
  const load = typeof system.load === "number" ? `load ${system.load.toFixed(2)}` : "";
  $("cpu-note").textContent = [
    average !== null && span ? `Average ${average}% (${span})` : "", cores, load,
  ].filter(Boolean).join(" · ");
  drawChart($("cpu-chart"), [{ values: cpuValues, className: "line" }], 100);

  const rx = history.map((s) => s.rx);
  const tx = history.map((s) => s.tx);
  const totals = history.length > 1
    ? history.slice(1).reduce((sum, s, i) => {
      const seconds = s.t - history[i].t;
      return { rx: sum.rx + s.rx * seconds, tx: sum.tx + s.tx * seconds };
    }, { rx: 0, tx: 0 })
    : null;
  $("net-note").textContent = totals && span
    ? `${formatBytes(totals.rx)} down · ${formatBytes(totals.tx)} up (${span})`
    : "";
  const memory = system.memory || {};
  if (memory.total > 0) {
    const percent = Math.round((memory.used / memory.total) * 100);
    $("mem-text").textContent = `${percent}% used`;
    $("mem-bar").style.width = `${percent}%`;
    const meter = $("mem-bar").parentElement;
    meter.setAttribute("aria-valuenow", String(percent));
    meter.classList.toggle("warn", percent >= 80 && percent < 90);
    meter.classList.toggle("full", percent >= 90);
    const swap = memory.swap_used > 64e6 ? `${formatBytes(memory.swap_used)} swap in use` : "";
    $("mem-note").textContent = [
      `${formatBytes(memory.used)} of ${formatBytes(memory.total)}`, swap,
    ].filter(Boolean).join(" · ");
  }
  drawChart($("mem-chart"), [{ values: history.map((s) => s.mem ?? null).filter((v) => v !== null), className: "line" }], 100);

  drawChart($("net-chart"), [
    { values: rx, className: "line" },
    { values: tx, className: "line secondary" },
  ]);
}

// One line per checked drive in the Storage tile; problems first.
function renderDiskHealth(disks) {
  const list = $("disk-health");
  const known = disks.filter((d) => ["ok", "warning", "failing"].includes(d.status));
  list.replaceChildren();
  list.hidden = known.length === 0;
  const order = { failing: 0, warning: 1, ok: 2 };
  known.sort((a, b) => order[a.status] - order[b.status]);
  for (const disk of known) {
    const item = element("li", `disk ${disk.status}`);
    const name = disk.role === "backup" ? "Backup disk" : "Server disk";
    const state = disk.status === "ok" ? "healthy" : disk.status === "warning" ? "showing wear" : "failing";
    const temp = typeof disk.temperature === "number" ? ` · ${disk.temperature} °C` : "";
    item.append(element("span", "disk-dot"), element("span", "", `${name} ${state}${temp}`));
    const problems = Array.isArray(disk.problems) ? disk.problems.join(", ") : "";
    item.title = [disk.model, problems].filter(Boolean).join(": ");
    if (disk.status !== "ok") {
      item.append(element("span", "disk-advice", `${problems}. Run sudo hbox doctor.`));
    }
    list.append(item);
  }
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

  if (status.disk && status.disk.total > 0) {
    const percent = Math.round((status.disk.used / status.disk.total) * 100);
    $("disk-text").textContent = `${percent}% used`;
    $("disk-free").textContent =
      `${formatBytes(status.disk.total - status.disk.used)} free of ${formatBytes(status.disk.total)}`;
    $("disk-bar").style.width = `${percent}%`;
    const meter = $("disk-bar").parentElement;
    meter.setAttribute("aria-valuenow", String(percent));
    meter.classList.toggle("warn", percent >= 80 && percent < 90);
    meter.classList.toggle("full", percent >= 90);
  }

  renderUsage(status.system || {});
  renderDiskHealth(Array.isArray(status.disks) ? status.disks : []);

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

function openLogin() {
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
    const response = await request("/api/update", { Authorization: `Basic ${auth}` });
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
    action = { state: "updating", since: new Date(Date.now() - 2000) };
    renderProgress();
    startPolling();
  } catch (error) {
    $("login-error").textContent = `Could not reach the server (${error.message}).`;
    $("login-error").hidden = false;
  }
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
  $("update-button").addEventListener("click", openLogin);
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
  setInterval(checkHealth, 30000);
  setInterval(loadStatus, 60000);
}

main();
