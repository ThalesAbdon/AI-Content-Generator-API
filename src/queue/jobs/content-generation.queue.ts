import { Queue } from "bullmq";
import { createRedisConnection } from "@/config/redis";

export interface GenerateContentJobData {
  contentId: string;
  userId: string;
  topic: string;
}

export const CONTENT_QUEUE_NAME = "content-generation";

export const contentQueue = new Queue<GenerateContentJobData>(CONTENT_QUEUE_NAME, {
  connection: createRedisConnection(),
  defaultJobOptions: {
    attempts: 4,
    backoff: {
      type: "exponential",
      delay: 2000,
    },
    removeOnComplete: { age: 3600, count: 1000 },
    removeOnFail: { age: 86400 },
  },
});

