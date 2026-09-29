import process from "node:process";
import readline from "node:readline";
import { createBoxdClient, errorMessage, executeRequest } from "./operations.mjs";

function writeEnvelope(envelope) {
  process.stdout.write(JSON.stringify(envelope) + "\n");
}

let boxd;
try {
  boxd = createBoxdClient();
  const input = readline.createInterface({
    input: process.stdin,
    crlfDelay: Infinity,
  });

  for await (const line of input) {
    if (line.trim().length === 0) {
      continue;
    }

    let envelope;
    try {
      envelope = JSON.parse(line);
      const response = await executeRequest(boxd, envelope.request);
      writeEnvelope({
        id: envelope.id,
        response,
      });
    } catch (error) {
      writeEnvelope({
        id: envelope?.id ?? null,
        error: errorMessage(error),
      });
    }
  }
} catch (error) {
  console.error(errorMessage(error));
  process.exitCode = 1;
} finally {
  if (boxd) {
    await boxd.close();
  }
}
