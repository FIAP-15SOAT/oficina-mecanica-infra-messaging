# 📘 Runbook — Mensageria AWS

Procedimentos de operação da topologia `oficina-events.fifo`: subida e
derrubada, suíte de roteamento contra a AWS e contra o LocalStack, diagnóstico
com o ambiente em uso e redrive de DLQ.

## Índice

- [Subida e derrubada](#subida-e-derrubada)
- [Suíte de roteamento contra a AWS](#suíte-de-roteamento-contra-a-aws)
- [Suíte de roteamento contra o LocalStack](#suíte-de-roteamento-contra-o-localstack)
- [Diagnóstico com o ambiente em uso](#diagnóstico-com-o-ambiente-em-uso)
- [Redrive de uma DLQ](#redrive-de-uma-dlq)
- [Falhas conhecidas](#falhas-conhecidas)

Os comandos AWS supõem as credenciais AWS configuradas e `us-east-1`:

```bash
# Região padrão dos comandos abaixo
export AWS_DEFAULT_REGION=us-east-1
```

## Subida e derrubada

Ordem de subida da solução:

1. `oficina-mecanica-infra-base` (rede).
2. Em paralelo: `oficina-mecanica-infra-k8s`, **este repositório** e os repositórios de dados.
3. **Suíte de roteamento contra a AWS** (seção seguinte), antes de qualquer serviço ou Lambda.
4. CD dos quatro serviços.
5. API Gateway, depois as Lambdas e, por último, o monitoramento.

A derrubada segue a ordem inversa: os serviços e a Lambda de notificação saem
antes da topologia, porque leem as filas. Não há workflow de destroy:

```bash
# Na pasta terraform/, com o backend inicializado: revisar o que será removido
terraform plan -destroy

# Remover tópico, filas, DLQs, policies e assinaturas
terraform destroy
```

O destroy apaga as mensagens que estiverem nas filas e nas DLQs. Confira antes
que as DLQs estão vazias ou que as mensagens podem ser perdidas.

## Suíte de roteamento contra a AWS

Rode **só logo depois do apply deste repositório e antes de subir os serviços e
as Lambdas**. Com consumidores no ar, eles leriam as mensagens de teste, e a
suíte poderia receber uma mensagem real. Com o ambiente em uso, diagnostique
só por leitura ([próxima seção](#diagnóstico-com-o-ambiente-em-uso)).

```bash
# Na raiz do repositório: ambiente Python com boto3 e pytest
python -m venv .venv
. .venv/bin/activate   # no Windows (Git Bash): . .venv/Scripts/activate
pip install -r tests/requirements.txt

# Sem AWS_ENDPOINT_URL, o boto3 usa a AWS com as credenciais configuradas
unset AWS_ENDPOINT_URL

# Rodar a suíte: 4 assinaturas, 14 tipos e 1 tipo fora do mapa
pytest tests -v
```

Resultado esperado: `19 passed`. A suíte resolve tópico e filas pelo nome,
publica uma mensagem de cada tipo duas vezes com o mesmo `MessageDeduplicationId`
e apaga só as mensagens que ela mesma publicou. Na AWS, ela também prova a
policy das filas: uma entrega recusada pelo `aws:SourceArn` aparece como tipo
que não chegou à fila do consumidor.

Uma filter policy criada ou alterada leva até 15 minutos para valer na AWS
(consistência eventual do SNS). Se a suíte falhar logo depois de um apply que
mudou o mapa, espere esse tempo e rode de novo antes de investigar.

## Suíte de roteamento contra o LocalStack

```bash
# Subir o LocalStack com localstack/init-topology.sh montado em ready.d
docker compose up -d

# Apontar o boto3 para o LocalStack, com credenciais fictícias
export AWS_ENDPOINT_URL=http://localhost:4566
export AWS_ACCESS_KEY_ID=test
export AWS_SECRET_ACCESS_KEY=test

# Rodar a suíte com o ambiente Python da seção anterior ativo
pytest tests -v

# Derrubar o LocalStack
docker compose down
```

Se o script não estiver montado em `ready.d`, todos os testes dão erro com
`LocalStack init completed without running any script`. Se o script de init
falhar, o erro é `LocalStack init scripts failed: init-topology.sh: ERROR`, e o
log do container mostra o comando que falhou:

```bash
# Últimas linhas do LocalStack, com a saída do script de init
docker compose logs localstack --tail 50
```

## Diagnóstico com o ambiente em uso

Com serviços ou Lambdas no ar, use só leitura: não publique, não receba e não
apague mensagens.

```bash
# ARN do tópico e as 4 assinaturas
TOPIC_ARN=$(aws sns list-topics --query "Topics[?ends_with(TopicArn, ':oficina-events.fifo')].TopicArn" --output text)
aws sns list-subscriptions-by-topic --topic-arn "$TOPIC_ARN" --query 'Subscriptions[].[Endpoint,SubscriptionArn]' --output table

# Filter policy e raw delivery de uma assinatura
aws sns get-subscription-attributes --subscription-arn <SubscriptionArn> \
  --query 'Attributes.[FilterPolicy,RawMessageDelivery]'

# Atributos de uma fila: SSE, retenção, redrive, policy e mensagens pendentes
QUEUE_URL=$(aws sqs get-queue-url --queue-name work-order.fifo --query QueueUrl --output text)
aws sqs get-queue-attributes --queue-url "$QUEUE_URL" --attribute-names All

# Mensagens paradas numa DLQ
DLQ_URL=$(aws sqs get-queue-url --queue-name work-order-dlq.fifo --query QueueUrl --output text)
aws sqs get-queue-attributes --queue-url "$DLQ_URL" \
  --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible
```

## Redrive de uma DLQ

Uma mensagem vai para a DLQ depois de 5 recebimentos sem ser apagada. Antes do
redrive, corrija a causa (banco fora, bug, payload inesperado) e confira nos
logs do consumidor que ele voltou a processar. Não há redrive automático.

```bash
# ARN da DLQ do consumidor (troque work-order pelo consumidor afetado)
DLQ_URL=$(aws sqs get-queue-url --queue-name work-order-dlq.fifo --query QueueUrl --output text)
DLQ_ARN=$(aws sqs get-queue-attributes --queue-url "$DLQ_URL" --attribute-names QueueArn --query Attributes.QueueArn --output text)

# Devolver as mensagens à fila de origem (sem --destination-arn, a origem registrada)
aws sqs start-message-move-task --source-arn "$DLQ_ARN"

# Acompanhar até Status COMPLETED e conferir ApproximateNumberOfMessagesMoved
aws sqs list-message-move-tasks --source-arn "$DLQ_ARN"

# Conferir a DLQ vazia
aws sqs get-queue-attributes --queue-url "$DLQ_URL" --attribute-names ApproximateNumberOfMessages
```

Espere pelo menos 5 minutos desde a publicação da mensagem antes do redrive. A
mensagem volta com o mesmo `MessageDeduplicationId`, e dentro da janela de
deduplicação de 5 minutos a fila FIFO pode descartá-la como duplicata: a tarefa
termina `COMPLETED`, a DLQ fica vazia e a mensagem não chega à fila de origem.

Só uma tarefa de movimentação fica ativa por fila. As mensagens devolvidas se
misturam às novas e voltam a ter 5 recebimentos antes de cair de novo na DLQ;
os consumidores são idempotentes, então reprocessar é seguro.

## Falhas conhecidas

| Sintoma | Causa provável | O que fazer |
| --- | --- | --- |
| A Saga para e nenhuma mensagem chega a uma fila; o publicador não mostra erro | Filter policy da assinatura sem o tipo, ou tipo publicado com nome diferente do catálogo | Conferir a filter policy com `get-subscription-attributes` contra `terraform/subscribed-types.json`; corrigir o mapa e o script no mesmo PR e aplicar |
| `Routing Tests` falha em `test_subscription_filters_exactly_mapped_types[<consumidor>]` | Script do LocalStack divergente do mapa (tipo a mais ou a menos na assinatura) | Igualar a filter policy do consumidor em `localstack/init-topology.sh` à lista do mapa |
| `Routing Tests` falha em `test_type_reaches_only_its_consumer_queue[...]` com duas filas | O script assina o tipo em mais de um consumidor | Remover o tipo da assinatura errada no script |
| Mensagens de uma OS param de ser entregues por alguns minutos | Mensagem com falha segura as seguintes do mesmo `MessageGroupId` até ir para a DLQ (até cerca de 2,5 min: 30 s × 5) | Esperar a DLQ; conferir a mensagem na DLQ, corrigir a causa e fazer o [redrive](#redrive-de-uma-dlq) |
| Na AWS, nenhum tipo chega a uma fila, mas a assinatura está certa | Policy da fila sem o `aws:SourceArn` do tópico | Conferir `Policy` em `get-queue-attributes`; reaplicar o Terraform |

Voltar ao [README](../README.md).
