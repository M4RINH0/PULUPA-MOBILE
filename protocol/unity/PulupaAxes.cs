using UnityEngine;

namespace Pulupa.Motion
{
    /// <summary>
    /// Conversão do referencial do protocolo PULUPA para o referencial do Unity.
    ///
    /// Protocolo (motion-protocol.md): referencial DESTRO, X à direita, Y para cima e
    /// −Z à frente (+Z aponta para o observador). `q` chega como [x, y, z, w], rotação
    /// ativa unitária, e `accel`/`gyro` como [x, y, z].
    ///
    /// Unity: referencial CANHOTO, X à direita, Y para cima e +Z à frente.
    ///
    /// Um ponto do protocolo vira ponto do Unity espelhando Z: M = diag(1, 1, −1), ou
    /// seja p_unity = (x, y, −z). O "à frente" (−Z) do protocolo vira +Z no Unity e
    /// direita/cima continuam iguais.
    ///
    /// Rotação: R_unity = M · R · M. Como det(M) = −1, o eixo de rotação (pseudovetor)
    /// transforma como −M·a = (−ax, −ay, az) e o ângulo é preservado pela fórmula
    /// matricial (que o Unity usa sem mudança). Portanto
    ///     q_unity = (−x, −y, z, w).
    /// Conferência: rotação em Z (só z) não afeta o plano XY, e M·Rz·M = Rz (z mantém
    /// sinal); rotação em X: M·Rx(θ)·M = Rx(−θ) (x troca de sinal).
    ///
    /// Vetores polares (aceleração): (x, y, −z).
    /// Velocidade angular (pseudovetor): (−x, −y, z), consistente com o quaternion.
    ///
    /// Tabela de sanidade (mesmo movimento físico nos dois referenciais):
    ///   Nariz para cima (frente sobe): protocolo +θ em X  → Unity rotação NEGATIVA em X
    ///                                  (eulerAngles.x ≈ 360 − θ).
    ///   Virar à esquerda (yaw):        protocolo +θ em Y  → Unity rotação NEGATIVA em Y.
    ///   Topo inclina à esquerda (roll):protocolo +θ em Z  → Unity rotação POSITIVA em Z.
    /// </summary>
    public static class PulupaAxes
    {
        /// <summary>Quaternion [x, y, z, w] do protocolo → Quaternion do Unity (normalizado).</summary>
        public static Quaternion ToUnityRotation(float x, float y, float z, float w)
        {
            var q = new Quaternion(-x, -y, z, w);
            q.Normalize();
            return q;
        }

        /// <summary>Vetor polar (aceleração, posição) do protocolo → Unity.</summary>
        public static Vector3 ToUnityVector(float x, float y, float z) => new Vector3(x, y, -z);

        /// <summary>Velocidade angular (pseudovetor) do protocolo → Unity.</summary>
        public static Vector3 ToUnityAngularVelocity(float x, float y, float z) => new Vector3(-x, -y, z);
    }
}
