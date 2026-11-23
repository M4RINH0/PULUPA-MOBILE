# Arquitetura

| Módulo | Responsabilidade |
| --- | --- |
| `lib/app` | Ciclo de vida, navegação, preferências e atualização das telas. |
| `lib/core` | Matemática de quaternions, conversão de eixos, tema e componentes compartilhados. |
| `features/sensors` | Interface `SensorSource`, ponte Android, simulador, fusão alternativa e montagem de amostras. |
| `features/calibration` | Aceitação da posição neutra, cálculo relativo e filtragem. |
| `features/diagnostics` | Modelo em perspectiva e leitura da telemetria. |
| `features/pairing` e `features/connection` | Tela de entrada e contratos para QR, pacote, transporte e reconexão. |

No Android, `MainActivity` registra frequências de 25, 50 ou 100 Hz no `SensorManager` e publica leituras com o tempo monotônico do evento. A frequência medida usa a contagem de intervalos em janelas de aproximadamente meio segundo. O processador retém a leitura mais recente por sensor e forma uma amostra IMU quando os três sinais estão disponíveis com timestamps próximos. Leituras antigas, duplicadas ou inválidas ficam de fora.

O modelo 3D repinta até cerca de 30 vezes por segundo e as leituras numéricas atualizam até cerca de 10 vezes por segundo. A captura é liberada em segundo plano e reiniciada ao retornar. A posição neutra precisa ser refeita quando a captura reinicia ou muda de fonte de orientação. A referência e as leituras ficam em memória. As preferências locais guardam a frequência solicitada, a suavização, a zona morta e a opção de háptica.

## iOS

A UI, as preferências em memória, o simulador, a calibração e os contratos são Dart. O iOS precisa de um runner gerado em macOS e de um adaptador para `SensorSource`. O candidato em Core Motion é uma referência vertical com direção horizontal arbitrária. O adaptador deve garantir as mesmas unidades, converter o referencial de orientação para quaternion ativo dispositivo → mundo e remover a dependência da orientação da interface. O mapeamento precisa ser validado em aparelho.

A ponte atual expõe `pulupa/device` por MethodChannel e `pulupa/imu` por EventChannel. Cada evento é uma lista `[tipo, timestampUs, x, y, z]`, com um sexto elemento `w` para orientação. Os tipos nativos são 0 para aceleração, 1 para velocidade angular e 2 para orientação.

## Integração com o PC

Na fase 4, implemente a conexão WebSocket e envie cada vez a amostra mais recente, a uma frequência independente da captura. O contrato `MotionTransport` admite substituir WebSocket por UDP para movimento, mantendo o pareamento e o controle em WebSocket. Cada detector de gestos poderá receber `MotionFrame` diretamente, sem reconfigurar o serviço de sensores. O servidor de testes e o cliente Godot podem compartilhar o [protocolo](../protocol/motion-protocol.md).
