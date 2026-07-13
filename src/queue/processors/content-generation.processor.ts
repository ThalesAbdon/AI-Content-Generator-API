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

