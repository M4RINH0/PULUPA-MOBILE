# PULUPA Motion Protocol v1

Este protocolo liga o PULUPA Controller ao servidor local. O painel do PC mostra a sessão em `http://127.0.0.1:8765`. O jogo em Unity 6 consulta o servidor pelo loopback.

## Conexão e autenticação

O endereço previsto é `ws://<IPv4-local>:8765/ws/controller`. Use o IP da interface Wi-Fi ou Ethernet acessível aos jogadores. O cliente v1 aceita IPv4 em `10/8`, `172.16/12`, `192.168/16` e `169.254/16`, com porta entre 1 e 65535.

O QR é um URI neste formato, com ordem livre para os parâmetros.

```text
pulupa://pair?v=1&host=192.168.1.20&port=8765&session=dev_session_1234567890&ticket=temporary_ticket_1234567890_test
```

Cada campo é obrigatório e ocorre uma vez. `session` usa de 22 a 64 caracteres base64url sem padding e `ticket` de 32 a 128. O QR tem limite de 512 caracteres. O aplicativo valida esquema, autoridade, versão, endereço, porta e formato dos campos antes de conectar. Digitação manual usa IP e porta e solicita um código temporário de seis dígitos exibido pelo servidor.

Use mensagens WebSocket de texto de até 1.024 bytes com um objeto JSON UTF-8 por mensagem. Todo objeto traz `v: 1` e `type`. A primeira mensagem do cliente é `hello`, enviada em até 3 s, com `name` (veja [Nomes](#nomes)), rótulo opcional `device` (mesma regra, até 64 pontos de código; inválido vira "Dispositivo móvel"), `attempt` opcional e uma credencial.

| Campo de `hello` | Significado |
| --- | --- |
| `session` e `ticket` | Convite QR. |
| `code` | Fluxo manual. O servidor resolve a sessão ativa. |
| `session` e `resume` | Reconexão de jogador já autorizado. |
| `attempt` (opcional) | Identificador da tentativa de primeiro pareamento: 16 a 64 caracteres `[A-Za-z0-9_-]`. Só tem efeito junto com `ticket` ou `code`; é ignorado com `resume`. Fora do formato, o servidor responde `invalid_message`. |

O servidor responde com `welcome` contendo `session`, `player`, `player_key`, `name`, `color` e `resume`. `player` é o slot inteiro de 1 a 4, vinculado à conexão no servidor. `name` é o nome já normalizado. `player_key` identifica unicamente o ocupante na sessão e permanece na reconexão. É gerada outra chave ao reutilizar o slot para um jogador novo. As cores por slot são `#345CFF`, `#FF55A5`, `#FFD928` e `#8B5CF6`. Rejeições enviam `error` com `code` e encerram com 1008 (veja [Códigos de encerramento e erro](#códigos-de-encerramento-e-erro)).

### Reconexão e substituição

- **Assumir a conexão.** Um `hello` com `resume` válido é aceito mesmo que o servidor ainda considere o jogador conectado (por exemplo, o Wi-Fi caiu e o socket antigo ainda não expirou). O servidor passa o jogador para o novo socket, renova o token de reconexão e encerra o socket antigo com **4001**, sem afetar o jogador. O slot e o estado continuam; a verificação de ordem de `seq` e `t_us` recomeça no novo socket, porque um app reaberto reinicia a numeração. O código `resume_pending` está obsoleto e não é mais emitido.
- **Carência do token.** Ao renovar, o servidor guarda o token apresentado como token anterior. Um `hello` com o token atual ou o anterior é aceito, o que cobre um `welcome` perdido no caminho. O token anterior é descartado assim que o servidor recebe no novo socket qualquer mensagem válida (`motion`, `ping`, `pong` ou `calibration`), prova de que o `welcome` chegou. Por isso o cliente deve sempre guardar o `resume` do último `welcome` recebido, de preferência em armazenamento persistente: o app oficial salva `host`, `port`, `session` e `resume` e, se for reaberto dentro da reserva de 180 s, reconecta sozinho na mesma vaga.
- **Primeiro pareamento idempotente.** O cliente gera um `attempt` aleatório por intenção de pareamento (uma leitura de QR ou um código digitado) e o repete nas novas tentativas desse mesmo pareamento enquanto não receber `welcome`. Se um `hello` com `ticket` ou `code` válido traz o `attempt` de um jogador existente, o servidor devolve esse jogador (assumindo a conexão como acima e renovando `resume`) em vez de ocupar outro slot. Depois do `welcome`, use `resume`. `hello` sem `attempt` continua válido.
- Se o envio do `welcome` falhar para um jogador recém-criado, o servidor o remove e libera o slot.

O ticket e o código manual expiram em dois minutos. Uma sessão dura até duas horas. Após perda de conexão, o servidor reserva o slot por até um minuto para o token de reconexão. O servidor mantém credenciais em memória e valida se as mensagens do cliente correspondem ao jogador autenticado na conexão. O painel e o canal do jogo são acessíveis somente pelo loopback.

Limites contra abuso:

- Por origem (IP), 8 credenciais inválidas em 60 s bloqueiam novos `hello` dessa origem com `retry_later`.
- Por convite, 20 credenciais inválidas no total (somando todas as origens) renovam ticket e código; o QR e o código antigos deixam de valer.
- No máximo 16 conexões aguardando `hello` ao mesmo tempo, e 4 por origem. Excedentes recebem `retry_later` e 1008.

### Nomes

`name` é obrigatório em todo `hello`. A regra, aplicada por servidor e aplicativo:

1. Todo caractere da categoria Unicode `Zs` (por exemplo U+00A0, U+202F, U+3000) vira U+0020. Espaços internos não são colapsados.
2. Apara U+0020 das bordas. Somente U+0020 é aparado; uma tabulação na borda continua no texto e é rejeitada.
3. Rejeita se restar caractere das categorias `Cc`, `Cs`, `Co`, `Zl` ou `Zp`, ou um controle bidirecional U+202A–U+202E ou U+2066–U+2069.
4. Exige de 1 a 32 pontos de código (não unidades UTF-16 nem grafemas).

Caracteres `Cf` como ZWJ (U+200D), LRM (U+200E) e tags de emoji são permitidos, assim como emoji. Nome ausente, não textual ou fora da regra recebe `invalid_name` e 1008. Pontos ainda não atribuídos (`Cn`) são aceitos de propósito: a tabela Unicode do Python do PC pode ser mais antiga que a do celular, e recusá-los bloquearia emoji recentes.

## Movimento

Exemplo conceitual de dado calibrado. Cada pacote contém exatamente os campos abaixo e ocupa até 1.024 bytes em UTF-8.

```json
{"v":1,"type":"motion","session":"dev_session_1234567890","player":2,"seq":37,"t_us":52687000,"q":[0,0,0,1],"accel":[0,9.81,0],"gyro":[0,0,0],"calibrated":true,"valid":true}
```

| Campo | Convenção |
| --- | --- |
| `seq` | Inteiro monotônico por jogador e sessão, a partir de zero. Mantenha na reconexão. |
| `t_us` | Tempo monotônico de captura da orientação em microssegundos, com origem no aparelho. |
| `q` | Quaternion ativo unitário `[x,y,z,w]`. Orientação relativa à posição neutra quando calibrado. |
| `accel` | Aceleração específica com efeito da gravidade em m/s², em eixos locais do dispositivo remapeados. |
| `gyro` | Velocidade angular em rad/s, nos mesmos eixos locais remapeados. |
| `calibrated` | Indica se uma referência validada está ativa. |
| `valid` | Indica se as leituras podem ser consumidas. Ignore o movimento quando falso. |

O referencial é destro, com X à direita, Y para cima e −Z à frente. A mudança de base e a ordem de multiplicação estão em [Calibração e orientação](../docs/calibration.md). A origem de `t_us` varia entre dispositivos. Use sequência e timestamps por jogador para ordenar leituras. Nunca subtraia o timestamp do servidor do timestamp do celular para estimar atraso.

> **Convenção dos eixos no fio.** Referencial destro, Y para cima, X à direita, −Z à frente (+Z aponta para quem olha a tela). `q` é uma rotação ativa na ordem `[x, y, z, w]` (parte escalar por último). `accel` e `gyro` usam os mesmos eixos. Esta convenção não muda. Consumidores em Unity (canhoto, Y para cima, +Z à frente) precisam converter: veja [unity/README.md](unity/README.md).

Valide inteiros no intervalo `0..2^53−1` para sequência e timestamp (números com parte fracionária ou escritos como `1.0` são recusados), vetores finitos, desvio de norma quadrada do quaternion de até 0,02 em relação a 1, e magnitudes de até 500 m/s² e 100 rad/s. Normalize o quaternion aceito. Limite o tamanho das mensagens e a taxa por jogador. Comece com envio configurável em 60 Hz e limite de entrada em 120 pacotes de movimento por segundo com tolerância curta a rajadas. Casos de fronteira estão em [fixtures/motion.json](fixtures/motion.json), compartilhado pelos testes do servidor e do aplicativo: `session` e `player` do arquivo são a identidade autenticada esperada.

### Amostra sem dados (`valid: false`)

Quando não há leitura utilizável (sensor parado, permissão negada, fusão ainda sem convergir), o celular continua enviando pacotes com `valid: false`, `q: [0,0,0,1]`, `accel: [0,0,0]` e `gyro: [0,0,0]`, mantendo `seq`, `t_us` e `calibrated`. O servidor valida e confirma esses pacotes normalmente e guarda o estado, mas o `motion` do snapshot fica `null` enquanto a última amostra for inválida. Assim o jogo distingue "conectado sem dados" de "desconectado".

### Confirmação

O servidor responde a cada `motion` com `motion_ack`:

| Campo | Significado |
| --- | --- |
| `seq` | `seq` do pacote confirmado. |
| `accepted` | `true` se o pacote passou na validação; `false` se foi recusado. |
| `code` | Presente só quando `accepted` é `false`, com o código do erro (normalmente `invalid_motion`). |
| `packets`, `missing` | Contadores do jogador: amostras aplicadas e lacunas de sequência observadas. |

Pacotes repetidos ou mais antigos que o último aplicado recebem `accepted: true`: são reconhecidos, mas não aplicados. Um pacote recusado sem `seq` inteiro recebe `error` com `code` no lugar de `motion_ack`. O cliente mantém somente uma transmissão de movimento sem confirmação e escolhe a amostra mais recente disponível após o ACK. Um eventual canal UDP mantém a sessão em WebSocket e deve autenticar e associar cada datagrama ao mesmo jogador e sequência.

Erros de protocolo depois do `welcome` (JSON inválido, tipo desconhecido, movimento recusado) são tolerados até 3 **consecutivos**: o terceiro seguido gera `error` e 1008. Qualquer mensagem válida processada zera a contagem.

## Controle e métricas

- `calibration` leva `calibrated` do cliente ao servidor. O servidor devolve `calibration_ack` com o estado reconhecido.
- `ping` e `pong` carregam o mesmo `id`. O servidor envia `ping` a cada 2 s e encerra com 4000 se não receber o `pong` correspondente em 8 s. O iniciador mede RTT no próprio relógio monotônico e calcula média, percentil 95 e variação entre amostras. A razão `missing/(packets+missing)` mede lacunas de sequência observadas, sem estimar a perda física de pacotes TCP.
- `haptic` aceita o evento `confirm`. `disconnect` encerra o jogador de forma explícita e libera o slot.
- Em desconexão transitória, aguarde 0,5 s, 1 s, 2 s, 4 s e 8 s nas cinco tentativas de reconexão. Cancele em desconexão explícita, expiração, credencial recusada ou códigos de encerramento que pedem isso na tabela abaixo.

## Códigos de encerramento e erro

| Código WebSocket | Motivo | O cliente deve reconectar? |
| --- | --- | --- |
| 1000 | Encerramento normal após `disconnect`. | Não. |
| 1008 | Violação de protocolo ou política, precedida por `error`. Conexões com cabeçalho `Origin` ou de fora da rede local são recusadas já no handshake, sem `error`. | Conforme o `code` do `error` anterior. |
| 4000 | Par sem resposta: nenhum `pong` em 8 s ou nenhum `hello` em 3 s. | Sim, com `resume` (ou o mesmo `attempt`). |
| 4001 | Conexão substituída por outra mais nova do mesmo jogador. | Não. A conexão mais nova é a válida. |
| 4002 | Sessão encerrada ou substituída (nova sessão no painel, expiração ou slot liberado). | Não com `resume`; é preciso parear de novo. |
| 4003 | Jogador removido pelo anfitrião no painel. | Não. |
| 1006 e outros | Queda de transporte. | Sim, com `resume`. |

| `code` de `error` | Quando | Tentar de novo? |
| --- | --- | --- |
| `session_expired` | Sessão expirada. | Não. Peça uma nova sessão no PC. |
| `retry_later` | Muitas credenciais inválidas da origem, ou muitas conexões aguardando `hello`. | Sim, após aguardar (o bloqueio por origem dura até 60 s). |
| `invalid_invite` | Ticket, código ou `resume` inválido ou vencido. | Não com a mesma credencial. Leia o QR ou digite o código atual. |
| `invalid_name` | `name` ausente ou fora da [regra](#nomes). | Não sem corrigir o nome. |
| `invalid_message` | JSON, envelope, campos ou `attempt` inválidos. No `hello` é fatal; depois do `welcome` é tolerado até 3 erros consecutivos. | Não sem corrigir o cliente. |
| `session_full` | Quatro jogadores já ocupam a sessão. | Não automaticamente. |
| `rate_limit` | Taxa de mensagens acima do limite. | Sim, com `resume`, reduzindo a taxa. |
| `invalid_motion` | Pacote de movimento recusado. Vem em `motion_ack` (`accepted: false`) ou, sem `seq` inteiro, em `error`. | Não é fatal; corrija o pacote. |
| `resume_pending` | **Obsoleto.** Não é mais emitido (o servidor assume a conexão). | Clientes antigos tratavam como transitório. |

## Temporização

| Parâmetro | Valor | Lado |
| --- | --- | --- |
| Prazo para o `hello` | 3 s | Servidor |
| Intervalo de `ping` | 2 s | Servidor |
| Par sem resposta (sem `pong`) | 8 s, encerra com 4000 | Servidor |
| Reserva do slot para `resume` | 180 s | Servidor |
| Validade do ticket e do código | 120 s, ou até 20 falhas no convite | Servidor |
| Duração da sessão | 2 h | Servidor |
| Janela do bloqueio por origem | 60 s (8 falhas) | Servidor |
| Frescor do `motion` no snapshot | 350 ms | Servidor |
| Espera por `motion_ack` antes de reenviar | 4 s (valor atual do aplicativo) | Cliente |
| Intervalos de reconexão | 0,5 s, 1 s, 2 s, 4 s, 8 s | Cliente |
| Ociosidade do canal do jogo | 10 s sem `snapshot` encerra com 1008 | Servidor |

## Modelo de ameaça

O transporte é `ws://` em texto claro. Mensagens, ticket, código e token de reconexão podem ser lidos por qualquer um na mesma rede. Use o servidor somente numa rede local confiável (casa, laboratório) e nunca o exponha à internet. O servidor escuta em `0.0.0.0` para os celulares alcançarem o PC, mas só aceita conexões de controle vindas de IPv4 privado ou loopback, sem cabeçalho `Origin`. O painel, as ações administrativas e o canal do jogo exigem loopback. Os limites de tentativas e de conexões pendentes dificultam adivinhar o código de seis dígitos, mas não protegem contra quem já observa o tráfego.

## Consulta pelo jogo (Unity 6)

Em `ws://127.0.0.1:8765/ws/game`, envie `{"v":1,"type":"snapshot"}` e aguarde a resposta antes de consultar de novo. A resposta contém `v`, `type: "snapshot"`, `session` e a lista `players`. Cada elemento inclui `player`, `player_key`, `name`, `color`, `connected`, `calibrated` e o último objeto `motion` válido, ou `null`. Esse objeto expira em 350 ms. Os valores chegam na convenção do fio descrita em [Movimento](#movimento); o cliente Unity em [unity/PulupaMotionClient.cs](unity/PulupaMotionClient.cs) converte para os eixos do Unity. Veja a [integração em Unity 6](../docs/unity.md) e [unity/README.md](unity/README.md).
