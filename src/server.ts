import { buildApp } from "@/app";
import { env } from "@/config/env";

async function main(): Promise<void> {
  const app = await buildApp();

  try {
    await app.listen({ port: env.PORT, host: "0.0.0.0" });
    app.log.info(`📚 Docs disponíveis em http://localhost:${env.PORT}/docs`);
  } catch (error) {
    app.log.error(error);
    process.exit(1);
  }

  async function shutdown(): Promise<void> {
    app.log.info("Encerrando servidor graciosamente...");
    await app.close();
    process.exit(0);
  }

  process.on("SIGTERM", shutdown);
  process.on("SIGINT", shutdown);
}

main();

