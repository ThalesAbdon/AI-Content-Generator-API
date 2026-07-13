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

