# Arquitetura

| Módulo | Responsabilidade |
| --- | --- |
| `lib/app` | Ciclo de vida, navegação, preferências e atualização das telas. |
| `lib/core` | Matemática de quaternions, conversão de eixos, tema e componentes compartilhados. |
| `features/sensors` | Interface `SensorSource`, ponte Android, simulador, fusão alternativa e montagem de amostras. |
| `features/calibration` | Aceitação da posição neutra, cálculo relativo e filtragem. |
| `features/diagnostics` | Modelo em perspectiva e leitura da telemetria. |
| `features/pairing` e `features/connection` | Leitura do QR, entrada manual, WebSocket, identificação da sessão e reconexão. |
| `features/gestures` | Detectores experimentais desacoplados da coleta. |
| `motion-server/app` | Pareamento, quatro slots independentes, servidor de diagnóstico, simulador e interface para o jogo em Unity. |

No Android, `MainActivity` registra frequências de 25, 50 ou 100 Hz no `SensorManager` numa `HandlerThread` dedicada e publica leituras com o tempo monotônico do evento. Os eventos são enfileirados e entregues ao Dart pela thread principal em lotes, com no máximo uma tarefa pendente por vez; nenhuma leitura é descartada no caminho. A interface fica travada em retrato e a tela permanece acesa enquanto o app pede (`setKeepScreenOn` em `pulupa/device`). A frequência medida usa a contagem de intervalos em janelas de aproximadamente meio segundo. O processador retém a leitura mais recente por sensor e forma uma amostra IMU quando os três sinais estão disponíveis com timestamps próximos. Leituras antigas, duplicadas ou inválidas ficam de fora.

O modelo 3D repinta até cerca de 30 vezes por segundo e as leituras numéricas atualizam até cerca de 10 vezes por segundo. A captura é liberada em segundo plano e reiniciada ao retornar. A posição neutra precisa ser refeita quando a captura reinicia ou muda de fonte de orientação. A referência e as leituras ficam em memória. As preferências locais guardam as taxas de captura e envio, a suavização, a zona morta e a opção de háptica.

## iOS

A UI, as preferências em memória, o simulador, a calibração e os contratos são Dart. O iOS precisa de um runner gerado em macOS e de um adaptador para `SensorSource`. O candidato em Core Motion é uma referência vertical com direção horizontal arbitrária. O adaptador deve garantir as mesmas unidades, converter o referencial de orientação para quaternion ativo dispositivo → mundo e remover a dependência da orientação da interface. O mapeamento precisa ser validado em aparelho.

A ponte atual expõe `pulupa/device` por MethodChannel e `pulupa/imu` por EventChannel. Cada evento é uma lista `[tipo, timestampUs, x, y, z]`, com um sexto elemento `w` para orientação. Os tipos nativos são 0 para aceleração, 1 para velocidade angular e 2 para orientação.

## Rede e integração

O aplicativo agenda o envio com taxa própria de 30, 60 ou 100 Hz. Usa a amostra IMU completa mais recente e mantém no máximo um pacote em trânsito aguardando confirmação. O servidor descarta sequências e timestamps anteriores e mantém apenas o quadro recente de cada jogador. O painel e a interface do jogo (`/ws/game`) operam no loopback do anfitrião. O [protocolo](../protocol/motion-protocol.md) define as mensagens, as tentativas de reconexão e a tabela de códigos de fechamento: 1000 normal, 1008 violação de protocolo/política, 4000 tempo sem resposta do par, 4001 conexão substituída por outra mais nova, 4002 sessão encerrada e 4003 removido pelo anfitrião. No snapshot do jogo, `motion` é `null` quando o celular informa `valid: false` ou o último dado tem mais de 350 ms.

O transporte de movimento usa WebSocket. Em testes locais, o modelo com confirmação conteve a fila em um pacote e sustentou quatro controles na frequência padrão. UDP segue como uma alternativa para avaliar com medições em vários aparelhos e condições de Wi-Fi. `MotionTransport` permite trocar o canal de movimento preservando o pareamento e o controle de sessão.

## Gestos

Os detectores recebem `MotionFrame` e sinalizam início e fim aproximados. Aceleração distante de g sinaliza um movimento brusco. O giroscópio sinaliza uma rotação rápida ou, com duração mínima maior, um possível balanço. A inclinação usa o ângulo entre a normal atual e a normal da posição neutra e pode ser detectada após calibrar. Suavização, histerese, duração e cooldown são configuráveis por detector. Os nomes e limiares são experimentais e podem se sobrepor.
