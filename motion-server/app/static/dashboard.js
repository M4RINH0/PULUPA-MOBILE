const byId = (id) => document.getElementById(id);
const put = (root, selector, value) => { root.querySelector(selector).textContent = value; };
const cards = new Map();
const number = new Intl.NumberFormat("pt-BR", { maximumFractionDigits: 1 });
const format = (value, unit) => value == null ? "—" : `${number.format(value)} ${unit}`.trim();
const ERROR_SECONDS = 5;
const FETCH_TIMEOUT_MS = 1500;
let inviteKey = "";
let actionError = { text: "", at: 0 };
let latestRequest = 0;

function phoneMatrix(q) {
  // Convert game axes to the phone's physical axes and then to CSS Y-down.
  const [gx, gy, gz, w] = q;
  const x = -gx, y = -gz, z = -gy;
  const xx = 2*x*x, yy = 2*y*y, zz = 2*z*z;
  const xy = 2*x*y, xz = 2*x*z, yz = 2*y*z;
  const wx = 2*w*x, wy = 2*w*y, wz = 2*w*z;
  return `matrix3d(${[
    1-yy-zz, xy+wz, xz-wy, 0,
    xy-wz, 1-xx-zz, yz+wx, 0,
    xz+wy, yz-wx, 1-xx-yy, 0,
    0, 0, 0, 1,
  ].join(",")})`;
}

async function fetchWithTimeout(path, options = {}) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), FETCH_TIMEOUT_MS);
  try {
    return await fetch(path, { ...options, signal: controller.signal });
  } finally {
    clearTimeout(timer);
  }
}

async function action(path, { missingIsDone = false } = {}) {
  try {
    const response = await fetchWithTimeout(path, { method: "POST" });
    // Desconectar um jogador que já saiu (404) tem o mesmo efeito esperado.
    if (!response.ok && !(missingIsDone && response.status === 404)) throw new Error("action");
    actionError = { text: "", at: 0 };
  } catch {
    actionError = { text: "Não foi possível completar a ação.", at: Date.now() };
  }
  refresh();
}

function currentActionError() {
  if (actionError.text && Date.now() - actionError.at > ERROR_SECONDS * 1000) {
    actionError = { text: "", at: 0 };
  }
  return actionError.text;
}

function renderPlayer(player) {
  let card = cards.get(player.player);
  if (!card) {
    card = byId("player-card").content.firstElementChild.cloneNode(true);
    card.querySelector(".haptic").addEventListener("click", () => action(`/api/players/${player.player}/haptic`));
    card.querySelector(".disconnect").addEventListener("click", () => (
      action(`/api/players/${player.player}/disconnect`, { missingIsDone: true })
    ));
    cards.set(player.player, card);
  }
  card.classList.remove("stale");
  card.style.setProperty("--player", player.color);
  put(card, "h3", `${player.player} · ${player.name}`);
  put(card, ".device", player.device);
  put(card, ".state", player.connected ? "Conectado" : "Reconectando");
  put(card, ".signal", !player.motion
    ? "Aguardando amostras"
    : player.calibrated ? "Calibrado" : "Posição neutra pendente");
  put(card, ".hz", format(player.hz, "Hz"));
  put(card, ".packets", format(player.packets, ""));
  put(card, ".rtt", format(player.rtt_mean_ms, "ms"));
  put(card, ".p95", format(player.rtt_p95_ms, "ms"));
  put(card, ".jitter", format(player.jitter_ms, "ms"));
  put(card, ".loss", format(player.loss == null ? null : player.loss * 100, "%"));
  card.querySelector(".phone").style.transform = player.motion ? phoneMatrix(player.motion.q) : "none";
  card.querySelector(".haptic").disabled = !player.connected;
  if (!card.isConnected) byId("players").appendChild(card);
}

function render(data) {
  const key = data.active ? `${data.session}:${data.code}` : "";
  const qr = byId("qr");
  qr.hidden = !data.active;
  if (key && key !== inviteKey) qr.src = `/api/qr?version=${Date.now()}`;
  inviteKey = key;
  byId("host").textContent = data.host;
  byId("port").textContent = data.port;
  byId("code").textContent = data.active ? data.code : "—";
  byId("invite-status").textContent = data.active
    ? `Convite renova em ${data.invite_seconds} s.`
    : "Sessão expirada. Inicie uma nova sessão.";
  byId("count").textContent = `${data.players.filter((p) => p.connected).length} / 4`;
  const present = new Set(data.players.map((p) => p.player));
  for (const [id, card] of cards) {
    if (!present.has(id)) {
      card.remove();
      cards.delete(id);
    }
  }
  for (const player of data.players) renderPlayer(player);
}

function renderUnavailable() {
  // Sem resposta do servidor: nada exibido pode ser considerado atual.
  const qr = byId("qr");
  qr.hidden = true;
  qr.removeAttribute("src");
  inviteKey = "";
  byId("code").textContent = "—";
  byId("invite-status").textContent = "Sem conexão com o servidor.";
  for (const card of cards.values()) {
    card.classList.add("stale");
    put(card, ".state", "Sem dados");
    put(card, ".signal", "Sem dados");
    card.querySelector(".phone").style.transform = "none";
    card.querySelector(".haptic").disabled = true;
  }
}

async function refresh() {
  const request = ++latestRequest;
  const error = byId("error");
  let text;
  try {
    const response = await fetchWithTimeout("/api/state", { cache: "no-store" });
    if (!response.ok) throw new Error("state");
    const data = await response.json();
    if (request !== latestRequest) return;
    render(data);
    text = currentActionError();
  } catch {
    if (request !== latestRequest) return;
    renderUnavailable();
    text = "Servidor indisponível. Tentando novamente…";
  }
  error.textContent = text;
  error.hidden = !text;
}

async function update() {
  await refresh();
  setTimeout(update, 100);
}

byId("new-session").addEventListener("click", () => {
  if (window.confirm("Iniciar outra sessão desconecta os jogadores atuais. Continuar?")) {
    action("/api/session");
  }
});
update();
