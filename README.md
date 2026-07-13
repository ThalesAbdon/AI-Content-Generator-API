# AI Content Generator API

Desafio Técnico Backend Sênior: API que gera conteúdos via IA (simulada) de forma assíncrona, resiliente a falhas e segura sob concorrência.

## Stack

Node.js + TypeScript (strict) · Fastify · PostgreSQL + Prisma · Redis + BullMQ · MinIO (S3) · Zod · Vitest

## Como rodar

### Opção 1 — Docker (recomendado)

```bash
cp .env.example .env
docker compose up --build
```

Isso sobe Postgres, Redis, MinIO (com bucket já criado), a API e o Worker. A API roda as migrations automaticamente antes de subir (`prisma migrate deploy`).

Depois, popule um usuário de teste com créditos:

```bash
docker compose exec api npx tsx prisma/seed.ts
```

### Opção 2 — Local (API/Worker no host, infra no Docker)

```bash
cp .env.example .env
docker compose up -d postgres redis minio minio-init

npm install
npx prisma migrate dev
npm run prisma:seed

npm run dev          # terminal 1: API
npm run dev:worker   # terminal 2: Worker
```

## Documentação (Swagger)

Com a API no ar: **http://localhost:3000/docs**

## Testes

```bash
npm test
```

Cobre a regra de negócio de créditos (débito atômico, insuficiência de saldo, estorno) e o cenário de corrida entre `/cancel` e o Worker.

## Fluxo de uso rápido

```bash
# 1. Pegue o id do usuário de teste (criado pelo seed) via Prisma Studio ou log do seed
npx prisma studio

# 2. Gere um conteúdo
curl -X POST http://localhost:3000/api/content/generate \
  -H "Content-Type: application/json" \
  -d '{"topic": "Inteligência Artificial", "userId": "<uuid-do-usuario>"}'

# 3. Consulte o status
curl http://localhost:3000/api/content/<contentId>

# 4. (Opcional) Cancele antes de completar
curl -X POST http://localhost:3000/api/content/<contentId>/cancel
```

## Decisões arquiteturais (concorrência e resiliência)

O projeto segue separação em camadas — **rotas** (apenas parsing/HTTP), **services** (regra de negócio) e **repositories** (única camada que fala com o Prisma) — para manter a lógica testável e fora dos handlers HTTP. Os dois pontos de concorrência exigidos pelo desafio foram resolvidos evitando o padrão "ler em memória → decidir em JS → gravar", que é inerentemente vulnerável a *race conditions* sob carga concorrente, e usando **updates condicionais atômicos no PostgreSQL** como fonte única de verdade. Para o **sistema de créditos**, o débito é feito com um único `UPDATE users SET credits = credits - 1 WHERE id = ? AND credits > 0`: o próprio banco decide atomicamente se há saldo, e duas requisições simultâneas do mesmo usuário nunca conseguem descontar além do saldo disponível (o Postgres serializa updates na mesma linha via lock implícito). Para a **corrida entre `/cancel` e o Worker**, a tabela `contents` tem um campo `cancelRequestedAt`: o endpoint de cancelamento faz um `UPDATE ... WHERE status IN ('PENDING','PROCESSING')` (só "vence" se o conteúdo ainda estiver em andamento), e o Worker, antes de cada transição de status (`PENDING→PROCESSING` e `PROCESSING→COMPLETED`), faz o update condicionado ao status esperado e a `cancelRequestedAt IS NULL`. Se o usuário cancelar durante os 5s de espera pela "IA", o update final do Worker afeta 0 linhas e o resultado é descartado silenciosamente — o Worker nunca "ressuscita" um job cancelado, independentemente de qual dos dois lados "chegou primeiro" fisicamente. Para **resiliência**, a função de IA lança erro em ~20% das chamadas e o BullMQ trata isso via `attempts: 4` com backoff exponencial; se todas as tentativas se esgotarem, um listener `worker.on("failed")` marca o conteúdo como `FAILED` (de forma condicional, respeitando um cancelamento concorrente) e devolve o crédito ao usuário, já que o sistema não entregou o serviço cobrado.

## Endpoints

| Método | Rota | Descrição |
|---|---|---|
| POST | `/api/content/generate` | Solicita geração (retorna `contentId` imediatamente) |
| GET | `/api/content/:id` | Consulta status/resultado |
| POST | `/api/content/:id/cancel` | Cancela geração em andamento |
| GET | `/docs` | Swagger UI |
| GET | `/health` | Health check |

## Observações

- Erros de negócio (crédito insuficiente, conteúdo não encontrado, estado inválido) retornam status HTTP apropriados (402/404/409) com corpo estruturado; erros inesperados nunca vazam stack trace (ver `src/shared/plugins/error-handler.plugin.ts`).
- `jobId: content.id` no enfileiramento garante que um mesmo `contentId` nunca gera dois jobs duplicados no BullMQ.

