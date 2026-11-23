# Testes do PULUPA Controller

```powershell
cd mobile-controller
flutter pub get
flutter analyze
flutter test
```

| Fase | Verificações automatizadas |
| --- | --- |
| 1 — Fundação | Inicial, navegação, tela de pareamento em largura reduzida e escala de texto aumentada. |
| 2 — Sensores | Fluxo do simulador, frequência medida, leituras expiradas, sensores ausentes, fusão por giroscópio e troca de fonte. |
| 3 — Calibração | Produto de Hamilton, mudança de base, estabilidade, recalibração, rejeição de picos, janela incompleta, filtros e fluxo pelas telas. |
| Contratos da fase 4 | QR válido e inválido, validação de pacotes, IDs de quatro jogadores e limite de tentativas da política de reconexão. |

## Roteiro em um Android físico

1. Em **Início**, confira o estado do Wi-Fi. Compare com o Wi-Fi ativado e desativado e aguarde até quatro segundos pela atualização.
2. Em **Laboratório**, gire o aparelho em cada eixo. Verifique a resposta do modelo e compare as taxas reais em 25, 50 e 100 Hz. Em repouso, a norma da aceleração deve ficar próxima de 9,81 m/s².
3. Em **Calibrar**, segure o aparelho em um ângulo confortável e fique imóvel por dois segundos. A pose centralizada deve aparecer após a confirmação. Teste também com o celular deitado e de lado.
4. Inicie outra calibração e mexa o aparelho durante a medição. A interface deve recusar a nova referência. Pare o movimento e repita.
5. Coloque o app em segundo plano e retorne. Confira que o sinal retorna e que é possível iniciar uma nova calibração.
6. Desative a háptica em Configurações e confirme uma calibração silenciosa. Feche e reabra o app para verificar a persistência das preferências.

Repita o roteiro de calibração em um emulador com `--dart-define=PULUPA_SIMULATE=true`, usando o botão **Simular movimento** para alternar entre os estados. Valide a orientação e as taxas reais num aparelho físico.

## Medições após o pareamento

Quando o servidor estiver disponível, registre a taxa solicitada e recebida por jogador, a quantidade de pacotes e RTT médio e p95 em sessões comparáveis. Use o mesmo relógio monotônico para medir o ida e volta. A perda observável usa lacunas de sequência entre pacotes aceitos, documentando a diferença entre descartes no emissor e lacunas no receptor.
