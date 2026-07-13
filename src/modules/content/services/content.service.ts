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

