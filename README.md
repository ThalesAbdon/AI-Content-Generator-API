# AI Content Generator API

> Desafio Técnico Backend Sênior — API que gera conteúdos via IA (simulada) de forma **assíncrona**, **resiliente a falhas** e **segura sob concorrência**, com processamento em background via fila.

Node.js + TypeScript · Fastify · PostgreSQL + Prisma · Redis + BullMQ · MinIO/S3 · Zod · Vitest

---

## Índice

- [Contexto e objetivo](#contexto-e-objetivo)
- [Stack técnica](#stack-técnica)
- [Arquitetura](#arquitetura)
- [Como rodar](#como-rodar)
  - [Opção 1 — Docker (recomendado)](#opção-1--docker-recomendado)
  - [Opção 2 — Local com infra em Docker](#opção-2--local-com-infra-em-docker)
- [Variáveis de ambiente](#variáveis-de-ambiente)
- [Documentação da API (Swagger)](#documentação-da-api-swagger)
- [Endpoints](#endpoints)
- [Fluxo de geração de conteúdo](#fluxo-de-geração-de-conteúdo)
- [Decisões arquiteturais: concorrência e resiliência](#decisões-arquiteturais-concorrência-e-resiliência)
- [Testes](#testes)
- [Estrutura de pastas](#estrutura-de-pastas)
- [Scripts disponíveis](#scripts-disponíveis)
- [Troubleshooting](#troubleshooting)

---

## Contexto e objetivo

Chamadas para LLMs são demoradas (segundos) e sujeitas a falhas (timeouts, rate limits) — por isso a API nunca bloqueia a requisição HTTP esperando a geração terminar. O fluxo é sempre:

1. Usuário pede geração → API responde **na hora** com um `contentId` e status `PENDING`.
2. Um job é enfileirado no BullMQ.
3. Um **Worker** separado processa o job em background (chama a "IA", sobe o resultado no S3, atualiza o status).
4. Usuário consulta o status quando quiser via `GET /api/content/:id`.

O projeto também precisa lidar corretamente com dois cenários de concorrência: **crédito insuficiente sob requisições simultâneas** e **cancelamento no meio do processamento** — ambos detalhados na seção de [decisões arquiteturais](#decisões-arquiteturais-concorrência-e-resiliência).

## Stack técnica

| Camada | Tecnologia | Por quê |
|---|---|---|
| Linguagem | Node.js + TypeScript (`strict: true`) | Tipagem estática de ponta a ponta, incluindo `noUncheckedIndexedAccess` |
| Framework Web | [Fastify](https://fastify.dev/) | Performance e integração nativa com JSON Schema/Swagger |
| Banco de dados | PostgreSQL + [Prisma ORM](https://www.prisma.io/) | Migrations tipadas e updates atômicos condicionais |
| Fila | Redis + [BullMQ](https://docs.bullmq.io/) | Retries com backoff exponencial, jobs idempotentes |
| Storage | MinIO (S3-compatible) via AWS SDK v3 | Mesmo client funciona com AWS S3 real, só trocando env vars |
| Validação | [Zod](https://zod.dev/) | Schemas usados tanto para validar request/response quanto para gerar o OpenAPI |
| Testes | [Vitest](https://vitest.dev/) | Testes unitários das regras de negócio críticas |

## Arquitetura

Separação em camadas, sem regra de negócio nas rotas:

```
Rota (Fastify)  →  Service (regra de negócio)  →  Repository (única camada que fala com o Prisma)
```

- **Routes** (`src/modules/*/routes`): só parsing de request/response (via Zod) e chamada ao service. Zero lógica de negócio.
- **Services** (`src/modules/*/services`): orquestram as regras — débito de crédito, criação de registro, enfileiramento, cancelamento.
- **Repositories** (`src/modules/*/repositories`): único ponto de contato com o Prisma. Concentram os *updates condicionais* que resolvem os problemas de concorrência.
- **Queue/Worker** (`src/queue`): fila (`BullMQ Queue`), processor (lógica de processamento) e worker (consumidor + tratamento de retry/falha definitiva) desacoplados em arquivos separados.

## Como rodar

### Opção 1 — Docker (recomendado)

Sobe **tudo** (Postgres, Redis, MinIO, API e Worker) com um único comando:

```bash
cp .env.example .env
docker compose up --build
```

O container da API roda `prisma migrate deploy` automaticamente antes de subir, e o `minio-init` cria o bucket sozinho. Depois que tudo estiver no ar, popule um usuário de teste com créditos:

```bash
docker compose exec api npx tsx prisma/seed.ts
```

A API estará em `http://localhost:3000`.

### Opção 2 — Local com infra em Docker

Útil pra desenvolvimento com hot-reload (API e Worker rodam no host via `tsx watch`, só a infra fica em containers):

```bash
cp .env.example .env
docker compose up -d postgres redis minio minio-init

npm install
npx prisma generate
npx prisma migrate dev
npm run prisma:seed

npm run dev          # terminal 1 — API
npm run dev:worker   # terminal 2 — Worker
```

## Variáveis de ambiente

Todas descritas em [`.env.example`](.env.example) e validadas via Zod na inicialização (`src/config/env.ts`) — se alguma variável obrigatória estiver faltando ou for inválida, o processo falha imediatamente com uma mensagem clara em vez de quebrar em runtime.

| Variável | Descrição | Default |
|---|---|---|
| `PORT` | Porta da API | `3000` |
| `NODE_ENV` | `development` \| `production` \| `test` | `development` |
| `DATABASE_URL` | Connection string do Postgres | — (obrigatória) |
| `REDIS_HOST` / `REDIS_PORT` | Conexão com o Redis usado pelo BullMQ | `localhost` / `6379` |
| `S3_ENDPOINT` | Endpoint do MinIO (ou da AWS, se usar S3 real) | — (obrigatória) |
| `S3_REGION` | Região do bucket | `us-east-1` |
| `S3_ACCESS_KEY_ID` / `S3_SECRET_ACCESS_KEY` | Credenciais | — (obrigatórias) |
| `S3_BUCKET` | Nome do bucket | — (obrigatória) |
| `S3_FORCE_PATH_STYLE` | `true` para MinIO (path-style), `false` para AWS S3 real (virtual-hosted style) | `true` |

> Pra usar AWS S3 real em vez do MinIO: troque `S3_ENDPOINT` pelo endpoint da sua região (ou remova, deixando o SDK resolver sozinho), use credenciais IAM reais e `S3_FORCE_PATH_STYLE=false`. Nenhuma linha de código muda — o client (`src/infra/s3/client.ts`) é o mesmo para os dois casos.

## Documentação da API (Swagger)

Com a API no ar:

**http://localhost:3000/docs**

Gerada automaticamente a partir dos schemas Zod de cada rota (`@fastify/swagger` + `fastify-type-provider-zod`) — não é escrita manualmente, então nunca fica dessincronizada do código.

## Endpoints

| Método | Rota | Descrição |
|---|---|---|
| `POST` | `/api/content/generate` | Solicita geração de conteúdo. Retorna `contentId` e status `PENDING` imediatamente. |
| `GET` | `/api/content/:id` | Consulta status/resultado de um conteúdo. |
| `POST` | `/api/content/:id/cancel` | Cancela um conteúdo em `PENDING` ou `PROCESSING`. |
| `GET` | `/health` | Health check simples. |
| `GET` | `/docs` | Swagger UI. |

### `POST /api/content/generate`

```bash
curl -X POST http://localhost:3000/api/content/generate \
  -H "Content-Type: application/json" \
  -d '{"topic": "Inteligência Artificial", "userId": "<uuid-do-usuario>"}'
```
```json
{ "contentId": "6f1e...", "status": "PENDING" }
```
Erros possíveis: `404` (usuário não existe), `402` (sem créditos).

### `GET /api/content/:id`

```bash
curl http://localhost:3000/api/content/<contentId>
```
```json
{
  "id": "6f1e...",
  "userId": "7b1f...",
  "topic": "Inteligência Artificial",
  "status": "COMPLETED",
  "resultUrl": "http://localhost:9000/ai-content-generator/contents/6f1e....txt",
  "errorMessage": null,
  "createdAt": "2026-07-12T20:00:00.000Z",
  "updatedAt": "2026-07-12T20:00:05.000Z"
}
```
Erro possível: `404` (conteúdo não existe).

### `POST /api/content/:id/cancel`

```bash
curl -X POST http://localhost:3000/api/content/<contentId>/cancel
```
```json
{ "id": "6f1e...", "status": "CANCELED" }
```
Erros possíveis: `404` (não existe), `409` (já está em estado final — `COMPLETED` ou `FAILED` — e não pode mais ser cancelado).

## Fluxo de geração de conteúdo

```
Cliente                API                    Worker                    S3/MinIO
  │                     │                        │                          │
  │─POST /generate─────▶│                        │                          │
  │                     │─debita crédito         │                          │
  │                     │─cria Content(PENDING)  │                          │
  │                     │─enfileira job──────────▶│                         │
  │◀─201 {contentId}────│                        │                          │
  │                     │                        │─PENDING→PROCESSING       │
  │                     │                        │─chama "IA" (5s,          │
  │                     │                        │  ~20% chance de falhar)  │
  │                     │                        │─upload .txt─────────────▶│
  │                     │                        │◀─URL do arquivo──────────│
  │                     │                        │─PROCESSING→COMPLETED     │
  │─GET /:id────────────▶│                        │                          │
  │◀─status COMPLETED───│                        │                          │
```

Se a "IA" falhar, o BullMQ tenta novamente (até 4x, com backoff exponencial) antes de desistir e marcar como `FAILED` — ver seção seguinte.

## Decisões arquiteturais: concorrência e resiliência

O ponto mais crítico do desafio é evitar o padrão **"ler em memória → decidir em JS → gravar"**, que é inerentemente vulnerável a *race conditions* sob concorrência real. A solução em todos os casos foi usar **updates condicionais atômicos no PostgreSQL** como fonte única de verdade — o banco decide, não a aplicação.

### 1. Sistema de créditos

O débito é um único `UPDATE`:

```sql
UPDATE users SET credits = credits - 1 WHERE id = ? AND credits > 0
```

(implementado em [`user.repository.ts`](src/modules/user/repositories/user.repository.ts), método `debitOneCredit`)

Não há um "ler saldo, checar em JS, gravar" — o próprio Postgres decide atomicamente se há saldo disponível, e duas requisições simultâneas do mesmo usuário nunca conseguem descontar além do que existe, porque o banco serializa updates na mesma linha via lock implícito. Se `debitOneCredit` retorna `false` (0 linhas afetadas), a API responde `402` sem nunca ter criado o registro de conteúdo.

Se alguma etapa **depois** do débito falhar (criação do registro, enfileiramento do job), o crédito é devolvido via `refundOneCredit` — o usuário nunca é cobrado por um serviço que não foi de fato solicitado.

### 2. Corrida entre `/cancel` e o Worker

Este é o cenário mais delicado: o usuário pode chamar `/cancel` no exato momento em que o Worker está no meio dos 5 segundos de espera pela "IA". A tabela `contents` tem um campo `cancelRequestedAt`, e **toda transição de status do Worker é condicional**:

```sql
-- cancelamento (feito pela API)
UPDATE contents SET status = 'CANCELED', "cancelRequestedAt" = NOW()
WHERE id = ? AND status IN ('PENDING', 'PROCESSING')

-- cada transição do worker (PENDING→PROCESSING, PROCESSING→COMPLETED)
UPDATE contents SET status = ?, ...
WHERE id = ? AND status = ? AND "cancelRequestedAt" IS NULL
```

(implementado em [`content.repository.ts`](src/modules/content/repositories/content.repository.ts), métodos `requestCancel` e `transitionStatus`)

Isso garante que, não importa qual dos dois lados "chegue primeiro" fisicamente, o resultado final é sempre consistente:

- Se o `/cancel` rodar **antes** do Worker terminar o upload: o update final do Worker (`PROCESSING→COMPLETED`) afeta **0 linhas** (porque `cancelRequestedAt` já não é `NULL`), então o resultado gerado é descartado silenciosamente — o Worker nunca "ressuscita" um job cancelado.
- Se o `/cancel` rodar **depois** do Worker já ter completado: o `requestCancel` afeta 0 linhas (porque o status já não está mais em `PENDING`/`PROCESSING`), e a API responde `409` avisando que o conteúdo já está em estado final.

Esse comportamento está coberto por testes em três níveis: unitário do `ContentService.cancel` (incluindo o cenário explícito de corrida), unitário do `processContentGeneration` (cancelamento antes de iniciar, durante a chamada da IA, e durante o upload), e validação manual ponta a ponta.

### 3. Resiliência da "chamada à IA"

A função que simula a IA (`src/queue/processors/ai-simulator.ts`) espera 5 segundos e lança erro em ~20% das chamadas. O BullMQ trata isso via:

```ts
defaultJobOptions: {
  attempts: 4,
  backoff: { type: "exponential", delay: 2000 },
}
```

Um detalhe importante do BullMQ que vale registrar: o evento `worker.on("failed", ...)` dispara em **toda tentativa que falha**, não só na última. O `content.worker.ts` checa `job.attemptsMade` contra o total de `attempts` configurado para diferenciar "vai tentar de novo" de "falhou definitivamente" — só no segundo caso o conteúdo é marcado como `FAILED` (de forma condicional, respeitando um cancelamento concorrente) e o crédito é devolvido ao usuário, já que o sistema não entregou o serviço cobrado.

### 4. Idempotência do enfileiramento

Cada job é criado com `jobId: content.id` — um mesmo `contentId` nunca gera dois jobs duplicados no BullMQ, mesmo que `generate` seja chamado de forma redundante.

## Testes

```bash
npm test             # roda uma vez
npm run test:watch   # modo watch
```

16 testes cobrindo as três peças mais críticas de regra de negócio:

- **`content.service.test.ts`** — créditos (débito atômico, saldo insuficiente, estorno) e cancelamento (idempotência, estado inválido, corrida com o Worker).
- **`content-generation.processor.spec.ts`** — os cenários de cancelamento concorrente durante o processamento (antes de iniciar, durante a chamada da IA, durante o upload, e o caminho feliz completo).
- **`generate-ai-content.spec.ts`** — a função de simulação da IA, com o gerador de aleatoriedade injetado (`random: () => number`) em vez de depender de `Math.random()` real, permitindo testar deterministicamente os cenários de sucesso e falha, além do tempo de espera de 5s (via fake timers).

Os testes não dependem de banco/Redis/S3 reais — todos os repositórios e clients externos são mockados, então rodam rápido e isolados.

## Estrutura de pastas

```
src/
├── app.ts                        # monta a instância Fastify (plugins, swagger, rotas)
├── server.ts                     # entrypoint da API
├── config/
│   ├── env.ts                    # validação de env vars com Zod
│   └── redis.ts                  # opções de conexão compartilhadas (BullMQ)
├── infra/
│   ├── prisma/client.ts          # singleton do PrismaClient
│   └── s3/client.ts              # client S3/MinIO + helper de upload
├── modules/
│   ├── content/
│   │   ├── routes/                # handlers HTTP (fino, sem regra de negócio)
│   │   ├── services/              # regra de negócio (créditos, cancelamento, orquestração)
│   │   ├── repositories/          # única camada que fala com o Prisma
│   │   └── schemas/               # schemas Zod (validação + OpenAPI)
│   └── user/
│       └── repositories/
├── queue/
│   ├── jobs/                     # definição da Queue (BullMQ)
│   ├── processors/                # lógica de processamento + simulador de IA
│   └── workers/                   # Worker (consumidor da fila, tratamento de retry/falha)
└── shared/
    ├── errors/                   # classes de erro de domínio (AppError e subclasses)
    └── plugins/                   # error handler global (Fastify)

prisma/
├── schema.prisma
├── seed.ts                       # cria usuário de teste com créditos
└── migrations/

tests/unit/                       # testes unitários (Vitest)
```

## Scripts disponíveis

| Script | Descrição |
|---|---|
| `npm run dev` | API em modo watch (`tsx`) |
| `npm run dev:worker` | Worker em modo watch |
| `npm run build` | Compila TypeScript (`tsc` + `tsc-alias` para resolver os path aliases `@/...`) |
| `npm start` / `npm run start:worker` | Roda a versão compilada (produção) |
| `npm run prisma:generate` | Gera o Prisma Client |
| `npm run prisma:migrate` | Cria/aplica migration em dev |
| `npm run prisma:migrate:deploy` | Aplica migrations pendentes (usado no container da API) |
| `npm run prisma:studio` | Abre o Prisma Studio |
| `npm run prisma:seed` | Popula um usuário de teste com 10 créditos |
| `npm test` / `npm run test:watch` | Roda os testes unitários |
| `npm run lint` | ESLint (flat config, TypeScript) |
| `npm run typecheck` | `tsc --noEmit` |

## Troubleshooting

**"Variáveis de ambiente inválidas" ao rodar `npm run dev`/`dev:worker`**
Confirma que existe um `.env` na raiz (`cp .env.example .env`) — as variáveis não são carregadas de lugar nenhum sem esse arquivo.

**Erro de tipo `Module '"@prisma/client"' has no exported member 'User'`**
O Prisma Client precisa ser gerado antes do TypeScript reconhecer os tipos: `npx prisma generate`. Se o erro persistir só no editor, reinicie o TS Server do VSCode (`Ctrl+Shift+P` → `TypeScript: Restart TS Server`).

**`permission denied` ao rodar comandos Docker no WSL2**
Seu usuário precisa estar no grupo `docker`: `sudo usermod -aG docker $USER`, depois `wsl --shutdown` no PowerShell do Windows e reabrir o terminal.

**Conteúdo fica `FAILED` sem eu ver retry nos logs**
É esperado ocasionalmente — cada tentativa tem ~20% de chance de falhar, então nem sempre você vai ver múltiplas tentativas nos logs num único teste manual. O comportamento de retry é validado deterministicamente nos testes automatizados (`generate-ai-content.spec.ts`), que não dependem de sorte.