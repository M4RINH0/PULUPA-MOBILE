# PULUPA Motion Protocol v1

Contrato para a fase 4. O app das fases 1–3 inclui validação local de convites, endpoint manual e pacotes de movimento. O transporte, a autenticação e o servidor serão implementados na fase 4.

## Conexão e autenticação

O endereço previsto é `ws://<IPv4-local>:8765/ws/controller`. Use o IP da interface Wi-Fi ou Ethernet acessível aos jogadores. O cliente v1 aceita IPv4 em `10/8`, `172.16/12`, `192.168/16` e `169.254/16`, com porta entre 1 e 65535. Use `ws` exclusivamente numa rede local confiável. Mensagens e tokens transitam em texto claro nesse transporte.

O QR é um URI neste formato, com ordem livre para os parâmetros.

```text
pulupa://pair?v=1&host=192.168.1.20&port=8765&session=dev_session_1234567890&ticket=temporary_ticket_1234567890_test
```

Cada campo é obrigatório e ocorre uma vez. `session` usa de 22 a 64 caracteres base64url sem padding e `ticket` de 32 a 128. O QR tem limite de 512 caracteres. O aplicativo valida esquema, autoridade, versão, endereço, porta e formato dos campos antes de conectar. Digitação manual usa IP e porta e solicita um código temporário exibido pelo servidor.

Use mensagens WebSocket de texto com um objeto JSON UTF-8 por mensagem. Todo objeto traz `v: 1` e `type`. A primeira mensagem do cliente é `hello`, com `name` (1 a 32 caracteres visíveis) e uma credencial.

| Campo de `hello` | Significado |
| --- | --- |
| `session` e `ticket` | Convite QR. |
| `code` | Fluxo manual. O servidor resolve a sessão ativa. |
| `session` e `resume` | Reconexão de jogador já autorizado. |

O servidor responde com `welcome` contendo `session`, `player`, `name`, `color` e `resume`. `player` é um inteiro de 1 a 4, vinculado à conexão no servidor. As cores por slot são `#345CFF`, `#FF55A5`, `#FFD928` e `#8B5CF6`. Em reconexão autenticada, preserve o slot, estado e sequência do cliente e renove o token. Use `error` com `code` para rejeições, incluindo `invalid_invite`, `session_expired` e `session_full`.

Emita convites aleatórios de curta duração e limite o uso de códigos manuais por origem e sessão. Expire a sessão e seus tokens, mantenha credenciais em memória e exclua-as de logs. O servidor valida se as mensagens do cliente correspondem ao jogador autenticado na conexão. Restrinja a interface de gerenciamento ao PC anfitrião.

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

O transporte retém uma amostra pendente por jogador. Se uma mais recente chegar enquanto o envio estiver ocupado, ela substitui a anterior. Ao testar um canal UDP, mantenha a autoridade da sessão em WebSocket e associe cada datagrama autenticado ao mesmo jogador e sequência.

## Controle e métricas

- `calibration` leva `calibrated` do cliente ao servidor. O servidor devolve `calibration_ack` com o estado reconhecido.
- `ping` e `pong` carregam o mesmo `id`. O iniciador mede RTT no próprio relógio monotônico e calcula média, percentil 95 e variação entre amostras. Conte pacotes e lacunas de sequência separadamente por jogador.
- `haptic` usa uma lista fixa de eventos, começando por `confirm`. `disconnect` encerra o jogador de forma explícita. Valide cada comando por tipo e ignore tipos desconhecidos.
- Em desconexão transitória, aguarde 0,5 s, 1 s, 2 s, 4 s e 8 s nas cinco tentativas de reconexão. Cancele em desconexão explícita, expiração ou credencial recusada.
