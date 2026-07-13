export class AIGenerationError extends Error {
  constructor(topic: string) {
    super(`Falha simulada ao gerar conteúdo para o tópico "${topic}"`);
    this.name = "AIGenerationError";
  }
}

type RandomFn = () => number;

/**
 * Simula uma chamada a um LLM externo.
 *
 * - Aguarda 5 segundos.
 * - Falha em aproximadamente 20% das execuções.
 *
 * O parâmetro `random` existe apenas para facilitar testes unitários.
 * Em produção ele utiliza Math.random().
 */
export async function generateAIContent(
  topic: string,
  random: RandomFn = Math.random
): Promise<string> {
  await new Promise((resolve) => setTimeout(resolve, 5000));

  const shouldFail = random() < 0.2;

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