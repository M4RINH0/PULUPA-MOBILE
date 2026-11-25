# Cliente Unity 6 do PULUPA

Arquivos para copiar em `Assets/` de um projeto Unity 6 (6000.x):

| Arquivo | Conteúdo |
| --- | --- |
| `PulupaMotionClient.cs` | Componente que consulta `ws://127.0.0.1:<porta>/ws/game`, reconecta sozinho e expõe jogadores, eventos e orientação. |
| `PulupaPlayer.cs` | `PulupaPlayer` (slot, `player_key`, nome, cor, estado) e `PulupaMotion` (orientação, aceleração e velocidade angular). |
| `PulupaAxes.cs` | Conversão do referencial do protocolo para o do Unity. |

Dependência: `com.unity.nuget.newtonsoft-json` (Package Manager > + > Install package by name). Não funciona em WebGL. O guia completo, com exemplo, está em [docs/unity.md](../../docs/unity.md) e as mensagens em [motion-protocol.md](../motion-protocol.md).

## Conversão de eixos

O protocolo usa referencial destro: X à direita, Y para cima, −Z à frente (+Z aponta para quem olha). O quaternion chega como `[x, y, z, w]`, rotação ativa unitária. O Unity é canhoto: X à direita, Y para cima, +Z à frente.

Um ponto passa de um referencial ao outro espelhando Z, `M = diag(1, 1, −1)`:

```text
p_unity = M · p = (x, y, −z)
R_unity = M · R · M
```

Como `det(M) = −1`, o eixo de uma rotação é um pseudovetor e vira `−M·a = (−aₓ, −a_y, a_z)`, com o mesmo ângulo na fórmula matricial que o Unity usa. Logo:

```text
q_unity     = (−x, −y, z, w)
accel_unity = (x, y, −z)       // vetor polar
gyro_unity  = (−x, −y, z)      // pseudovetor, consistente com q
```

Conferência rápida: uma rotação só em Z não mexe no plano XY e o espelho não a altera (`z` mantém o sinal); uma rotação `θ` em X vira `−θ` em X (`x` troca de sinal).

| Movimento físico | Protocolo | Unity |
| --- | --- | --- |
| Frente sobe (pitch para cima) | +θ em X | −θ em X (`eulerAngles.x ≈ 360 − θ`) |
| Virar à esquerda (yaw) | +θ em Y | −θ em Y |
| Topo inclina à esquerda (roll) | +θ em Z | +θ em Z |
| Posição neutra | identidade | `Quaternion.identity` |
