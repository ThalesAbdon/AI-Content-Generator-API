import { beforeEach, describe, expect, it, vi } from "vitest";

const repository = vi.hoisted(() => ({
  findById: vi.fn(),
  transitionStatus: vi.fn(),
}));

vi.mock("@/modules/content/repositories/content.repository", () => {
  return {
    ContentRepository: vi.fn(() => repository),
  };
});

vi.mock("@/queue/processors/ai-simulator", () => ({
  generateAIContent: vi.fn(),
}));

vi.mock("@/infra/s3/client", () => ({
  uploadTextFile: vi.fn(),
}));

import { processContentGeneration } from "../../src/queue/processors/content-generation.processor";
import { generateAIContent } from "../../src/queue/processors/ai-simulator";
import { uploadTextFile } from "../../src/infra/s3/client";

describe("processContentGeneration", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it("ignora conteúdos já cancelados antes do worker iniciar", async () => {
    repository.findById.mockResolvedValue({
      id: "c1",
      status: "CANCELED",
      cancelRequestedAt: new Date(),
    });

    const result = await processContentGeneration({
      data: {
        contentId: "c1",
        topic: "Node",
      },
    } as any);

    expect(result).toEqual({
      skipped: true,
      reason: "already-canceled",
    });

    expect(generateAIContent).not.toHaveBeenCalled();
    expect(uploadTextFile).not.toHaveBeenCalled();
  });

  it("marca PROCESSING e COMPLETED quando todo processamento ocorre com sucesso", async () => {
    repository.findById.mockResolvedValue({
      id: "c1",
      status: "PENDING",
      cancelRequestedAt: null,
    });

    repository.transitionStatus
      .mockResolvedValueOnce(true)
      .mockResolvedValueOnce(true);

    vi.mocked(generateAIContent).mockResolvedValue("conteúdo gerado");

    vi.mocked(uploadTextFile).mockResolvedValue(
      "https://minio/content.txt"
    );

    const result = await processContentGeneration({
      data: {
        contentId: "c1",
        topic: "Node",
      },
    } as any);

    expect(generateAIContent).toHaveBeenCalledWith("Node");

    expect(uploadTextFile).toHaveBeenCalledWith({
      key: "contents/c1.txt",
      content: "conteúdo gerado",
    });

    expect(repository.transitionStatus).toHaveBeenNthCalledWith(
      1,
      "c1",
      "PENDING",
      {
        status: "PROCESSING",
      }
    );

    expect(repository.transitionStatus).toHaveBeenNthCalledWith(
      2,
      "c1",
      "PROCESSING",
      {
        status: "COMPLETED",
        resultUrl: "https://minio/content.txt",
      }
    );

    expect(result).toEqual({
      skipped: false,
    });
  });

  it("não ressuscita um conteúdo cancelado durante a chamada da IA", async () => {
    repository.findById
      .mockResolvedValueOnce({
        id: "c1",
        status: "PENDING",
        cancelRequestedAt: null,
      })
      .mockResolvedValueOnce({
        id: "c1",
        status: "CANCELED",
        cancelRequestedAt: new Date(),
      });

    repository.transitionStatus.mockResolvedValue(true);

    vi.mocked(generateAIContent).mockRejectedValue(
      new Error("LLM timeout")
    );

    const result = await processContentGeneration({
      data: {
        contentId: "c1",
        topic: "Node",
      },
    } as any);

    expect(result).toEqual({
      skipped: true,
      reason: "canceled-during-ai",
    });
  });

  it("propaga o erro quando a IA falha e o conteúdo não foi cancelado", async () => {
    repository.findById
      .mockResolvedValueOnce({
        id: "c1",
        status: "PENDING",
        cancelRequestedAt: null,
      })
      .mockResolvedValueOnce({
        id: "c1",
        status: "PROCESSING",
        cancelRequestedAt: null,
      });

    repository.transitionStatus.mockResolvedValue(true);

    vi.mocked(generateAIContent).mockRejectedValue(
      new Error("IA indisponível")
    );

    await expect(
      processContentGeneration({
        data: {
          contentId: "c1",
          topic: "Node",
        },
      } as any)
    ).rejects.toThrow("IA indisponível");
  });

  it("descarta o resultado quando o conteúdo é cancelado durante o upload", async () => {
    repository.findById.mockResolvedValue({
      id: "c1",
      status: "PENDING",
      cancelRequestedAt: null,
    });

    repository.transitionStatus
      .mockResolvedValueOnce(true)
      .mockResolvedValueOnce(false);

    vi.mocked(generateAIContent).mockResolvedValue("conteúdo");

    vi.mocked(uploadTextFile).mockResolvedValue(
      "https://minio/content.txt"
    );

    const result = await processContentGeneration({
      data: {
        contentId: "c1",
        topic: "Node",
      },
    } as any);

    expect(result).toEqual({
      skipped: true,
      reason: "canceled-after-upload",
    });
  });
});