# PULUPA Motion Protocol v1

Este protocolo liga o PULUPA Controller ao servidor local. O painel do PC mostra a sessão em `http://127.0.0.1:8765`.

## Conexão e autenticação

O endereço previsto é `ws://<IPv4-local>:8765/ws/controller`. Use o IP da interface Wi-Fi ou Ethernet acessível aos jogadores. O cliente v1 aceita IPv4 em `10/8`, `172.16/12`, `192.168/16` e `169.254/16`, com porta entre 1 e 65535. Use `ws` exclusivamente numa rede local confiável. Mensagens e tokens transitam em texto claro nesse transporte.

O QR é um URI neste formato, com ordem livre para os parâmetros.

```text
pulupa://pair?v=1&host=192.168.1.20&port=8765&session=dev_session_1234567890&ticket=temporary_ticket_1234567890_test
```

Cada campo é obrigatório e ocorre uma vez. `session` usa de 22 a 64 caracteres base64url sem padding e `ticket` de 32 a 128. O QR tem limite de 512 caracteres. O aplicativo valida esquema, autoridade, versão, endereço, porta e formato dos campos antes de conectar. Digitação manual usa IP e porta e solicita um código temporário exibido pelo servidor.

Use mensagens WebSocket de texto de até 1.024 bytes com um objeto JSON UTF-8 por mensagem. Todo objeto traz `v: 1` e `type`. A primeira mensagem do cliente é `hello`, com `name` (1 a 32 caracteres visíveis), rótulo opcional `device` (até 64) e uma credencial.

| Campo de `hello` | Significado |
| --- | --- |
| `session` e `ticket` | Convite QR. |
| `code` | Fluxo manual. O servidor resolve a sessão ativa. |
| `session` e `resume` | Reconexão de jogador já autorizado. |

O servidor responde com `welcome` contendo `session`, `player`, `player_key`, `name`, `color` e `resume`. `player` é o slot inteiro de 1 a 4, vinculado à conexão no servidor. `player_key` identifica unicamente o ocupante na sessão e permanece na reconexão. É gerada outra chave ao reutilizar o slot para um jogador novo. As cores por slot são `#345CFF`, `#FF55A5`, `#FFD928` e `#8B5CF6`. A reconexão autenticada preserva o slot, estado e sequência do cliente e renova o token. Rejeições incluem `error` com `code`, como `invalid_invite`, `session_expired` e `session_full`.

O ticket e o código manual de seis dígitos expiram em dois minutos. Uma sessão dura até duas horas. Após perda de conexão, o servidor reserva o slot por até um minuto para o token de reconexão. O servidor limita tentativas inválidas por origem, mantém credenciais em memória e valida se as mensagens do cliente correspondem ao jogador autenticado na conexão. O painel e o canal Godot são acessíveis pelo loopback.

## Movimento

Exemplo conceitual de dado calibrado. Cada pacote contém apenas os campos abaixo e ocupa até 1.024 bytes em UTF-8.

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

O referencial é destro, com X à direita, Y para cima e −Z à frente na convenção do Godot. A mudança de base e a ordem de multiplicação estão em [Calibração e orientação](../docs/calibration.md). A origem de `t_us` varia entre dispositivos. Use sequência e timestamps por jogador para ordenar leituras. Nunca subtraia o timestamp do servidor do timestamp do celular para estimar atraso.

Valide inteiros no intervalo `0..2^53−1` para sequência e timestamp, vetores finitos, desvio de norma quadrada do quaternion de até 0,02 em relação a 1, e magnitudes de até 500 m/s² e 100 rad/s. Normalize o quaternion aceito. Descarte pacotes repetidos ou anteriores ao mais recente para o mesmo jogador. Limite o tamanho das mensagens e a taxa por jogador. Comece com envio configurável em 60 Hz e limite de entrada em 120 pacotes de movimento por segundo com tolerância curta a rajadas.

O servidor devolve `motion_ack` com `seq`, `packets` e `missing`. O cliente mantém somente uma transmissão de movimento sem confirmação e escolhe a amostra mais recente disponível após o ACK. O servidor descarta amostras mais antigas e responde com ACK à sequência repetida para liberar o cliente. Um eventual canal UDP mantém a sessão em WebSocket e deve autenticar e associar cada datagrama ao mesmo jogador e sequência.

## Controle e métricas

- `calibration` leva `calibrated` do cliente ao servidor. O servidor devolve `calibration_ack` com o estado reconhecido.
- `ping` e `pong` carregam o mesmo `id`. O iniciador mede RTT no próprio relógio monotônico e calcula média, percentil 95 e variação entre amostras. A razão `missing/(packets+missing)` mede lacunas de sequência observadas, sem estimar a perda física de pacotes TCP.
- `haptic` aceita o evento `confirm`. `disconnect` encerra o jogador de forma explícita e libera o slot.
- Em desconexão transitória, aguarde 0,5 s, 1 s, 2 s, 4 s e 8 s nas cinco tentativas de reconexão. Cancele em desconexão explícita, expiração ou credencial recusada.

## Consulta pelo Godot

Em `ws://127.0.0.1:8765/ws/game`, envie `{"v":1,"type":"snapshot"}` e aguarde a resposta antes de consultar de novo. A resposta contém `v`, `type: "snapshot"`, `session` e a lista `players`. Cada elemento inclui `player`, `player_key`, `name`, `color`, `connected`, `calibrated` e o último objeto `motion` válido. Esse objeto expira em 350 ms. Veja a [integração em Godot 4](../docs/godot.md).
