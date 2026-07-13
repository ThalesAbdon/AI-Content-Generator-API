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
  console.log(`[worker] job ${job.id} concluído`, result);
});

// IMPORTANTE: o evento "failed" do BullMQ dispara em TODA tentativa que
// falha — não apenas na última. Por isso é essencial checar
// job.attemptsMade contra o total de `attempts` configurado para saber
// se ainda vai haver retry ou se essa foi a tentativa definitiva.
worker.on("failed", async (job, error) => {
  if (!job) return;

  const maxAttempts = job.opts.attempts ?? 1;
  const isFinalAttempt = job.attemptsMade >= maxAttempts;

  if (!isFinalAttempt) {
    console.warn(
      `[worker] job ${job.id} falhou na tentativa ${job.attemptsMade}/${maxAttempts}, vai tentar novamente:`,
      error.message
    );
    return; // deixa o BullMQ agendar o retry (backoff exponencial já configurado na Queue)
  }

  const { contentId, userId } = job.data;
  console.error(
    `[worker] job ${job.id} falhou definitivamente após ${job.attemptsMade}/${maxAttempts} tentativas:`,
    error.message
  );

  const marked = await contentRepository.transitionStatus(contentId, "PROCESSING", {
    status: "FAILED",
    errorMessage: error.message,
  });

  if (marked) {
    await userRepository.refundOneCredit(userId);
  }
});

worker.on("error", (error) => {
  console.error("[worker] erro de infraestrutura:", error);
});

console.log(`[worker] escutando a fila "${CONTENT_QUEUE_NAME}" (env=${env.NODE_ENV})`);

async function shutdown(): Promise<void> {
  console.log("[worker] encerrando graciosamente...");
  await worker.close();
  process.exit(0);
}

process.on("SIGTERM", shutdown);
process.on("SIGINT", shutdown);