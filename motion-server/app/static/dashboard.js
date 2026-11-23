const byId = (id) => document.getElementById(id);
const put = (root, selector, value) => { root.querySelector(selector).textContent = value; };
const cards = new Map();
const number = new Intl.NumberFormat("pt-BR", { maximumFractionDigits: 1 });
const format = (value, unit) => value == null ? "—" : `${number.format(value)} ${unit}`.trim();
let inviteKey = "";
let actionError = "";

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

async function action(path) {
  try {
    const response = await fetch(path, { method: "POST" });
    if (!response.ok) throw new Error("action");
    actionError = "";
  } catch {
    actionError = "Não foi possível completar a ação.";
  }
}

function renderPlayer(player) {
  let card = cards.get(player.player);
  if (!card) {
    card = byId("player-card").content.firstElementChild.cloneNode(true);
    card.querySelector(".haptic").addEventListener("click", () => action(`/api/players/${player.player}/haptic`));
    card.querySelector(".disconnect").addEventListener("click", () => action(`/api/players/${player.player}/disconnect`));
    cards.set(player.player, card);
  }
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

async function update() {
  const error = byId("error");
  try {
    const response = await fetch("/api/state", { cache: "no-store" });
    if (!response.ok) throw new Error("state");
    render(await response.json());
    error.textContent = actionError;
  } catch {
    error.textContent = "Servidor indisponível. Tentando novamente…";
  }
  error.hidden = !error.textContent;
  setTimeout(update, 100);
}

byId("new-session").addEventListener("click", () => {
  if (window.confirm("Iniciar outra sessão desconecta os jogadores atuais. Continuar?")) {
    action("/api/session");
  }
});
update();
