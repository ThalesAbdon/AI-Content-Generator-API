export abstract class AppError extends Error {
  abstract readonly statusCode: number;
  abstract readonly code: string;

  constructor(message: string) {
    super(message);
    this.name = this.constructor.name;
  }
}

export class InsufficientCreditsError extends AppError {
  readonly statusCode = 402;
  readonly code = "INSUFFICIENT_CREDITS";

  constructor(userId: string) {
    super(`Usuário ${userId} não possui créditos suficientes para gerar conteúdo.`);
  }
}

export class ContentNotFoundError extends AppError {
  readonly statusCode = 404;
  readonly code = "CONTENT_NOT_FOUND";

  constructor(id: string) {
    super(`Conteúdo com id ${id} não foi encontrado.`);
  }
}

export class UserNotFoundError extends AppError {
  readonly statusCode = 404;
  readonly code = "USER_NOT_FOUND";

  constructor(id: string) {
    super(`Usuário com id ${id} não foi encontrado.`);
  }
}

export class InvalidContentStateError extends AppError {
  readonly statusCode = 409;
  readonly code = "INVALID_CONTENT_STATE";

  constructor(message: string) {
    super(message);
  }
}

