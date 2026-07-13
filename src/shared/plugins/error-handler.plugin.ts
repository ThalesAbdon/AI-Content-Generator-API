import fp from "fastify-plugin";
import type { FastifyError, FastifyPluginAsync } from "fastify";
import { ZodError } from "zod";
import { AppError } from "@/shared/errors/domain-errors";

export const errorHandlerPlugin: FastifyPluginAsync = fp(async (fastify) => {
  fastify.setErrorHandler((error: FastifyError | AppError | ZodError, request, reply) => {
    // Erros de negócio conhecidos (mapeados para o status code correto)
    if (error instanceof AppError) {
      return reply.status(error.statusCode).send({
        statusCode: error.statusCode,
        code: error.code,
        message: error.message,
      });
    }

    // Erros de validação do Zod (via fastify-type-provider-zod)
    if (error instanceof ZodError) {
      return reply.status(400).send({
        statusCode: 400,
        code: "VALIDATION_ERROR",
        message: "Dados de entrada inválidos.",
        issues: error.issues,
      });
    }

    // Erros de validação já formatados pelo fastify-type-provider-zod
    if (error.validation) {
      return reply.status(400).send({
        statusCode: 400,
        code: "VALIDATION_ERROR",
        message: error.message,
      });
    }

    // Qualquer outro erro: loga completo internamente, mas NUNCA
    // devolve stack trace ou detalhes internos para o cliente.
    request.log.error({ err: error }, "Erro interno não tratado");

    return reply.status(500).send({
      statusCode: 500,
      code: "INTERNAL_SERVER_ERROR",
      message: "Ocorreu um erro interno. Tente novamente mais tarde.",
    });
  });

  fastify.setNotFoundHandler((request, reply) => {
    return reply.status(404).send({
      statusCode: 404,
      code: "ROUTE_NOT_FOUND",
      message: `Rota ${request.method} ${request.url} não encontrada.`,
    });
  });
});

