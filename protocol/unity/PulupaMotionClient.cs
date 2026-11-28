// PULUPA Motion Client para Unity 6 (6000.x).
//
// Consulta ws://127.0.0.1:<porta>/ws/game com {"v":1,"type":"snapshot"}, um pedido por vez,
// e entrega a orientação de cada jogador já convertida para o referencial do Unity
// (veja PulupaAxes.cs). Requer o pacote com.unity.nuget.newtonsoft-json.
//
// Não funciona em builds WebGL: System.Net.WebSockets.ClientWebSocket não existe no navegador.
// O canal /ws/game só aceita conexões do loopback, então o jogo roda no mesmo PC do servidor.

using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Diagnostics;
using System.Net.WebSockets;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Newtonsoft.Json.Linq;
using UnityEngine;

namespace Pulupa.Motion
{
    [DisallowMultipleComponent]
    public sealed class PulupaMotionClient : MonoBehaviour
    {
        const string Request = "{\"v\":1,\"type\":\"snapshot\"}";
        const double RequestIntervalSeconds = 1.0 / 60.0; // mesma cadência do cliente anterior (16,667 ms)
        const int RequestTimeoutMs = 500;
        const int ConnectTimeoutMs = 2000;
        const double MinBackoffSeconds = 0.5;
        const double MaxBackoffSeconds = 5.0;
        const int MaxMessageBytes = 64 * 1024;

        /// <summary>Snapshot mais velho que isto não fornece orientação (igual à expiração do servidor).</summary>
        public const double StaleSeconds = 0.35;

        /// <summary>Código local (não enviado pelo servidor) para pedido de snapshot sem resposta.</summary>
        public const int CloseCodeSnapshotTimeout = 4900;
        /// <summary>Código local para falha ao conectar ou queda sem close frame.</summary>
        public const int CloseCodeAbnormal = 1006;

        [SerializeField, Tooltip("Porta do motion-server no PC local.")]
        int port = 8765;

        [SerializeField, Tooltip("Conecta automaticamente ao habilitar o componente.")]
        bool connectOnEnable = true;

        /// <summary>Um slot passou a ter um ocupante (novo jogador, ou outra player_key no mesmo slot).</summary>
        public event Action<int, string> PlayerJoined;
        /// <summary>O ocupante saiu do slot, foi trocado, ou a conexão com o servidor caiu/expirou.</summary>
        public event Action<int, string> PlayerLeft;
        /// <summary>Snapshot aplicado; lista ordenada por slot.</summary>
        public event Action<IReadOnlyList<PulupaPlayer>> SnapshotReceived;
        public event Action Connected;
        /// <summary>Conexão encerrada: (código, motivo). Veja a tabela de códigos em protocol/motion-protocol.md.</summary>
        public event Action<int, string> ConnectionClosed;

        readonly ConcurrentQueue<ClientEvent> _events = new ConcurrentQueue<ClientEvent>();
        readonly List<PulupaPlayer> _players = new List<PulupaPlayer>();
        CancellationTokenSource _cts;
        Task _worker;
        int _generation;
        double _lastSnapshotAt = double.NegativeInfinity;

        public int Port
        {
            get => port;
            set => port = value;
        }

        public bool IsConnected { get; private set; }
        public string SessionId { get; private set; }
        /// <summary>Ocupantes do último snapshot, ordenados por slot. Vazio após timeout/fechamento.</summary>
        public IReadOnlyList<PulupaPlayer> Players => _players;
        /// <summary>True se o último snapshot tem até 350 ms.</summary>
        public bool HasFreshSnapshot => Now - _lastSnapshotAt <= StaleSeconds;

        void OnEnable()
        {
            if (connectOnEnable) Connect();
        }

        void OnDisable() => Close();

        void OnDestroy() => StopWorker();

        /// <summary>Inicia (ou reinicia) a conexão com reconexão automática.</summary>
        public void Connect()
        {
            StopWorker();
            _generation++;
            _cts = new CancellationTokenSource();
            var uri = new Uri($"ws://127.0.0.1:{port}/ws/game");
            var generation = _generation;
            var token = _cts.Token;
            _worker = Task.Run(() => RunAsync(uri, generation, token));
        }

        /// <summary>Encerra a conexão explicitamente; não reconecta até Connect() ser chamado.</summary>
        public void Close()
        {
            var wasConnected = _cts != null && IsConnected;
            StopWorker();
            _generation++; // descarta eventos ainda na fila do worker antigo
            IsConnected = false;
            ClearPlayers();
            if (wasConnected) ConnectionClosed?.Invoke(1000, "closed by client");
        }

        void StopWorker()
        {
            if (_cts == null) return;
            _cts.Cancel();
            // O worker termina sozinho (cancelamento aborta o socket) e descarta o próprio
            // ClientWebSocket; o CTS é liberado quando a tarefa acabar.
            var cts = _cts;
            var worker = _worker;
            _cts = null;
            _worker = null;
            if (worker != null)
                worker.ContinueWith(_ => cts.Dispose(), TaskScheduler.Default);
            else
                cts.Dispose();
        }

        // ---------------------------------------------------------------- consulta

        public bool TryGetPlayer(int slot, out PulupaPlayer player)
        {
            foreach (var entry in _players)
            {
                if (entry.Slot == slot)
                {
                    player = entry;
                    return true;
                }
            }
            player = null;
            return false;
        }

        public bool TryGetPlayerByKey(string playerKey, out PulupaPlayer player)
        {
            foreach (var entry in _players)
            {
                if (entry.PlayerKey == playerKey)
                {
                    player = entry;
                    return true;
                }
            }
            player = null;
            return false;
        }

        /// <summary>
        /// Orientação calibrada (relativa à posição neutra) do slot, no referencial do Unity.
        /// False se o slot está vazio, desconectado, não calibrado, sem movimento válido ou se
        /// o último snapshot tem mais de 350 ms.
        /// </summary>
        public bool TryGetOrientation(int slot, out Quaternion orientation)
        {
            TryGetPlayer(slot, out var player);
            return TryOrientation(player, out orientation);
        }

        /// <summary>Como TryGetOrientation, mas pela player_key (segue a pessoa, não o slot).</summary>
        public bool TryGetOrientationByKey(string playerKey, out Quaternion orientation)
        {
            TryGetPlayerByKey(playerKey, out var player);
            return TryOrientation(player, out orientation);
        }

        bool TryOrientation(PulupaPlayer player, out Quaternion orientation)
        {
            orientation = Quaternion.identity;
            if (player == null || !HasFreshSnapshot || !player.Connected || !player.Calibrated)
                return false;
            if (!(player.Motion is PulupaMotion motion) || !motion.Calibrated)
                return false;
            orientation = motion.Orientation;
            return true;
        }

        // ------------------------------------------------------------ thread principal

        void Update()
        {
            // Update roda mesmo com Time.timeScale = 0; os tempos usam Stopwatch.
            while (_events.TryDequeue(out var e))
            {
                if (e.Generation != _generation) continue;
                switch (e.Kind)
                {
                    case EventKind.Opened:
                        IsConnected = true;
                        Connected?.Invoke();
                        break;
                    case EventKind.Snapshot:
                        ApplySnapshot(e);
                        break;
                    case EventKind.Closed:
                        IsConnected = false;
                        ClearPlayers();
                        ConnectionClosed?.Invoke(e.CloseCode, e.CloseReason);
                        break;
                }
            }
        }

        void ApplySnapshot(ClientEvent e)
        {
            var next = new List<PulupaPlayer>(e.Players.Count);
            foreach (var raw in e.Players)
                next.Add(raw.ToPlayer());
            next.Sort((a, b) => a.Slot.CompareTo(b.Slot));

            var left = new List<PulupaPlayer>();
            foreach (var old in _players)
            {
                var match = next.Find(p => p.Slot == old.Slot);
                if (match == null || match.PlayerKey != old.PlayerKey) left.Add(old);
            }
            var joined = new List<PulupaPlayer>();
            foreach (var player in next)
            {
                var match = _players.Find(p => p.Slot == player.Slot);
                if (match == null || match.PlayerKey != player.PlayerKey) joined.Add(player);
            }

            _players.Clear();
            _players.AddRange(next);
            SessionId = e.Session;
            _lastSnapshotAt = e.ReceivedAt;

            foreach (var player in left) PlayerLeft?.Invoke(player.Slot, player.PlayerKey);
            foreach (var player in joined) PlayerJoined?.Invoke(player.Slot, player.PlayerKey);
            SnapshotReceived?.Invoke(_players);
        }

        void ClearPlayers()
        {
            _lastSnapshotAt = double.NegativeInfinity;
            if (_players.Count == 0) return;
            var removed = _players.ToArray();
            _players.Clear();
            foreach (var player in removed) PlayerLeft?.Invoke(player.Slot, player.PlayerKey);
        }

        // ------------------------------------------------------------------- worker
        // Nada abaixo toca a API do Unity: só System.*, Newtonsoft e a fila de eventos.

        static double Now => Stopwatch.GetTimestamp() / (double)Stopwatch.Frequency;

        async Task RunAsync(Uri uri, int generation, CancellationToken token)
        {
            var backoff = MinBackoffSeconds;
            var buffer = new byte[8192];
            while (!token.IsCancellationRequested)
            {
                var closeCode = CloseCodeAbnormal;
                var closeReason = "connection failed";
                var opened = false;
                using (var socket = new ClientWebSocket())
                {
                    try
                    {
                        using (var connectCts = CancellationTokenSource.CreateLinkedTokenSource(token))
                        {
                            connectCts.CancelAfter(ConnectTimeoutMs);
                            await socket.ConnectAsync(uri, connectCts.Token).ConfigureAwait(false);
                        }
                        opened = true;
                        closeReason = "connection lost";
                        _events.Enqueue(ClientEvent.Opened(generation));

                        var nextRequestAt = Now;
                        while (!token.IsCancellationRequested && socket.State == WebSocketState.Open)
                        {
                            var wait = nextRequestAt - Now;
                            if (wait > 0)
                                await Task.Delay(TimeSpan.FromSeconds(wait), token).ConfigureAwait(false);

                            var sentAt = Now;
                            nextRequestAt = sentAt + RequestIntervalSeconds;
                            await socket.SendAsync(new ArraySegment<byte>(Encoding.UTF8.GetBytes(Request)),
                                WebSocketMessageType.Text, true, token).ConfigureAwait(false);

                            ClientEvent snapshot = null;
                            using (var replyCts = CancellationTokenSource.CreateLinkedTokenSource(token))
                            {
                                replyCts.CancelAfter(RequestTimeoutMs);
                                try
                                {
                                    while (snapshot == null)
                                    {
                                        var text = await ReceiveTextAsync(socket, buffer, replyCts.Token)
                                            .ConfigureAwait(false);
                                        if (text == null) break; // close frame
                                        snapshot = ParseSnapshot(text, generation);
                                    }
                                }
                                catch (Exception timeout) when (!token.IsCancellationRequested
                                                                && replyCts.IsCancellationRequested
                                                                && (timeout is OperationCanceledException
                                                                    || timeout is WebSocketException))
                                {
                                    closeCode = CloseCodeSnapshotTimeout;
                                    closeReason = "snapshot timeout";
                                    break;
                                }
                            }
                            if (snapshot == null) break;
                            _events.Enqueue(snapshot);
                            backoff = MinBackoffSeconds;
                        }

                        if (socket.CloseStatus.HasValue)
                        {
                            closeCode = (int)socket.CloseStatus.Value;
                            closeReason = socket.CloseStatusDescription ?? string.Empty;
                        }
                    }
                    catch (OperationCanceledException) when (token.IsCancellationRequested)
                    {
                        // Close()/OnDisable: sai sem emitir evento (a thread principal já limpou).
                    }
                    catch (OperationCanceledException)
                    {
                        closeReason = opened ? "connection lost" : "connect timeout";
                    }
                    catch (Exception failure)
                    {
                        // Qualquer outra falha (rede, servidor fechou, etc.) cai na reconexão.
                        closeReason = failure.Message;
                        if (socket.CloseStatus.HasValue)
                        {
                            closeCode = (int)socket.CloseStatus.Value;
                            closeReason = socket.CloseStatusDescription ?? string.Empty;
                        }
                    }
                    finally
                    {
                        await TryCloseAsync(socket).ConfigureAwait(false);
                    }
                }

                if (token.IsCancellationRequested) break;
                // Falha de conexão sem nunca abrir também é reportada, para o jogo saber
                // que o servidor não está acessível.
                _events.Enqueue(ClientEvent.Closed(generation, closeCode, closeReason));

                try
                {
                    await Task.Delay(TimeSpan.FromSeconds(backoff), token).ConfigureAwait(false);
                }
                catch (OperationCanceledException)
                {
                    break;
                }
                backoff = Math.Min(backoff * 2, MaxBackoffSeconds);
            }
        }

        static async Task TryCloseAsync(ClientWebSocket socket)
        {
            if (socket.State != WebSocketState.Open && socket.State != WebSocketState.CloseReceived) return;
            try
            {
                using (var cts = new CancellationTokenSource(250))
                    await socket.CloseOutputAsync(WebSocketCloseStatus.NormalClosure, "bye", cts.Token)
                        .ConfigureAwait(false);
            }
            catch (Exception)
            {
                // Melhor esforço: o Dispose aborta a conexão de qualquer forma.
            }
        }

        /// <summary>Lê uma mensagem completa. Retorna null ao receber close frame.</summary>
        static async Task<string> ReceiveTextAsync(ClientWebSocket socket, byte[] buffer, CancellationToken token)
        {
            using (var message = new System.IO.MemoryStream())
            {
                while (true)
                {
                    var result = await socket.ReceiveAsync(new ArraySegment<byte>(buffer), token).ConfigureAwait(false);
                    if (result.MessageType == WebSocketMessageType.Close) return null;
                    message.Write(buffer, 0, result.Count);
                    if (message.Length > MaxMessageBytes)
                        throw new WebSocketException(WebSocketError.Faulted, "snapshot too large");
                    if (result.EndOfMessage)
                    {
                        if (result.MessageType != WebSocketMessageType.Text) return string.Empty;
                        return Encoding.UTF8.GetString(message.GetBuffer(), 0, (int)message.Length);
                    }
                }
            }
        }

        /// <summary>Retorna null se a mensagem não é um snapshot v1 (ela é ignorada).</summary>
        static ClientEvent ParseSnapshot(string text, int generation)
        {
            if (string.IsNullOrEmpty(text)) return null;
            try
            {
                return ParseSnapshotUnchecked(text, generation);
            }
            catch (Exception failure) when (failure is Newtonsoft.Json.JsonException || failure is FormatException
                                            || failure is ArgumentException || failure is InvalidCastException
                                            || failure is OverflowException)
            {
                return null; // JSON malformado ou com tipos inesperados: ignora a mensagem.
            }
        }

        static ClientEvent ParseSnapshotUnchecked(string text, int generation)
        {
            var root = JObject.Parse(text);
            if ((int?)root["v"] != 1 || (string)root["type"] != "snapshot") return null;
            if (!(root["players"] is JArray players)) return null;

            var list = new List<RawPlayer>(players.Count);
            foreach (var token in players)
            {
                if (!(token is JObject entry)) continue;
                var slot = (int?)entry["player"];
                var key = (string)entry["player_key"];
                if (slot == null || string.IsNullOrEmpty(key)) continue;
                list.Add(new RawPlayer
                {
                    Slot = slot.Value,
                    Key = key,
                    Name = (string)entry["name"] ?? string.Empty,
                    Color = (string)entry["color"] ?? string.Empty,
                    Connected = (bool?)entry["connected"] ?? false,
                    Calibrated = (bool?)entry["calibrated"] ?? false,
                    ButtonA = (bool?)(entry["buttons"] as JObject)?["a"] ?? false,
                    ButtonB = (bool?)(entry["buttons"] as JObject)?["b"] ?? false,
                    Motion = ParseMotion(entry["motion"] as JObject),
                });
            }
            return ClientEvent.Snapshot(generation, (string)root["session"], list, Now);
        }

        static RawMotion ParseMotion(JObject motion)
        {
            // motion é null no servidor quando valid:false, dados velhos ou desconectado.
            if (motion == null || (bool?)motion["valid"] != true) return null;
            var q = ReadFloats(motion["q"], 4);
            if (q == null) return null;
            var norm = q[0] * q[0] + q[1] * q[1] + q[2] * q[2] + q[3] * q[3];
            if (norm < 1e-6f) return null;
            return new RawMotion
            {
                Seq = (long?)motion["seq"] ?? 0,
                TimeUs = (long?)motion["t_us"] ?? 0,
                Q = q,
                Accel = ReadFloats(motion["accel"], 3) ?? new float[3],
                Gyro = ReadFloats(motion["gyro"], 3) ?? new float[3],
                Calibrated = (bool?)motion["calibrated"] ?? false,
            };
        }

        static float[] ReadFloats(JToken token, int count)
        {
            if (!(token is JArray array) || array.Count != count) return null;
            var values = new float[count];
            for (var i = 0; i < count; i++)
            {
                var item = array[i];
                if (item.Type != JTokenType.Float && item.Type != JTokenType.Integer) return null;
                var value = (float)item;
                if (float.IsNaN(value) || float.IsInfinity(value)) return null;
                values[i] = value;
            }
            return values;
        }

        // ---------------------------------------------------------------- tipos internos

        enum EventKind
        {
            Opened,
            Snapshot,
            Closed,
        }

        sealed class ClientEvent
        {
            public EventKind Kind;
            public int Generation;
            public string Session;
            public List<RawPlayer> Players;
            public double ReceivedAt;
            public int CloseCode;
            public string CloseReason;

            public static ClientEvent Opened(int generation) =>
                new ClientEvent { Kind = EventKind.Opened, Generation = generation };

            public static ClientEvent Snapshot(int generation, string session, List<RawPlayer> players, double at) =>
                new ClientEvent
                {
                    Kind = EventKind.Snapshot, Generation = generation, Session = session, Players = players,
                    ReceivedAt = at,
                };

            public static ClientEvent Closed(int generation, int code, string reason) =>
                new ClientEvent { Kind = EventKind.Closed, Generation = generation, CloseCode = code, CloseReason = reason };
        }

        sealed class RawMotion
        {
            public long Seq;
            public long TimeUs;
            public float[] Q;
            public float[] Accel;
            public float[] Gyro;
            public bool Calibrated;
        }

        sealed class RawPlayer
        {
            public int Slot;
            public string Key;
            public string Name;
            public string Color;
            public bool Connected;
            public bool Calibrated;
            public bool ButtonA;
            public bool ButtonB;
            public RawMotion Motion;

            // Executa na thread principal (ColorUtility e structs do Unity).
            public PulupaPlayer ToPlayer()
            {
                var player = new PulupaPlayer
                {
                    Slot = Slot,
                    PlayerKey = Key,
                    Name = Name,
                    ColorHex = Color,
                    Color = ColorUtility.TryParseHtmlString(Color, out var parsed) ? parsed : UnityEngine.Color.white,
                    Connected = Connected,
                    Calibrated = Calibrated,
                    ButtonA = ButtonA,
                    ButtonB = ButtonB,
                };
                if (Motion != null)
                {
                    var q = Motion.Q;
                    player.Motion = new PulupaMotion(
                        Motion.Seq,
                        Motion.TimeUs,
                        PulupaAxes.ToUnityRotation(q[0], q[1], q[2], q[3]),
                        PulupaAxes.ToUnityVector(Motion.Accel[0], Motion.Accel[1], Motion.Accel[2]),
                        PulupaAxes.ToUnityAngularVelocity(Motion.Gyro[0], Motion.Gyro[1], Motion.Gyro[2]),
                        Motion.Calibrated);
                }
                return player;
            }
        }
    }
}
