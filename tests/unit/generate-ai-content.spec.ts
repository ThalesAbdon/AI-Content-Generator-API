import { afterEach, describe, expect, it, vi } from "vitest";
import {
  generateAIContent,
  AIGenerationError,
} from "../../src/queue/processors/ai-simulator";

describe("generateAIContent", () => {
  afterEach(() => {
    vi.useRealTimers();
    vi.restoreAllMocks();
  });

  it("gera conteúdo quando o random é maior que 0.2", async () => {
    vi.useFakeTimers();

    const promise = generateAIContent("Node.js", () => 0.9);

    await vi.advanceTimersByTimeAsync(5000);

    const result = await promise;

    expect(result).toContain("Título: Tudo sobre Node.js");
    expect(result).toContain(
      'Este é um conteúdo gerado automaticamente sobre "Node.js".'
    );
    expect(result).toContain("Gerado em:");
  });

  it("lança AIGenerationError quando o random é menor que 0.2", async () => {
    vi.useFakeTimers();

    const assertion = expect(
      generateAIContent("Node.js", () => 0.1)
    ).rejects.toBeInstanceOf(AIGenerationError);

    await vi.advanceTimersByTimeAsync(5000);

    await assertion;
  });

  it("aguarda aproximadamente 5 segundos antes de concluir", async () => {
    vi.useFakeTimers();

    const promise = generateAIContent("Node.js", () => 0.9);

    await vi.advanceTimersByTimeAsync(4999);

    let finished = false;

    promise.then(() => {
      finished = true;
    });

    await Promise.resolve();

    expect(finished).toBe(false);

    await vi.advanceTimersByTimeAsync(1);

    await expect(promise).resolves.toContain("Tudo sobre Node.js");
  });
});