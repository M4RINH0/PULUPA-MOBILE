# Consumir o movimento no Godot 4

O jogo pode rodar no mesmo computador que o servidor de testes. Use o endpoint `ws://127.0.0.1:8765/ws/game`. O servidor disponibiliza um snapshot dos quatro slots em resposta a `{"v":1,"type":"snapshot"}`. Envie o próximo pedido após receber o anterior. O payload define `session` e uma lista `players` com identificador, nome, cor, status de conexão, indicador de calibração e `motion`. O campo `motion` é nulo quando o sensor para de atualizar ou o jogador desconecta. [Documentação do WebSocketPeer](https://docs.godotengine.org/en/stable/classes/class_websocketpeer.html)

Para integrar sem implementar o polling outra vez, copie [pulupa_motion_client.gd](../protocol/godot/pulupa_motion_client.gd) para o projeto Godot e anexe a um nó. Chame `connect_local()` após iniciar o servidor. O sinal `snapshot_received` entrega a lista atual e `orientation_for(id)` retorna `Quaternion` calibrado ou `null`.

```gdscript
@onready var controllers: PulupaMotionClient = $PulupaMotionClient
@onready var preview: Node3D = $Preview

func _ready() -> void:
    controllers.connect_local()

func _process(_delta: float) -> void:
    var orientation: Variant = controllers.orientation_for(1)
    if orientation is Quaternion:
        preview.quaternion = orientation
```

Use `session` e `player_key` como identidade do fluxo. Uma nova pessoa que ocupa um slot recebe outra chave e reinicia a sequência. Uma reconexão mantém a chave. Quaternions vêm no referencial Godot de X à direita, Y para cima e −Z à frente. Vetores de aceleração e velocidade angular usam eixos locais do aparelho remapeados para essa base. Veja o [protocolo](../protocol/motion-protocol.md) para unidades e convenções.
