using UnityEngine;

namespace Pulupa.Motion
{
    /// <summary>Último movimento válido de um jogador, já convertido para o referencial do Unity.</summary>
    public readonly struct PulupaMotion
    {
        public readonly long Seq;
        /// <summary>Tempo de captura no relógio do celular (µs). Não compare com o relógio do PC.</summary>
        public readonly long TimeUs;
        /// <summary>Orientação relativa à posição neutra (quando Calibrated) no referencial do Unity.</summary>
        public readonly Quaternion Orientation;
        /// <summary>Aceleração específica (com gravidade), m/s², referencial do Unity.</summary>
        public readonly Vector3 Acceleration;
        /// <summary>Velocidade angular, rad/s, referencial do Unity.</summary>
        public readonly Vector3 AngularVelocity;
        public readonly bool Calibrated;

        public PulupaMotion(long seq, long timeUs, Quaternion orientation, Vector3 acceleration,
            Vector3 angularVelocity, bool calibrated)
        {
            Seq = seq;
            TimeUs = timeUs;
            Orientation = orientation;
            Acceleration = acceleration;
            AngularVelocity = angularVelocity;
            Calibrated = calibrated;
        }
    }

    /// <summary>Estado de um slot ocupado no último snapshot.</summary>
    public sealed class PulupaPlayer
    {
        /// <summary>Slot de 1 a 4.</summary>
        public int Slot { get; internal set; }
        /// <summary>Identidade do ocupante na sessão. Mantida na reconexão; muda quando outra pessoa ocupa o slot.</summary>
        public string PlayerKey { get; internal set; }
        public string Name { get; internal set; }
        public Color Color { get; internal set; }
        /// <summary>Cor como enviada pelo servidor (ex.: "#345CFF").</summary>
        public string ColorHex { get; internal set; }
        /// <summary>False enquanto o servidor reserva o slot para reconexão.</summary>
        public bool Connected { get; internal set; }
        public bool Calibrated { get; internal set; }
        /// <summary>Nulo quando o celular informa valid:false, os dados estão velhos (&gt;350 ms) ou desconectado.</summary>
        public PulupaMotion? Motion { get; internal set; }
    }
}
