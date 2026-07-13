import { PrismaClient } from "@prisma/client";

const prisma = new PrismaClient();

async function main(): Promise<void> {
  const user = await prisma.user.upsert({
    where: { email: "teste@example.com" },
    update: {},
    create: {
      name: "Usuário de Teste",
      email: "teste@example.com",
      credits: 10,
    },
  });

  // eslint-disable-next-line no-console
  console.log("✅ Usuário de teste:", user);
}

main()
  .catch((error) => {
    // eslint-disable-next-line no-console
    console.error(error);
    process.exit(1);
  })
  .finally(async () => {
    await prisma.$disconnect();
  });

