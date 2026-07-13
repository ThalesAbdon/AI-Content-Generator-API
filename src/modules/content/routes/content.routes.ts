import type { FastifyPluginAsync } from "fastify";
import type { ZodTypeProvider } from "fastify-type-provider-zod";
import { ContentService } from "@/modules/content/services/content.service";
import {
  generateContentBodySchema,
  generateContentResponseSchema,
  contentParamsSchema,
  contentResponseSchema,
  cancelContentResponseSchema,
  errorResponseSchema,
} from "@/modules/content/schemas/content.schemas";

const contentService = new ContentService();

export const contentRoutes: FastifyPluginAsync = async (fastify) => {
  const app = fastify.withTypeProvider<ZodTypeProvider>();

  app.post(
    "/api/content/generate",
    {
      schema: {
        description: "Solicita a geração de um novo conteúdo via IA (processado em background).",
        tags: ["content"],
        body: generateContentBodySchema,
        response: {
          201: generateContentResponseSchema,
          402: errorResponseSchema,
          404: errorResponseSchema,
        },
      },
    },
    async (request, reply) => {
      const result = await contentService.generate(request.body);
      return reply.status(201).send(result);
    }
  );

  app.get(
    "/api/content/:id",
    {
      schema: {
        description: "Consulta o status e o resultado de um conteúdo gerado.",
        tags: ["content"],
        params: contentParamsSchema,
        response: {
          200: contentResponseSchema,
          404: errorResponseSchema,
        },
      },
    },
    async (request) => {
      return contentService.findById(request.params.id);
    }
  );

  app.post(
    "/api/content/:id/cancel",
    {
      schema: {
        description: "Cancela a geração de um conteúdo em andamento (PENDING ou PROCESSING).",
        tags: ["content"],
        params: contentParamsSchema,
        response: {
          200: cancelContentResponseSchema,
          404: errorResponseSchema,
          409: errorResponseSchema,
        },
      },
    },
    async (request) => {
      return contentService.cancel(request.params.id);
    }
  );
};

