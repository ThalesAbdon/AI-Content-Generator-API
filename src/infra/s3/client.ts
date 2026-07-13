import { S3Client, PutObjectCommand } from "@aws-sdk/client-s3";
import { env } from "@/config/env";

export const s3Client = new S3Client({
  endpoint: env.S3_ENDPOINT,
  region: env.S3_REGION,
  forcePathStyle: env.S3_FORCE_PATH_STYLE,
  credentials: {
    accessKeyId: env.S3_ACCESS_KEY_ID,
    secretAccessKey: env.S3_SECRET_ACCESS_KEY,
  },
});

export interface UploadTextFileParams {
  key: string;
  content: string;
}

export async function uploadTextFile({ key, content }: UploadTextFileParams): Promise<string> {
  await s3Client.send(
    new PutObjectCommand({
      Bucket: env.S3_BUCKET,
      Key: key,
      Body: content,
      ContentType: "text/plain; charset=utf-8",
    })
  );

  // Monta a URL pública (path-style), válida tanto para Minio local quanto AWS S3 real
  return `${env.S3_ENDPOINT}/${env.S3_BUCKET}/${key}`;
}

