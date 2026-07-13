import { describe, it, expect, vi, beforeEach } from "vitest";
import { ContentService } from "../../src/modules/content/services/content.service";
import { InsufficientCreditsError, InvalidContentStateError, UserNotFoundError } from "../../src/shared/errors/domain-errors";

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

