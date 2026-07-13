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

