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

