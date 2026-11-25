# Testes do PULUPA Controller

```powershell
cd mobile-controller
flutter pub get
flutter analyze
flutter test
```

| Fase | Verificações automatizadas |
| --- | --- |
| 1 — Fundação | Inicial, navegação, campos de pareamento em largura reduzida e escala de texto aumentada. |
| 2 — Sensores | Fluxo do simulador, frequência medida, leituras expiradas, sensores ausentes, fusão por giroscópio e troca de fonte. |
| 3 — Calibração | Produto de Hamilton, mudança de base, estabilidade, recalibração, rejeição de picos, janela incompleta, filtros e fluxo pelas telas. |
| 4 — Conexão | QR válido e inválido, pacote, pareamento, stream WebSocket, háptica, confirmação de calibração e reconexão com o mesmo jogador. |
| 5 — Multiplayer | Quatro jogadores, isolamento de amostras, sessão lotada, expiração, desconexão e reuso de slots. |
| 6 — Otimização | Controle de frequência, substituição da amostra pendente, gestos e benchmark com quatro emissores. |
| 7 — Jogo (Unity) | Endpoint local de snapshot, expiração do movimento em 350 ms e identidade dos fluxos por `player_key`. |

Execute também no servidor.

```powershell
cd motion-server
.\.venv\Scripts\python.exe -m pip install -r requirements-dev.txt
.\.venv\Scripts\python.exe -m unittest discover -s tests -v
.\.venv\Scripts\python.exe -m app.simulator --local-server --players 4 --seconds 12
```

## Roteiro em um Android físico

1. Em **Início**, confira o estado do Wi-Fi. Compare com o Wi-Fi ativado e desativado e com o roteador do próprio celular (hotspot) ligado, e aguarde até quatro segundos pela atualização.
2. Em **Laboratório**, gire o aparelho em cada eixo. Confirme que a interface continua em retrato e que a tela não apaga durante a captura. Verifique a resposta do modelo e compare as taxas reais em 25, 50 e 100 Hz. Em repouso, a norma da aceleração deve ficar próxima de 9,81 m/s².
3. Em **Calibrar**, segure o aparelho como vai jogar (em pé ou deitado de lado pelas laterais) e mantenha-o firme por 1,5 s; tremor normal da mão não deve cancelar a medição. Depois, no **Laboratório**, confira: virar o corpo para a direita aumenta **Giro**, abaixar o lado direito aumenta **Balanço** e inclinar o topo para longe aumenta **Frente/trás**, sem misturar eixos, tanto em pé quanto de lado.
4. Inicie outra calibração e mexa o aparelho durante a medição. A medição deve recomeçar com "Segure firme" e só falhar se o movimento continuar por 10 s. Pare o movimento e confirme que ela conclui.
5. Coloque o app em segundo plano e retorne. Confira que o sinal retorna e que é possível iniciar uma nova calibração.
6. Com o controle conectado a um PC, bloqueie a tela pelo botão de energia por 30 s. O painel deve continuar mostrando Hz e a pose; a notificação "PULUPA conectado" deve aparecer. Desbloqueie e confira que nada foi recalibrado.
7. Ainda conectado, aperte voltar: o app deve ir para o fundo, sem desconectar. Depois remova o app dos recentes e reabra em menos de 3 minutos: ele deve voltar sozinho à mesma vaga (mesmo número e cor no painel). Recalibre, porque a referência neutra não sobrevive ao fechamento.
8. Desative a háptica em Configurações e confirme uma calibração silenciosa. Feche e reabra o app para verificar a persistência das preferências.

Repita o roteiro de calibração em um emulador com `--dart-define=PULUPA_SIMULATE=true`, usando o botão **Simular movimento** para alternar entre os estados. Valide a orientação e as taxas reais num aparelho físico.

## Verificação pela rede local

1. Abra o painel no PC e pareie o primeiro celular por QR. Pareie um segundo digitando IP, porta e código do painel.
2. Calibre os dois em posições confortáveis. Mova um de cada vez e confirme que só o modelo correspondente muda.
3. Na tela **Laboratório**, compare as métricas com as do painel no PC. Alterne 30, 60 e 100 Hz nas configurações e registre a frequência real, média e p95 de RTT.
4. Interrompa e restabeleça o Wi-Fi num aparelho dentro da janela de reconexão. Verifique se ele recupera o mesmo jogador (mesma `player_key`) e se o outro mantém o fluxo. Se a conexão antiga ainda estiver aberta quando a nova chegar, o servidor a encerra com o código 4001. Os códigos de fechamento estão no [protocolo](../protocol/motion-protocol.md).
5. Com o jogo Unity aberto, pare e reinicie o servidor. O cliente deve reconectar sozinho (espera de 0,5 s até 5 s) e emitir `PlayerLeft`/`PlayerJoined` conforme os slots somem e voltam.
6. Use **Testar toque** e **Desconectar** na ficha de um jogador. Verifique se só esse aparelho recebe a ação (o removido recebe o código 4003).

## Medição em loopback

Uma execução de 12 s com quatro emissores a 60 Hz neste PC recebeu 716 confirmações por jogador, cerca de 59,6 Hz. O RTT médio de movimento ficou entre 1,11 e 1,70 ms por jogador e o p95 entre 1,56 e 2,42 ms. O RTT foi medido no emissor desde o início do envio até receber `motion_ack`. As medições cobrem o servidor e clientes simulados no mesmo computador. Valores reais dependem dos aparelhos, do Wi-Fi e da taxa escolhida.

As telas usam o RTT de `ping`/`pong`. O jitter é a média das diferenças absolutas entre RTTs sucessivos. Lacunas entre sequências aceitas medem ausências no fluxo de aplicação. A captura mantém a última amostra e atribui a sequência na hora do envio, por isso descartar amostras antes de enviar não conta como lacuna.
