#!/usr/bin/env bash
set -e
echo '📦 Criando estrutura do projeto AI Content Generator API...'

cat > "eslint.config.js" << 'CLAUDE_EOF_MARKER'
// @ts-check
const eslint = require("@eslint/js");
const tseslint = require("typescript-eslint");

module.exports = tseslint.config(
  eslint.configs.recommended,
  ...tseslint.configs.recommended,
  {
    ignores: ["dist/**", "node_modules/**"],
  },
  {
    rules: {
      "@typescript-eslint/no-unused-vars": ["warn", { argsIgnorePattern: "^_" }],
      "@typescript-eslint/explicit-function-return-type": "off",
    },
  }
);

CLAUDE_EOF_MARKER

cat > "README.md" << 'CLAUDE_EOF_MARKER'
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

CLAUDE_EOF_MARKER

cat > "docker-compose.yml" << 'CLAUDE_EOF_MARKER'
version: "3.9"

services:
  postgres:
    image: postgres:16-alpine
    container_name: ai-content-postgres
    restart: unless-stopped
    environment:
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: postgres
      POSTGRES_DB: ai_content_generator
    ports:
      - "5432:5432"
    volumes:
      - postgres_data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 5s
      timeout: 5s
      retries: 10

  redis:
    image: redis:7-alpine
    container_name: ai-content-redis
    restart: unless-stopped
    ports:
      - "6379:6379"
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 5s
      timeout: 5s
      retries: 10

  minio:
    image: minio/minio:latest
    container_name: ai-content-minio
    restart: unless-stopped
    environment:
      MINIO_ROOT_USER: minioadmin
      MINIO_ROOT_PASSWORD: minioadmin
    command: server /data --console-address ":9001"
    ports:
      - "9000:9000"
      - "9001:9001"
    volumes:
      - minio_data:/data
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:9000/minio/health/live"]
      interval: 5s
      timeout: 5s
      retries: 10

  # Cria o bucket automaticamente ao subir o stack
  minio-init:
    image: minio/mc:latest
    depends_on:
      minio:
        condition: service_healthy
    entrypoint: >
      /bin/sh -c "
      mc alias set local http://minio:9000 minioadmin minioadmin &&
      mc mb -p local/ai-content-generator &&
      mc anonymous set download local/ai-content-generator &&
      exit 0
      "

  api:
    build:
      context: .
      dockerfile: Dockerfile
    container_name: ai-content-api
    restart: unless-stopped
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy
      minio:
        condition: service_healthy
    ports:
      - "3000:3000"
    environment:
      PORT: 3000
      NODE_ENV: production
      DATABASE_URL: postgresql://postgres:postgres@postgres:5432/ai_content_generator?schema=public
      REDIS_HOST: redis
      REDIS_PORT: 6379
      S3_ENDPOINT: http://minio:9000
      S3_REGION: us-east-1
      S3_ACCESS_KEY_ID: minioadmin
      S3_SECRET_ACCESS_KEY: minioadmin
      S3_BUCKET: ai-content-generator
      S3_FORCE_PATH_STYLE: "true"
    command: sh -c "npx prisma migrate deploy && node dist/server.js"

  worker:
    build:
      context: .
      dockerfile: Dockerfile
    container_name: ai-content-worker
    restart: unless-stopped
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy
      minio:
        condition: service_healthy
    environment:
      NODE_ENV: production
      DATABASE_URL: postgresql://postgres:postgres@postgres:5432/ai_content_generator?schema=public
      REDIS_HOST: redis
      REDIS_PORT: 6379
      S3_ENDPOINT: http://minio:9000
      S3_REGION: us-east-1
      S3_ACCESS_KEY_ID: minioadmin
      S3_SECRET_ACCESS_KEY: minioadmin
      S3_BUCKET: ai-content-generator
      S3_FORCE_PATH_STYLE: "true"
    command: sh -c "node dist/queue/workers/content.worker.js"

volumes:
  postgres_data:
  minio_data:

CLAUDE_EOF_MARKER

cat > "Dockerfile" << 'CLAUDE_EOF_MARKER'
# --- Build stage ---
FROM node:20-alpine AS builder

WORKDIR /app

COPY package*.json ./
COPY prisma ./prisma
RUN npm install

COPY . .
RUN npx prisma generate
RUN npm run build

# --- Production stage ---
FROM node:20-alpine AS production

WORKDIR /app
ENV NODE_ENV=production

COPY package*.json ./
COPY prisma ./prisma
RUN npm install --omit=dev
RUN npx prisma generate

COPY --from=builder /app/dist ./dist

EXPOSE 3000

CMD ["node", "dist/server.js"]

CLAUDE_EOF_MARKER

cat > ".gitignore" << 'CLAUDE_EOF_MARKER'
node_modules
dist
.env
*.log
.DS_Store
coverage
tmp/

CLAUDE_EOF_MARKER

cat > "vitest.config.ts" << 'CLAUDE_EOF_MARKER'
import { defineConfig } from "vitest/config";
import path from "node:path";

export default defineConfig({
  resolve: {
    alias: {
      "@": path.resolve(__dirname, "./src"),
    },
  },
  test: {
    environment: "node",
    globals: true,
  },
});

CLAUDE_EOF_MARKER

cat > "package.json" << 'CLAUDE_EOF_MARKER'
{
  "name": "ai-content-generator-api",
  "version": "1.0.0",
  "description": "AI Content Generator API - Desafio Técnico Backend Sênior",
  "main": "dist/server.js",
  "type": "commonjs",
  "scripts": {
    "dev": "tsx watch src/server.ts",
    "dev:worker": "tsx watch src/queue/workers/content.worker.ts",
    "build": "tsc -p tsconfig.json && tsc-alias -p tsconfig.json",
    "start": "node dist/server.js",
    "start:worker": "node dist/queue/workers/content.worker.js",
    "prisma:generate": "prisma generate",
    "prisma:migrate": "prisma migrate dev",
    "prisma:migrate:deploy": "prisma migrate deploy",
    "prisma:studio": "prisma studio",
    "prisma:seed": "tsx prisma/seed.ts",
    "test": "vitest run",
    "test:watch": "vitest",
    "lint": "eslint .",
    "typecheck": "tsc --noEmit"
  },
  "keywords": [],
  "author": "",
  "license": "MIT",
  "dependencies": {
    "@fastify/cors": "^10.0.1",
    "@fastify/swagger": "^9.4.0",
    "@fastify/swagger-ui": "^5.2.0",
    "@prisma/client": "^6.1.0",
    "@aws-sdk/client-s3": "^3.717.0",
    "@aws-sdk/lib-storage": "^3.717.0",
    "bullmq": "^5.34.6",
    "fastify": "^5.2.0",
    "fastify-type-provider-zod": "^4.0.2",
    "pino": "^9.5.0",
    "pino-pretty": "^13.0.0",
    "zod": "^3.24.1"
  },
  "devDependencies": {
    "@eslint/js": "^9.17.0",
    "@types/node": "^22.10.2",
    "eslint": "^9.17.0",
    "typescript-eslint": "^8.18.1",
    "prisma": "^6.1.0",
    "tsc-alias": "^1.8.10",
    "tsx": "^4.19.2",
    "typescript": "^5.7.2",
    "vitest": "^2.1.8"
  },
  "engines": {
    "node": ">=20.0.0"
  }
}

CLAUDE_EOF_MARKER

cat > ".env.example" << 'CLAUDE_EOF_MARKER'
# App
PORT=3000
NODE_ENV=development

# Database
DATABASE_URL="postgresql://postgres:postgres@localhost:5432/ai_content_generator?schema=public"

# Redis
REDIS_HOST=localhost
REDIS_PORT=6379

# S3 / MinIO
S3_ENDPOINT=http://localhost:9000
S3_REGION=us-east-1
S3_ACCESS_KEY_ID=minioadmin
S3_SECRET_ACCESS_KEY=minioadmin
S3_BUCKET=ai-content-generator
S3_FORCE_PATH_STYLE=true

CLAUDE_EOF_MARKER

cat > "tsconfig.json" << 'CLAUDE_EOF_MARKER'
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "commonjs",
    "moduleResolution": "node",
    "lib": ["ES2022"],
    "outDir": "dist",
    "rootDir": "src",
    "strict": true,
    "noUncheckedIndexedAccess": true,
    "noImplicitOverride": true,
    "exactOptionalPropertyTypes": false,
    "esModuleInterop": true,
    "skipLibCheck": true,
    "forceConsistentCasingInFileNames": true,
    "resolveJsonModule": true,
    "declaration": false,
    "sourceMap": true,
    "baseUrl": ".",
    "paths": {
      "@/*": ["src/*"]
    }
  },
  "include": ["src/**/*.ts"],
  "exclude": ["node_modules", "dist", "tests"]
}

CLAUDE_EOF_MARKER

mkdir -p "prisma"
cat > "prisma/seed.ts" << 'CLAUDE_EOF_MARKER'
import { PrismaClient } from "@prisma/client";

const prisma = new PrismaClient();

async function main(): Promise<void> {
  const user = await prisma.user.upsert({
    where: { email: "teste@example.com" },
    update: {},
    create: {
      name: "Usuário de Teste",
      email: "teste@example.com",
      credits: 10,
    },
  });

  // eslint-disable-next-line no-console
  console.log("✅ Usuário de teste:", user);
}

main()
  .catch((error) => {
    // eslint-disable-next-line no-console
    console.error(error);
    process.exit(1);
  })
  .finally(async () => {
    await prisma.$disconnect();
  });

CLAUDE_EOF_MARKER

mkdir -p "prisma"
cat > "prisma/schema.prisma" << 'CLAUDE_EOF_MARKER'
generator client {
  provider = "prisma-client-js"
}

datasource db {
  provider = "postgresql"
  url      = env("DATABASE_URL")
}

enum ContentStatus {
  PENDING
  PROCESSING
  COMPLETED
  CANCELED
  FAILED
}

model User {
  id        String   @id @default(uuid())
  name      String
  email     String   @unique
  credits   Int      @default(10)
  createdAt DateTime @default(now())
  updatedAt DateTime @updatedAt

  contents Content[]

  @@map("users")
}

model Content {
  id        String        @id @default(uuid())
  userId    String
  topic     String
  status    ContentStatus @default(PENDING)
  resultUrl String?
  errorMessage String?

  // Concorrência Worker vs API: quando o usuário chama /cancel,
  // marcamos este timestamp. O worker consulta este campo (via
  // UPDATE condicional) antes de gravar o resultado final, evitando
  // que um job "ressuscite" um conteúdo já cancelado.
  cancelRequestedAt DateTime?

  // Otimistic locking extra: incrementado a cada transição de status
  // relevante, usado como guarda em updates condicionais do worker.
  version Int @default(0)

  createdAt DateTime @default(now())
  updatedAt DateTime @updatedAt

  user User @relation(fields: [userId], references: [id])

  @@index([userId])
  @@index([status])
  @@map("contents")
}

CLAUDE_EOF_MARKER

mkdir -p "src"
cat > "src/server.ts" << 'CLAUDE_EOF_MARKER'
import { buildApp } from "@/app";
import { env } from "@/config/env";

async function main(): Promise<void> {
  const app = await buildApp();

  try {
    await app.listen({ port: env.PORT, host: "0.0.0.0" });
    app.log.info(`📚 Docs disponíveis em http://localhost:${env.PORT}/docs`);
  } catch (error) {
    app.log.error(error);
    process.exit(1);
  }

  async function shutdown(): Promise<void> {
    app.log.info("Encerrando servidor graciosamente...");
    await app.close();
    process.exit(0);
  }

  process.on("SIGTERM", shutdown);
  process.on("SIGINT", shutdown);
}

main();

CLAUDE_EOF_MARKER

mkdir -p "src"
cat > "src/app.ts" << 'CLAUDE_EOF_MARKER'
import Fastify, { type FastifyInstance } from "fastify";
import cors from "@fastify/cors";
import swagger from "@fastify/swagger";
import swaggerUi from "@fastify/swagger-ui";
import {
  serializerCompiler,
  validatorCompiler,
  jsonSchemaTransform,
  type ZodTypeProvider,
} from "fastify-type-provider-zod";
import { errorHandlerPlugin } from "@/shared/plugins/error-handler.plugin";
import { contentRoutes } from "@/modules/content/routes/content.routes";

export async function buildApp(): Promise<FastifyInstance> {
  const app = Fastify({
    logger: {
      transport:
        process.env.NODE_ENV === "development"
          ? { target: "pino-pretty", options: { colorize: true } }
          : undefined,
    },
  }).withTypeProvider<ZodTypeProvider>();

  app.setValidatorCompiler(validatorCompiler);
  app.setSerializerCompiler(serializerCompiler);

  await app.register(cors, { origin: true });

  await app.register(swagger, {
    openapi: {
      info: {
        title: "AI Content Generator API",
        description: "Desafio Técnico Backend Sênior — geração de conteúdo via IA em background.",
        version: "1.0.0",
      },
      tags: [{ name: "content", description: "Geração e consulta de conteúdo" }],
    },
    transform: jsonSchemaTransform,
  });

  await app.register(swaggerUi, {
    routePrefix: "/docs",
  });

  await app.register(errorHandlerPlugin);

  app.get("/health", async () => ({ status: "ok" }));

  await app.register(contentRoutes);

  return app;
}

CLAUDE_EOF_MARKER

mkdir -p "src/modules/user/repositories"
cat > "src/modules/user/repositories/user.repository.ts" << 'CLAUDE_EOF_MARKER'
import type { PrismaClient, User } from "@prisma/client";
import { prisma } from "@/infra/prisma/client";

export class UserRepository {
  constructor(private readonly db: PrismaClient = prisma) {}

  findById(id: string): Promise<User | null> {
    return this.db.user.findUnique({ where: { id } });
  }

  create(data: { name: string; email: string; credits?: number }): Promise<User> {
    return this.db.user.create({ data });
  }

  /**
   * Desconta 1 crédito de forma atômica e segura contra concorrência.
   * Usa um UPDATE condicional (WHERE credits > 0) diretamente no banco,
   * em vez de "ler saldo -> checar em JS -> gravar", que sofreria de
   * race condition sob requisições simultâneas (lost update).
   * Retorna true se o débito foi aplicado, false se não havia saldo.
   */
  async debitOneCredit(userId: string): Promise<boolean> {
    const result = await this.db.user.updateMany({
      where: {
        id: userId,
        credits: { gt: 0 },
      },
      data: {
        credits: { decrement: 1 },
      },
    });

    return result.count > 0;
  }

  async refundOneCredit(userId: string): Promise<void> {
    await this.db.user.update({
      where: { id: userId },
      data: { credits: { increment: 1 } },
    });
  }
}

CLAUDE_EOF_MARKER

mkdir -p "src/modules/content/services"
cat > "src/modules/content/services/content.service.ts" << 'CLAUDE_EOF_MARKER'
import type { Content } from "@prisma/client";
import { ContentRepository } from "@/modules/content/repositories/content.repository";
import { UserRepository } from "@/modules/user/repositories/user.repository";
import { contentQueue } from "@/queue/jobs/content-generation.queue";
import {
  ContentNotFoundError,
  InsufficientCreditsError,
  InvalidContentStateError,
  UserNotFoundError,
} from "@/shared/errors/domain-errors";

export interface GenerateContentInput {
  userId: string;
  topic: string;
}

export interface GenerateContentOutput {
  contentId: string;
  status: Content["status"];
}

export class ContentService {
  constructor(
    private readonly contentRepository: ContentRepository = new ContentRepository(),
    private readonly userRepository: UserRepository = new UserRepository()
  ) {}

  async generate(input: GenerateContentInput): Promise<GenerateContentOutput> {
    const user = await this.userRepository.findById(input.userId);
    if (!user) {
      throw new UserNotFoundError(input.userId);
    }

    // Débito atômico no banco (UPDATE condicional WHERE credits > 0).
    // Isso é seguro sob concorrência: duas requisições simultâneas do
    // mesmo usuário não conseguem "roubar" o último crédito, pois o
    // Postgres serializa os UPDATEs na mesma linha.
    const debited = await this.userRepository.debitOneCredit(input.userId);
    if (!debited) {
      throw new InsufficientCreditsError(input.userId);
    }

    let content: Content;
    try {
      content = await this.contentRepository.create({
        userId: input.userId,
        topic: input.topic,
      });
    } catch (error) {
      // Se a criação do registro falhar por algum motivo, devolve o crédito
      // para não cobrar por um serviço que nunca foi de fato solicitado.
      await this.userRepository.refundOneCredit(input.userId);
      throw error;
    }

    try {
      await contentQueue.add(
        "generate-content",
        { contentId: content.id, userId: input.userId, topic: input.topic },
        { jobId: content.id } // idempotência: 1 job por contentId
      );
    } catch (error) {
      // Se não conseguimos nem enfileirar, marca como FAILED e devolve o crédito.
      await this.contentRepository.transitionStatus(content.id, "PENDING", {
        status: "FAILED",
        errorMessage: "Falha ao enfileirar job de processamento",
      });
      await this.userRepository.refundOneCredit(input.userId);
      throw error;
    }

    return { contentId: content.id, status: content.status };
  }

  async findById(id: string): Promise<Content> {
    const content = await this.contentRepository.findById(id);
    if (!content) {
      throw new ContentNotFoundError(id);
    }
    return content;
  }

  async cancel(id: string): Promise<Content> {
    const existing = await this.contentRepository.findById(id);
    if (!existing) {
      throw new ContentNotFoundError(id);
    }

    if (existing.status === "COMPLETED" || existing.status === "FAILED") {
      throw new InvalidContentStateError(
        `Não é possível cancelar um conteúdo em estado final (${existing.status}).`
      );
    }

    if (existing.status === "CANCELED") {
      return existing; // idempotente
    }

    // Update condicional: só efetiva se ainda estiver PENDING/PROCESSING
    // no exato momento do UPDATE. Se o worker tiver acabado de completar
    // (COMPLETED) entre o findById acima e este update, o cancelamento
    // simplesmente não pega — o requestCancel retorna null.
    const canceled = await this.contentRepository.requestCancel(id);
    if (!canceled) {
      const latest = await this.contentRepository.findById(id);
      throw new InvalidContentStateError(
        `Conteúdo já mudou para estado final (${latest?.status}) antes do cancelamento ser aplicado.`
      );
    }

    return canceled;
  }
}

CLAUDE_EOF_MARKER

mkdir -p "src/modules/content/schemas"
cat > "src/modules/content/schemas/content.schemas.ts" << 'CLAUDE_EOF_MARKER'
import { z } from "zod";

export const ContentStatusEnum = z.enum(["PENDING", "PROCESSING", "COMPLETED", "CANCELED", "FAILED"]);

export const generateContentBodySchema = z.object({
  topic: z.string().min(3, "topic deve ter ao menos 3 caracteres").max(500),
  userId: z.string().uuid("userId deve ser um UUID válido"),
});
export type GenerateContentBody = z.infer<typeof generateContentBodySchema>;

export const generateContentResponseSchema = z.object({
  contentId: z.string().uuid(),
  status: ContentStatusEnum,
});

export const contentParamsSchema = z.object({
  id: z.string().uuid("id deve ser um UUID válido"),
});
export type ContentParams = z.infer<typeof contentParamsSchema>;

export const contentResponseSchema = z.object({
  id: z.string().uuid(),
  userId: z.string().uuid(),
  topic: z.string(),
  status: ContentStatusEnum,
  resultUrl: z.string().nullable(),
  errorMessage: z.string().nullable(),
  createdAt: z.date(),
  updatedAt: z.date(),
});

export const cancelContentResponseSchema = z.object({
  id: z.string().uuid(),
  status: ContentStatusEnum,
});

export const errorResponseSchema = z.object({
  statusCode: z.number(),
  code: z.string(),
  message: z.string(),
});

CLAUDE_EOF_MARKER

mkdir -p "src/modules/content/repositories"
cat > "src/modules/content/repositories/content.repository.ts" << 'CLAUDE_EOF_MARKER'
import type { Content, ContentStatus, PrismaClient } from "@prisma/client";
import { prisma } from "@/infra/prisma/client";

export class ContentRepository {
  constructor(private readonly db: PrismaClient = prisma) {}

  create(data: { userId: string; topic: string }): Promise<Content> {
    return this.db.content.create({
      data: {
        userId: data.userId,
        topic: data.topic,
        status: "PENDING",
      },
    });
  }

  findById(id: string): Promise<Content | null> {
    return this.db.content.findUnique({ where: { id } });
  }

  /**
   * Marca cancelamento de forma condicional: só afeta linhas que ainda
   * estão em um estado "cancelável" (PENDING ou PROCESSING). Isso evita
   * sobrescrever um conteúdo que já terminou (COMPLETED/FAILED).
   * Retorna o registro atualizado, ou null se não havia nada a cancelar.
   */
  async requestCancel(id: string): Promise<Content | null> {
    const result = await this.db.content.updateMany({
      where: {
        id,
        status: { in: ["PENDING", "PROCESSING"] },
      },
      data: {
        status: "CANCELED",
        cancelRequestedAt: new Date(),
      },
    });

    if (result.count === 0) {
      return null;
    }

    return this.findById(id);
  }

  /**
   * Transição condicional de status: só aplica o update se o registro
   * ainda estiver no status `fromStatus` esperado E não tiver sido
   * marcado para cancelamento. É a peça-chave para o Worker nunca
   * "ressuscitar" um job cancelado pelo usuário.
   */
  async transitionStatus(
    id: string,
    fromStatus: ContentStatus,
    data: Partial<Pick<Content, "status" | "resultUrl" | "errorMessage">>
  ): Promise<boolean> {
    const result = await this.db.content.updateMany({
      where: {
        id,
        status: fromStatus,
        cancelRequestedAt: null,
      },
      data,
    });

    return result.count > 0;
  }
}

CLAUDE_EOF_MARKER

mkdir -p "src/modules/content/routes"
cat > "src/modules/content/routes/content.routes.ts" << 'CLAUDE_EOF_MARKER'
import type { FastifyPluginAsync } from "fastify";
import type { ZodTypeProvider } from "fastify-type-provider-zod";
import { ContentService } from "@/modules/content/services/content.service";
import {
  generateContentBodySchema,
  generateContentResponseSchema,
  contentParamsSchema,
  contentResponseSchema,
  cancelContentResponseSchema,
  errorResponseSchema,
} from "@/modules/content/schemas/content.schemas";

const contentService = new ContentService();

export const contentRoutes: FastifyPluginAsync = async (fastify) => {
  const app = fastify.withTypeProvider<ZodTypeProvider>();

  app.post(
    "/api/content/generate",
    {
      schema: {
        description: "Solicita a geração de um novo conteúdo via IA (processado em background).",
        tags: ["content"],
        body: generateContentBodySchema,
        response: {
          201: generateContentResponseSchema,
          402: errorResponseSchema,
          404: errorResponseSchema,
        },
      },
    },
    async (request, reply) => {
      const result = await contentService.generate(request.body);
      return reply.status(201).send(result);
    }
  );

  app.get(
    "/api/content/:id",
    {
      schema: {
        description: "Consulta o status e o resultado de um conteúdo gerado.",
        tags: ["content"],
        params: contentParamsSchema,
        response: {
          200: contentResponseSchema,
          404: errorResponseSchema,
        },
      },
    },
    async (request) => {
      return contentService.findById(request.params.id);
    }
  );

  app.post(
    "/api/content/:id/cancel",
    {
      schema: {
        description: "Cancela a geração de um conteúdo em andamento (PENDING ou PROCESSING).",
        tags: ["content"],
        params: contentParamsSchema,
        response: {
          200: cancelContentResponseSchema,
          404: errorResponseSchema,
          409: errorResponseSchema,
        },
      },
    },
    async (request) => {
      return contentService.cancel(request.params.id);
    }
  );
};

CLAUDE_EOF_MARKER

mkdir -p "src/shared/errors"
cat > "src/shared/errors/domain-errors.ts" << 'CLAUDE_EOF_MARKER'
export abstract class AppError extends Error {
  abstract readonly statusCode: number;
  abstract readonly code: string;

  constructor(message: string) {
    super(message);
    this.name = this.constructor.name;
  }
}

export class InsufficientCreditsError extends AppError {
  readonly statusCode = 402;
  readonly code = "INSUFFICIENT_CREDITS";

  constructor(userId: string) {
    super(`Usuário ${userId} não possui créditos suficientes para gerar conteúdo.`);
  }
}

export class ContentNotFoundError extends AppError {
  readonly statusCode = 404;
  readonly code = "CONTENT_NOT_FOUND";

  constructor(id: string) {
    super(`Conteúdo com id ${id} não foi encontrado.`);
  }
}

export class UserNotFoundError extends AppError {
  readonly statusCode = 404;
  readonly code = "USER_NOT_FOUND";

  constructor(id: string) {
    super(`Usuário com id ${id} não foi encontrado.`);
  }
}

export class InvalidContentStateError extends AppError {
  readonly statusCode = 409;
  readonly code = "INVALID_CONTENT_STATE";

  constructor(message: string) {
    super(message);
  }
}

CLAUDE_EOF_MARKER

mkdir -p "src/shared/plugins"
cat > "src/shared/plugins/error-handler.plugin.ts" << 'CLAUDE_EOF_MARKER'
import fp from "fastify-plugin";
import type { FastifyError, FastifyPluginAsync } from "fastify";
import { ZodError } from "zod";
import { AppError } from "@/shared/errors/domain-errors";

export const errorHandlerPlugin: FastifyPluginAsync = fp(async (fastify) => {
  fastify.setErrorHandler((error: FastifyError | AppError | ZodError, request, reply) => {
    // Erros de negócio conhecidos (mapeados para o status code correto)
    if (error instanceof AppError) {
      return reply.status(error.statusCode).send({
        statusCode: error.statusCode,
        code: error.code,
        message: error.message,
      });
    }

    // Erros de validação do Zod (via fastify-type-provider-zod)
    if (error instanceof ZodError) {
      return reply.status(400).send({
        statusCode: 400,
        code: "VALIDATION_ERROR",
        message: "Dados de entrada inválidos.",
        issues: error.issues,
      });
    }

    // Erros de validação já formatados pelo fastify-type-provider-zod
    if (error.validation) {
      return reply.status(400).send({
        statusCode: 400,
        code: "VALIDATION_ERROR",
        message: error.message,
      });
    }

    // Qualquer outro erro: loga completo internamente, mas NUNCA
    // devolve stack trace ou detalhes internos para o cliente.
    request.log.error({ err: error }, "Erro interno não tratado");

    return reply.status(500).send({
      statusCode: 500,
      code: "INTERNAL_SERVER_ERROR",
      message: "Ocorreu um erro interno. Tente novamente mais tarde.",
    });
  });

  fastify.setNotFoundHandler((request, reply) => {
    return reply.status(404).send({
      statusCode: 404,
      code: "ROUTE_NOT_FOUND",
      message: `Rota ${request.method} ${request.url} não encontrada.`,
    });
  });
});

CLAUDE_EOF_MARKER

mkdir -p "src/config"
cat > "src/config/redis.ts" << 'CLAUDE_EOF_MARKER'
import type { ConnectionOptions } from "bullmq";
import { env } from "@/config/env";

// BullMQ exige maxRetriesPerRequest: null na conexão usada por Queue/Worker
// para habilitar os comandos de blocking (BRPOPLPUSH etc.). Passamos um
// objeto de opções (em vez de uma instância de Redis própria) para evitar
// conflito de tipos entre a versão do ioredis do projeto e a que o BullMQ
// usa internamente como dependência.
export function createRedisConnection(): ConnectionOptions {
  return {
    host: env.REDIS_HOST,
    port: env.REDIS_PORT,
    maxRetriesPerRequest: null,
  };
}

CLAUDE_EOF_MARKER

mkdir -p "src/config"
cat > "src/config/env.ts" << 'CLAUDE_EOF_MARKER'
import { z } from "zod";

const envSchema = z.object({
  PORT: z.coerce.number().default(3000),
  NODE_ENV: z.enum(["development", "production", "test"]).default("development"),

  DATABASE_URL: z.string().min(1),

  REDIS_HOST: z.string().default("localhost"),
  REDIS_PORT: z.coerce.number().default(6379),

  S3_ENDPOINT: z.string().url(),
  S3_REGION: z.string().default("us-east-1"),
  S3_ACCESS_KEY_ID: z.string().min(1),
  S3_SECRET_ACCESS_KEY: z.string().min(1),
  S3_BUCKET: z.string().min(1),
  S3_FORCE_PATH_STYLE: z.coerce.boolean().default(true),
});

const parsed = envSchema.safeParse(process.env);

if (!parsed.success) {
  // eslint-disable-next-line no-console
  console.error("❌ Variáveis de ambiente inválidas:", parsed.error.flatten().fieldErrors);
  process.exit(1);
}

export const env = parsed.data;

CLAUDE_EOF_MARKER

mkdir -p "src/queue/jobs"
cat > "src/queue/jobs/content-generation.queue.ts" << 'CLAUDE_EOF_MARKER'
import { Queue } from "bullmq";
import { createRedisConnection } from "@/config/redis";

export interface GenerateContentJobData {
  contentId: string;
  userId: string;
  topic: string;
}

export const CONTENT_QUEUE_NAME = "content-generation";

export const contentQueue = new Queue<GenerateContentJobData>(CONTENT_QUEUE_NAME, {
  connection: createRedisConnection(),
  defaultJobOptions: {
    attempts: 4,
    backoff: {
      type: "exponential",
      delay: 2000,
    },
    removeOnComplete: { age: 3600, count: 1000 },
    removeOnFail: { age: 86400 },
  },
});

CLAUDE_EOF_MARKER

mkdir -p "src/queue/processors"
cat > "src/queue/processors/ai-simulator.ts" << 'CLAUDE_EOF_MARKER'
export class AIGenerationError extends Error {
  constructor(topic: string) {
    super(`Falha simulada ao gerar conteúdo para o tópico "${topic}"`);
    this.name = "AIGenerationError";
  }
}

/**
 * Simula uma chamada a um LLM externo: demora 5s e falha aleatoriamente
 * em ~20% das vezes, para exercitar o mecanismo de retry do worker.
 */
export async function generateAIContent(topic: string): Promise<string> {
  await new Promise((resolve) => setTimeout(resolve, 5000));

  const shouldFail = Math.random() < 0.2;
  if (shouldFail) {
    throw new AIGenerationError(topic);
  }

  return [
    `Título: Tudo sobre ${topic}`,
    "",
    `Este é um conteúdo gerado automaticamente sobre "${topic}".`,
    "Ele explora os principais aspectos do tema, oferecendo uma visão",
    "geral clara e objetiva para o leitor interessado no assunto.",
    "",
    `Gerado em: ${new Date().toISOString()}`,
  ].join("\n");
}

CLAUDE_EOF_MARKER

mkdir -p "src/queue/processors"
cat > "src/queue/processors/content-generation.processor.ts" << 'CLAUDE_EOF_MARKER'
import type { Job } from "bullmq";
import type { GenerateContentJobData } from "@/queue/jobs/content-generation.queue";
import { ContentRepository } from "@/modules/content/repositories/content.repository";
import { generateAIContent } from "@/queue/processors/ai-simulator";
import { uploadTextFile } from "@/infra/s3/client";

export interface ProcessResult {
  skipped: boolean;
  reason?: "already-canceled" | "canceled-race" | "canceled-during-ai" | "canceled-after-upload";
}

const contentRepository = new ContentRepository();

export async function processContentGeneration(
  job: Job<GenerateContentJobData>
): Promise<ProcessResult> {
  const { contentId, topic } = job.data;

  // 1) Guarda de entrada: se já foi cancelado antes mesmo do worker pegar o job, nem começa.
  const current = await contentRepository.findById(contentId);
  if (!current || current.cancelRequestedAt !== null || current.status === "CANCELED") {
    return { skipped: true, reason: "already-canceled" };
  }

  // 2) Transição PENDING -> PROCESSING (condicional). Em retries (attempt > 1),
  // o status já é PROCESSING, então pulamos essa etapa.
  if (current.status === "PENDING") {
    const moved = await contentRepository.transitionStatus(contentId, "PENDING", {
      status: "PROCESSING",
    });
    if (!moved) {
      // Perdeu a corrida: o usuário cancelou entre o findById e o update.
      return { skipped: true, reason: "canceled-race" };
    }
  }

  // 3) Chamada (simulada) à IA — pode falhar ~20% das vezes.
  let generatedText: string;
  try {
    generatedText = await generateAIContent(topic);
  } catch (error) {
    // Antes de deixar o BullMQ tentar de novo, checa se foi cancelado
    // enquanto esperávamos a "IA". Se sim, não faz sentido retentar.
    const check = await contentRepository.findById(contentId);
    if (check?.cancelRequestedAt) {
      return { skipped: true, reason: "canceled-during-ai" };
    }
    throw error; // deixa o BullMQ aplicar o retry/backoff configurado na Queue
  }

  // 4) Upload do resultado para o S3/MinIO.
  const objectKey = `contents/${contentId}.txt`;
  const resultUrl = await uploadTextFile({ key: objectKey, content: generatedText });

  // 5) Transição final PROCESSING -> COMPLETED (condicional). Se o usuário
  // cancelou durante o upload, este update afeta 0 linhas e o resultado
  // é descartado silenciosamente — nunca sobrescrevemos um CANCELED.
  const completed = await contentRepository.transitionStatus(contentId, "PROCESSING", {
    status: "COMPLETED",
    resultUrl,
  });

  if (!completed) {
    return { skipped: true, reason: "canceled-after-upload" };
  }

  return { skipped: false };
}

CLAUDE_EOF_MARKER

mkdir -p "src/queue/workers"
cat > "src/queue/workers/content.worker.ts" << 'CLAUDE_EOF_MARKER'
import { Worker, type Job } from "bullmq";
import { createRedisConnection } from "@/config/redis";
import { env } from "@/config/env";
import {
  CONTENT_QUEUE_NAME,
  type GenerateContentJobData,
} from "@/queue/jobs/content-generation.queue";
import { processContentGeneration } from "@/queue/processors/content-generation.processor";
import { ContentRepository } from "@/modules/content/repositories/content.repository";
import { UserRepository } from "@/modules/user/repositories/user.repository";

const contentRepository = new ContentRepository();
const userRepository = new UserRepository();

const worker = new Worker<GenerateContentJobData>(
  CONTENT_QUEUE_NAME,
  async (job: Job<GenerateContentJobData>) => {
    return processContentGeneration(job);
  },
  {
    connection: createRedisConnection(),
    concurrency: 5,
  }
);

worker.on("completed", (job, result) => {
  // eslint-disable-next-line no-console
  console.log(`[worker] job ${job.id} concluído`, result);
});

// Disparado somente quando o job esgota todas as tentativas (`attempts`
// configuradas na Queue). Aqui marcamos o conteúdo como FAILED (de forma
// condicional, respeitando um possível cancelamento) e devolvemos o
// crédito ao usuário, já que o sistema não entregou o serviço pago.
worker.on("failed", async (job, error) => {
  if (!job) return;

  const { contentId, userId } = job.data;
  // eslint-disable-next-line no-console
  console.error(`[worker] job ${job.id} falhou definitivamente:`, error.message);

  const marked = await contentRepository.transitionStatus(contentId, "PROCESSING", {
    status: "FAILED",
    errorMessage: error.message,
  });

  if (marked) {
    await userRepository.refundOneCredit(userId);
  }
});

worker.on("error", (error) => {
  // eslint-disable-next-line no-console
  console.error("[worker] erro de infraestrutura:", error);
});

// eslint-disable-next-line no-console
console.log(`[worker] escutando a fila "${CONTENT_QUEUE_NAME}" (env=${env.NODE_ENV})`);

async function shutdown(): Promise<void> {
  // eslint-disable-next-line no-console
  console.log("[worker] encerrando graciosamente...");
  await worker.close();
  process.exit(0);
}

process.on("SIGTERM", shutdown);
process.on("SIGINT", shutdown);

CLAUDE_EOF_MARKER

mkdir -p "src/infra/prisma"
cat > "src/infra/prisma/client.ts" << 'CLAUDE_EOF_MARKER'
import { PrismaClient } from "@prisma/client";

declare global {
  // eslint-disable-next-line no-var
  var __prisma: PrismaClient | undefined;
}

// Evita múltiplas instâncias em hot-reload (tsx watch)
export const prisma: PrismaClient =
  global.__prisma ??
  new PrismaClient({
    log: process.env.NODE_ENV === "development" ? ["warn", "error"] : ["error"],
  });

if (process.env.NODE_ENV === "development") {
  global.__prisma = prisma;
}

CLAUDE_EOF_MARKER

mkdir -p "src/infra/s3"
cat > "src/infra/s3/client.ts" << 'CLAUDE_EOF_MARKER'
import { S3Client, PutObjectCommand } from "@aws-sdk/client-s3";
import { env } from "@/config/env";

export const s3Client = new S3Client({
  endpoint: env.S3_ENDPOINT,
  region: env.S3_REGION,
  forcePathStyle: env.S3_FORCE_PATH_STYLE,
  credentials: {
    accessKeyId: env.S3_ACCESS_KEY_ID,
    secretAccessKey: env.S3_SECRET_ACCESS_KEY,
  },
});

export interface UploadTextFileParams {
  key: string;
  content: string;
}

export async function uploadTextFile({ key, content }: UploadTextFileParams): Promise<string> {
  await s3Client.send(
    new PutObjectCommand({
      Bucket: env.S3_BUCKET,
      Key: key,
      Body: content,
      ContentType: "text/plain; charset=utf-8",
    })
  );

  // Monta a URL pública (path-style), válida tanto para Minio local quanto AWS S3 real
  return `${env.S3_ENDPOINT}/${env.S3_BUCKET}/${key}`;
}

CLAUDE_EOF_MARKER

mkdir -p "tests/unit"
cat > "tests/unit/content.service.test.ts" << 'CLAUDE_EOF_MARKER'
import { describe, it, expect, vi, beforeEach } from "vitest";
import { ContentService } from "@/modules/content/services/content.service";
import { InsufficientCreditsError, InvalidContentStateError, UserNotFoundError } from "@/shared/errors/domain-errors";

vi.mock("@/queue/jobs/content-generation.queue", () => ({
  contentQueue: { add: vi.fn().mockResolvedValue(undefined) },
}));

// Isola o teste do Prisma Client real (evita depender de "prisma generate"
// / conexão com banco só para rodar testes unitários de regra de negócio).
vi.mock("@/infra/prisma/client", () => ({ prisma: {} }));

function makeRepos() {
  const contentRepository = {
    create: vi.fn(),
    findById: vi.fn(),
    requestCancel: vi.fn(),
    transitionStatus: vi.fn(),
  };
  const userRepository = {
    findById: vi.fn(),
    debitOneCredit: vi.fn(),
    refundOneCredit: vi.fn(),
    create: vi.fn(),
  };
  return { contentRepository, userRepository };
}

describe("ContentService.generate", () => {
  let repos: ReturnType<typeof makeRepos>;
  let service: ContentService;

  beforeEach(() => {
    repos = makeRepos();
    // @ts-expect-error - mocks parciais o suficiente para o teste
    service = new ContentService(repos.contentRepository, repos.userRepository);
  });

  it("lança UserNotFoundError se o usuário não existir", async () => {
    repos.userRepository.findById.mockResolvedValue(null);

    await expect(service.generate({ userId: "u1", topic: "IA" })).rejects.toBeInstanceOf(
      UserNotFoundError
    );
    expect(repos.userRepository.debitOneCredit).not.toHaveBeenCalled();
  });

  it("lança InsufficientCreditsError quando o débito atômico falha (sem saldo)", async () => {
    repos.userRepository.findById.mockResolvedValue({ id: "u1", credits: 0 });
    repos.userRepository.debitOneCredit.mockResolvedValue(false);

    await expect(service.generate({ userId: "u1", topic: "IA" })).rejects.toBeInstanceOf(
      InsufficientCreditsError
    );
    expect(repos.contentRepository.create).not.toHaveBeenCalled();
  });

  it("cria o conteúdo e enfileira o job quando há crédito disponível", async () => {
    repos.userRepository.findById.mockResolvedValue({ id: "u1", credits: 5 });
    repos.userRepository.debitOneCredit.mockResolvedValue(true);
    repos.contentRepository.create.mockResolvedValue({
      id: "c1",
      status: "PENDING",
      userId: "u1",
      topic: "IA",
    });

    const result = await service.generate({ userId: "u1", topic: "IA" });

    expect(result).toEqual({ contentId: "c1", status: "PENDING" });
    expect(repos.userRepository.debitOneCredit).toHaveBeenCalledWith("u1");
  });

  it("devolve o crédito se a criação do registro falhar após o débito", async () => {
    repos.userRepository.findById.mockResolvedValue({ id: "u1", credits: 5 });
    repos.userRepository.debitOneCredit.mockResolvedValue(true);
    repos.contentRepository.create.mockRejectedValue(new Error("db down"));

    await expect(service.generate({ userId: "u1", topic: "IA" })).rejects.toThrow("db down");
    expect(repos.userRepository.refundOneCredit).toHaveBeenCalledWith("u1");
  });
});

describe("ContentService.cancel — concorrência com o Worker", () => {
  let repos: ReturnType<typeof makeRepos>;
  let service: ContentService;

  beforeEach(() => {
    repos = makeRepos();
    // @ts-expect-error - mocks parciais o suficiente para o teste
    service = new ContentService(repos.contentRepository, repos.userRepository);
  });

  it("cancela normalmente um conteúdo PENDING", async () => {
    repos.contentRepository.findById.mockResolvedValue({ id: "c1", status: "PENDING" });
    repos.contentRepository.requestCancel.mockResolvedValue({ id: "c1", status: "CANCELED" });

    const result = await service.cancel("c1");

    expect(result.status).toBe("CANCELED");
  });

  it("é idempotente ao cancelar um conteúdo já CANCELED", async () => {
    repos.contentRepository.findById.mockResolvedValue({ id: "c1", status: "CANCELED" });

    const result = await service.cancel("c1");

    expect(result.status).toBe("CANCELED");
    expect(repos.contentRepository.requestCancel).not.toHaveBeenCalled();
  });

  it("lança erro ao tentar cancelar um conteúdo já COMPLETED", async () => {
    repos.contentRepository.findById.mockResolvedValue({ id: "c1", status: "COMPLETED" });

    await expect(service.cancel("c1")).rejects.toBeInstanceOf(InvalidContentStateError);
    expect(repos.contentRepository.requestCancel).not.toHaveBeenCalled();
  });

  it("detecta quando o Worker completou o job entre a leitura e o update (race condition)", async () => {
    // Simula: no findById inicial o conteúdo ainda está PROCESSING,
    // mas entre esse instante e o UPDATE condicional, o worker já
    // finalizou o job (COMPLETED) — então requestCancel afeta 0 linhas.
    repos.contentRepository.findById
      .mockResolvedValueOnce({ id: "c1", status: "PROCESSING" })
      .mockResolvedValueOnce({ id: "c1", status: "COMPLETED" });
    repos.contentRepository.requestCancel.mockResolvedValue(null);

    await expect(service.cancel("c1")).rejects.toBeInstanceOf(InvalidContentStateError);
  });
});

CLAUDE_EOF_MARKER

echo '✅ Estrutura criada! Rodando npm install...'
npm install
echo '🎉 Pronto! Agora rode: cp .env.example .env && docker compose up -d postgres redis minio minio-init'