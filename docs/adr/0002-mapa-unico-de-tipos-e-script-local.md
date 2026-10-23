# ADR 0002: Filter policies de um mapa único e script do LocalStack conferido no CI

## Status

Aceito — 2026-10-23

## Contexto

Cada fila assina o tópico `oficina-events.fifo` com uma filter policy pelo
atributo `type` ([ADR 0001](0001-um-topico-fifo-e-uma-fila-por-consumidor.md)).
Uma filter policy errada descarta a mensagem sem aviso ao publicador, e a Saga
fica parada. Os serviços rodam localmente, no CI e nos testes BDD contra o
LocalStack, com a mesma topologia criada por um script de init que eles copiam
deste repositório. Se o script divergir do Terraform, os serviços passam nos
testes com um roteamento que a AWS não tem.

## Decisão

- O mapa consumidor → tipos fica em `terraform/subscribed-types.json`, com os 14 tipos do catálogo na ordem da tabela, e é a fonte única das filter policies. O `locals.tf` o lê com `jsondecode(file(...))`, e cada assinatura usa `jsonencode({ type = <tipos do consumidor> })`. Os nomes das filas derivam das chaves do mapa.
- O script `localstack/init-topology.sh` é escrito à mão com `awslocal`, com os mesmos nomes, atributos e filter policies, e um cabeçalho que aponta o mapa como fonte. Todo PR que muda a topologia altera os dois.
- Uma suíte pytest com boto3, em `tests/`, lê o mesmo mapa e confere o alvo: a filter policy de cada assinatura igual à do mapa, cada tipo chegando só à fila do consumidor, e um tipo fora do mapa sem chegar a nenhuma fila. O alvo vem só de `AWS_ENDPOINT_URL`, como nos SDKs dos serviços; tópico e filas são resolvidos pelo nome.
- O job `Routing Tests` do CI sobe o LocalStack pelo `docker-compose.yml` e roda a suíte a cada push. Contra a AWS, a suíte roda à mão, só logo depois do apply e antes dos serviços e das Lambdas.

## Alternativas consideradas

### Filter policies escritas à mão em cada assinatura

Descartado: é o erro que se quer evitar, com 14 tipos repetidos em dois lugares
sem nada que os compare.

### Mapa em HCL no `locals.tf`

A suíte o leria por `terraform console`, que exige o backend S3 inicializado,
ou seja, o Lab no ar até para conferir o LocalStack. Descartado.

### Catálogo JSON completo e script do LocalStack gerado

Um `catalog/messages.json` com `type`, `kind`, produtores e consumidor por tipo,
um gerador do script em bash com `jq` e `git diff --exit-code` no CI.
Descartado: um catálogo com campos que o Terraform não lê, um gerador e um
passo de CI para manter 14 tipos fixos, que só mudam com change revisada.

### YAML no lugar de JSON

Exigiria `yamldecode` no Terraform e `yq` ou uma biblioteca a mais no teste,
sem ganho para uma lista de tipos. Descartado.

### Verificação em bash com AWS CLI e `jq`

Laços, comparação de JSON e falha por tipo feitos à mão, difíceis de ler e de
manter. Descartado.

### TypeScript com Jest e AWS SDK v3

Mesma linguagem dos serviços, mas um projeto Node num repositório Terraform,
com `package.json`, lock, `tsconfig` e configuração do Jest, para o que o
pytest faz com dois pacotes. Descartado.

### Testcontainers para subir o LocalStack

O LocalStack subido antes pelo compose e `AWS_ENDPOINT_URL` bastam, como nos
serviços. Descartado.

### Robot Framework

Uma DSL sobre Python, com bibliotecas de AWS da comunidade, para três grupos de
teste. Descartado.

### Suíte como passo do `Terraform Validation` ou no CD contra a AWS

Um job próprio deixa o check separado e obrigatório no ruleset, no padrão dos
jobs de teste dos serviços. No CD, com serviços e Lambdas no ar, eles
consumiriam as mensagens de teste. Descartados.

### `tflocal` aplicando o próprio Terraform no LocalStack

Acrescentaria o provider apontado para o LocalStack em cada serviço, e o
script simples basta para SNS e SQS. Descartado.

## Consequências

### Positivas

- Um tipo novo é uma linha no mapa e outra no script; o Terraform gera a filter policy sem edição manual.
- Um tipo que o script assina a mais falha o `Routing Tests` apontando a assinatura e a lista divergente. Um tipo que falta no script falha o BDD e os e2e dos serviços, porque o LocalStack o descarta.
- A suíte roda sem Terraform, sem backend e sem credenciais AWS, então o CI a roda com o Lab desligado.

### Negativas / Trade-offs

- Python entra na solução, só neste repositório e só no teste.
- O script é duplicado à mão; a disciplina de alterar os dois no mesmo PR depende do CI.
- O LocalStack não aplica a policy de fila: um `aws:SourceArn` errado só aparece na suíte contra a AWS.
- As cópias do script nos serviços envelhecem até serem atualizadas.

## Revisar se

- O mapa crescer ou passar a mudar com frequência: gerar o script a partir do mapa.

## Referências

- [README — Tipos de mensagem](../../README.md#️-tipos-de-mensagem)
- [CI/CD — Job `routing-tests`](../ci-cd.md#job-routing-tests--routing-tests)
- [Runbook — Suíte de roteamento contra a AWS](../runbook.md#suíte-de-roteamento-contra-a-aws)
