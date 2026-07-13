import { z } from "zod";

export const ContentStatusEnum = z.enum(["PENDING", "PROCESSING", "COMPLETED", "CANCELED", "FAILED"]);

export const generateContentBodySchema = z.object({
  topic: z.string().min(3, "topic deve ter ao menos 3 caracteres").max(500),
  userId: z.string().uuid("userId deve ser um UUID válido"),
});
export type GenerateContentBody = z.infer<typeof generateContentBodySchema>;

export const generateContentResponseSchema = z.object({
  contentId: z.string().uuid(),
  status: ContentStatusEnum,
});

export const contentParamsSchema = z.object({
  id: z.string().uuid("id deve ser um UUID válido"),
});
export type ContentParams = z.infer<typeof contentParamsSchema>;

export const contentResponseSchema = z.object({
  id: z.string().uuid(),
  userId: z.string().uuid(),
  topic: z.string(),
  status: ContentStatusEnum,
  resultUrl: z.string().nullable(),
  errorMessage: z.string().nullable(),
  createdAt: z.date(),
  updatedAt: z.date(),
});

export const cancelContentResponseSchema = z.object({
  id: z.string().uuid(),
  status: ContentStatusEnum,
});

export const errorResponseSchema = z.object({
  statusCode: z.number(),
  code: z.string(),
  message: z.string(),
});

