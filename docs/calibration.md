# Calibração e orientação

O Android fornece posição relativa por `TYPE_GAME_ROTATION_VECTOR`: o referencial vertical acompanha a gravidade e a direção horizontal pode derivar. A ponte converte a ordem nativa retornada por `getQuaternionFromVector` de `[w,x,y,z]` para `[x,y,z,w]`. Os eixos do aparelho correspondem à sua orientação natural. Veja as [convenções do Android](https://developer.android.com/reference/android/hardware/SensorEvent).

| Eixo | Dispositivo | Referencial de movimento |
| --- | --- | --- |
| X | Direita | X |
| Y | Topo | −Z |
| Z | Para fora da tela | Y |

Em Dart, `q` é uma rotação ativa unitária de coordenadas do dispositivo para coordenadas do mundo da fonte. O produto de Hamilton `a * b` aplica `b` primeiro. A referência é decomposta em rumo `H` (giro em torno da vertical do mundo) e inclinação `T`, com `q_reference = H * T`. A posição atual no referencial neutro é `q_relative = inverse(H) * q_current * inverse(q_reference) * H`. Na pose neutra ela é a identidade, seja qual for a forma de segurar o telefone, e +Z continua apontando para cima no mundo; assim, nos eixos do jogo, Y é sempre a vertical da gravidade e −Z é a direção para onde o jogador estava virado ao calibrar. Com o telefone deitado de tela para cima, a fórmula se reduz a `inverse(q_reference) * q_current`. O rumo de referência é a projeção no chão de (topo do aparelho − normal da tela), com o eixo X do aparelho como alternativa. A referência sobrevive a pausas do app (tela apagada, troca de app) e só é descartada ao recalibrar, limpar, mudar a taxa de captura ou trocar a fonte de orientação; neste último caso o app mostra "A fonte de orientação mudou; recalibre.". Após uma pausa, a fonte nativa pode reiniciar com outro rumo: a inclinação continua correta, mas o yaw pode ficar deslocado até recalibrar.

O painel usa a orientação relativa quando uma referência está ativa e a orientação da fonte durante a preparação. Uma câmera fixa dá perspectiva à representação 3D. Os valores de diagnóstico usam decomposição Euler Z–Y–X: roll ao redor de X, pitch ao redor de Y e yaw ao redor de Z. Para transformar para o referencial do protocolo (destro, X à direita, Y para cima e −Z à frente), use `v_game = (v.x, v.z, -v.y)` e `q_game = B * q_relative * inverse(B)`, onde `B` é uma rotação de −90° em X. O Unity é canhoto com +Z à frente; o cliente Unity converte com `q_unity = (−x, −y, z, w)`, aceleração `(x, y, −z)` e velocidade angular `(−x, −y, z)`. Veja [Unity 6](unity.md).

## Aceitação da posição neutra

1. A calibração exige acelerômetro, giroscópio e uma orientação recente, com diferença de até 120 ms entre a orientação e cada vetor auxiliar.
2. Meça por 2 s monotônicos a partir da primeira amostra útil. A janela exige 31 ou mais orientações distintas e intervalo máximo de 200 ms entre amostras completas.
3. Rejeite a janela se a velocidade angular passar de 0,18 rad/s, o módulo da aceleração desviar mais de 0,65 m/s² de `g = 9,80665 m/s²`, o vetor de aceleração variar mais de 0,75 m/s² ou a orientação se afastar mais de 4° da primeira amostra. O processador verifica cada leitura vetorial para detectar picos mesmo entre quaternions consecutivos.
4. Calcule a média incremental no arco curto dos quaternions estáveis. Uma tentativa rejeitada mantém a referência anterior se a fonte de orientação continua a mesma.
5. Suavize por SLERP com constante de tempo configurável (0 a 60 ms, padrão 18 ms) e aplique zona morta radial (0 a 3°, padrão 0,5°). A saída é contínua na borda da zona morta.

Quando a orientação nativa não está disponível ou deixa de chegar, a fusão alternativa integra a velocidade angular e corrige a inclinação pela gravidade. A correção é ponderada pela proximidade de |a| a `g` e pela velocidade de giro (total abaixo de 0,5 rad/s, nenhuma acima de 1 rad/s), e é suspensa quando a aceleração se afasta mais de 0,75 m/s² de uma média de 150 ms. Em lacunas acima de 200 ms o giroscópio não é integrado: a inclinação é realinhada à gravidade, o rumo é mantido e a calibração em andamento é interrompida. A gravidade não corrige yaw e aceleração linear pode enviesar a inclinação. Recalibre quando perceber deriva. A IMU fornece orientação e movimento instantâneo e nenhuma estimativa de posição absoluta.
