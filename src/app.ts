import Fastify, { type FastifyInstance } from "fastify";
import cors from "@fastify/cors";
import swagger from "@fastify/swagger";
import swaggerUi from "@fastify/swagger-ui";
import {
  serializerCompiler,
  validatorCompiler,
  jsonSchemaTransform,
  type ZodTypeProvider,
} from "fastify-type-provider-zod";
import { errorHandlerPlugin } from "@/shared/plugins/error-handler.plugin";
import { contentRoutes } from "@/modules/content/routes/content.routes";

export async function buildApp(): Promise<FastifyInstance> {
  const app = Fastify({
    logger: {
      transport:
        process.env.NODE_ENV === "development"
          ? { target: "pino-pretty", options: { colorize: true } }
          : undefined,
    },
  }).withTypeProvider<ZodTypeProvider>();

  app.setValidatorCompiler(validatorCompiler);
  app.setSerializerCompiler(serializerCompiler);

  await app.register(cors, { origin: true });

  await app.register(swagger, {
    openapi: {
      info: {
        title: "AI Content Generator API",
        description: "Desafio Técnico Backend Sênior — geração de conteúdo via IA em background.",
        version: "1.0.0",
      },
      tags: [{ name: "content", description: "Geração e consulta de conteúdo" }],
    },
    transform: jsonSchemaTransform,
  });

  await app.register(swaggerUi, {
    routePrefix: "/docs",
  });

  await app.register(errorHandlerPlugin);

  app.get("/health", async () => ({ status: "ok" }));

  await app.register(contentRoutes);

  return app;
}

