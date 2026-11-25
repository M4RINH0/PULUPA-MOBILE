# Consumir o movimento no Unity 6

O jogo roda no mesmo computador que o motion-server. O canal do jogo é `ws://127.0.0.1:8765/ws/game` e só aceita conexões do loopback. A cada pedido `{"v":1,"type":"snapshot"}` o servidor responde com `session` e a lista `players` dos slots ocupados, cada um com `player`, `player_key`, `name`, `color`, `connected`, `calibrated` e `motion`. O campo `motion` é `null` quando o celular informa `valid: false`, quando o último dado tem mais de 350 ms ou quando o jogador está desconectado. Os detalhes estão no [protocolo](../protocol/motion-protocol.md).

## Instalação

1. Use Unity 6 (6000.x) com alvo Windows, macOS ou Linux. **WebGL não é suportado**: `System.Net.WebSockets.ClientWebSocket` não funciona no navegador.
2. Instale o pacote `com.unity.nuget.newtonsoft-json`: **Window > Package Manager > + > Install package by name...** e digite `com.unity.nuget.newtonsoft-json`. Em muitos projetos Unity 6 ele já vem como dependência de outros pacotes.
3. Copie a pasta [`protocol/unity`](../protocol/unity) (`PulupaMotionClient.cs`, `PulupaPlayer.cs`, `PulupaAxes.cs`) para `Assets/Pulupa/` do projeto.
4. Crie um GameObject vazio na cena, por exemplo `PulupaMotion`, e adicione o componente **Pulupa Motion Client**. A porta padrão é 8765 e **Connect On Enable** já vem marcado.

## Comportamento do cliente

- Mantém um pedido de snapshot por vez, a cerca de 60 Hz. Sem resposta em 500 ms, fecha e reconecta.
- Reconecta sozinho com espera exponencial de 0,5 s até 5 s. Só para quando `Close()` é chamado ou o componente é desabilitado.
- Usa `Stopwatch` e é drenado em `Update()`, então continua funcionando com `Time.timeScale = 0` (menu de pausa).
- A rede roda numa tarefa em segundo plano; eventos e estado são aplicados na thread principal.
- Um snapshot com mais de 350 ms não fornece orientação. Em timeout ou queda da conexão, a lista de jogadores é esvaziada e `PlayerLeft` é emitido para cada slot.
- `ConnectionClosed(code, reason)` informa o código de fechamento. Os códigos do servidor (1000, 1008, 4000 a 4003) estão na tabela do [protocolo](../protocol/motion-protocol.md); 1006 indica falha de conexão e 4900 é local, para snapshot sem resposta.

## Identidade dos jogadores

Use `player_key` como identidade da pessoa. Ela se mantém quando o celular reconecta e muda quando outra pessoa ocupa o mesmo slot. O cliente emite:

- `PlayerJoined(slot, playerKey)` quando um slot passa a ter um ocupante ou troca de `player_key`;
- `PlayerLeft(slot, playerKey)` quando o ocupante sai, é trocado ou a conexão com o servidor cai.

Durante a janela de reconexão do celular o slot continua na lista com `Connected = false` e sem movimento, mas a `player_key` é a mesma e nenhum evento é emitido.

## Exemplo

O script abaixo cria um cubo por jogador na cor do slot e o gira com o celular.

```csharp
using System.Collections.Generic;
using Pulupa.Motion;
using UnityEngine;

public sealed class PulupaPuppets : MonoBehaviour
{
    [SerializeField] PulupaMotionClient client;
    readonly Dictionary<string, Transform> puppets = new Dictionary<string, Transform>();

    void OnEnable()
    {
        client.PlayerJoined += OnJoined;
        client.PlayerLeft += OnLeft;
    }

    void OnDisable()
    {
        client.PlayerJoined -= OnJoined;
        client.PlayerLeft -= OnLeft;
    }

    void OnJoined(int slot, string key)
    {
        var cube = GameObject.CreatePrimitive(PrimitiveType.Cube).transform;
        cube.position = new Vector3((slot - 2.5f) * 2f, 0f, 0f);
        if (client.TryGetPlayerByKey(key, out var player))
        {
            cube.name = $"Jogador {slot} - {player.Name}";
            cube.GetComponent<Renderer>().material.color = player.Color;
        }
        puppets[key] = cube;
    }

    void OnLeft(int slot, string key)
    {
        if (puppets.Remove(key, out var cube)) Destroy(cube.gameObject);
    }

    void Update()
    {
        foreach (var pair in puppets)
        {
            if (client.TryGetOrientationByKey(pair.Key, out var rotation))
                pair.Value.localRotation = rotation;
        }
    }
}
```

`TryGetOrientation(slot, out rotation)` faz o mesmo pelo número do slot. As duas retornam `false` se o jogador não está conectado, não calibrou, não tem movimento válido ou o snapshot está velho; nesse caso mantenha a última pose ou volte ao neutro. `Players` expõe nome, cor, `Connected`, `Calibrated` e `Motion` (orientação, aceleração e velocidade angular, já no referencial do Unity).

## Eixos

O protocolo usa referencial destro com X à direita, Y para cima e −Z à frente. O Unity é canhoto, com X à direita, Y para cima e +Z à frente. O cliente espelha Z e converte tudo em `PulupaAxes`:

| Grandeza | Protocolo | Unity |
| --- | --- | --- |
| Quaternion `q = [x, y, z, w]` | `(x, y, z, w)` | `(−x, −y, z, w)` |
| Aceleração | `(x, y, z)` | `(x, y, −z)` |
| Velocidade angular | `(x, y, z)` | `(−x, −y, z)` |

| Movimento do celular a partir da posição neutra | No Unity |
| --- | --- |
| Frente sobe (pitch para cima) | rotação negativa em X |
| Virar para a esquerda (yaw) | rotação negativa em Y |
| Topo inclina para a esquerda (roll) | rotação positiva em Z |

A derivação está em [`PulupaAxes.cs`](../protocol/unity/PulupaAxes.cs) e no [README do cliente](../protocol/unity/README.md). Com o celular na posição neutra, o objeto fica com `Quaternion.identity`.

## Problemas comuns

| Sintoma | Causa provável |
| --- | --- |
| `ConnectionClosed` com 1006 em sequência | Servidor fechado ou porta diferente da configurada no componente. |
| `ConnectionClosed` com 1008 | Conexão fora do loopback ou mensagem inválida; o jogo precisa rodar no mesmo PC do servidor. |
| Jogador listado, mas `TryGetOrientation` falso | O celular ainda não calibrou, está reconectando ou o app está em segundo plano. |
| Rotação espelhada ou invertida | A orientação foi usada sem `PulupaAxes` ou aplicada a um objeto com rotação pai inesperada; use `localRotation` num filho sem rotação. |
| Erro de compilação `Newtonsoft` | Instale `com.unity.nuget.newtonsoft-json`. |
| Nada conecta em WebGL | Não suportado; gere para desktop. |
