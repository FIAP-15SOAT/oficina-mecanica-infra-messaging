# ADR 0001: Um tópico SNS FIFO e uma fila SQS FIFO por consumidor

## Status

Aceito — 2026-10-23

## Contexto

A solução tem quatro serviços (Identity, Work Order, Billing e Inventory) e uma
Lambda de envio de e-mail que trocam comandos e eventos de forma assíncrona. O
Work Order orquestra as Sagas de orçamento e pagamento, e a ordem das mensagens
de uma mesma OS importa: `billing.payment.requested` precisa chegar antes de
`billing.payment.approved`, e `billing.quote.sent` antes de
`billing.quote.approved`. Os serviços gravam a mensagem num outbox na mesma
transação da mudança de negócio e um relay a publica depois, então a entrega é
pelo menos uma vez e os consumidores são idempotentes.

O catálogo tem 14 tipos: 5 comandos e 9 eventos, consumidos por `work-order`
(9), `billing` (2), `inventory` (2) e `notification` (1).

## Decisão

- Um único tópico SNS FIFO, `oficina-events.fifo`, sem deduplicação por conteúdo, no qual todo serviço publica comandos e eventos com `MessageGroupId` igual ao `workOrderId` (ou ao `messageId`, quando não há OS) e `MessageDeduplicationId` igual ao `messageId`.
- Uma fila SQS FIFO por consumidor (`work-order.fifo`, `billing.fifo`, `inventory.fifo` e `notification.fifo`), que assina o tópico com raw message delivery e filter policy pelo atributo `type`.
- Uma DLQ FIFO por fila, `<consumidor>-dlq.fifo`, com `maxReceiveCount` 5 e `RedriveAllowPolicy` só da fila de origem. Redrive manual, por `StartMessageMoveTask`.
- Visibility timeout de 30 s, long polling de 20 s e retenção de 4 dias nas filas e 14 dias nas DLQs; 1 dia na `notification.fifo` e na DLQ dela, que carregam dados de e-mail.
- Criptografia SSE gerenciada pelo SQS nas 8 filas; o tópico, que não guarda mensagem, fica sem KMS.
- Policy de cada fila de consumo que só aceita `sqs:SendMessage` do SNS com `aws:SourceArn` igual ao ARN do tópico. Sem role de IAM para publicadores: pods e Lambdas usam a `LabRole`.
- Nomes fixos em `locals.tf`, não em variáveis, porque são contrato lido por todos os serviços.

## Alternativas consideradas

### Um tópico por serviço publicador e filas de comando separadas

Cada serviço teria o próprio tópico de eventos, e os comandos iriam para filas
de comando dedicadas. Descartado porque multiplica tópicos, assinaturas e
policies sem ganho: o consumidor continua lendo uma fila só, e o publicador
teria dois caminhos de publicação (tópico para evento, fila para comando).

### Filas standard com `aggregateVersion` para ordenar

Filas standard têm vazão maior, e a ordem seria reconstruída no consumidor por
uma versão do agregado. Descartado porque passa para cada handler a lógica de
reordenar e de esperar mensagens fora de ordem, que a FIFO já resolve por
`MessageGroupId`, e a vazão da solução cabe com folga no limite da FIFO.

### Comandos publicados direto na fila do consumidor

O publicador mandaria os comandos com `SendMessage` na fila do destino.
Descartado porque cria um segundo caminho de publicação no outbox e acopla o
publicador ao nome da fila do consumidor; pelo tópico, mover um tipo de fila é
só mudar a filter policy.

### Backoff por `ChangeMessageVisibility`

O consumidor aumentaria o visibility timeout a cada falha. Descartado porque
todo handler é rápido, e 5 recebimentos com 30 s levam a mensagem à DLQ em
cerca de 2,5 min, prazo aceito para segurar as mensagens seguintes da mesma OS.

## Consequências

### Positivas

- Um caminho só de publicação: o relay do outbox publica tudo no mesmo tópico.
- Ordem por OS garantida pelo SQS FIFO, sem lógica de reordenação nos serviços.
- Duplicatas da mesma mensagem descartadas por 5 minutos pela deduplicação FIFO.
- Uma mensagem com falha persistente vai para a DLQ e não bloqueia a OS para sempre.

### Negativas / Trade-offs

- Uma mensagem com falha segura as seguintes da mesma OS por até cerca de 2,5 min, até ir para a DLQ.
- A vazão da FIFO é menor que a de filas standard.
- Filter policy errada descarta a mensagem sem aviso ao publicador; a suíte de roteamento e o BDD dos serviços conferem cada tipo.

## Revisar se

- A vazão da FIFO limitar: usar `fifo_throughput_limit = "perMessageGroupId"` e `deduplication_scope = "messageGroup"`.
- A política de segurança exigir criptografia no tópico: `kms_master_key_id = "alias/aws/sns"`, conferido no Lab antes para os 4 publicadores.
- O redrive manual virar rotina: avaliar redrive automático.

## Referências

- [README — Recursos provisionados](../../README.md#️-recursos-provisionados)
- [Runbook — Redrive de uma DLQ](../runbook.md#redrive-de-uma-dlq)
- [ADR 0002 — Mapa único de tipos e script do LocalStack](0002-mapa-unico-de-tipos-e-script-local.md)
