import process from "node:process";
import { createBoxdClient, errorMessage, executeRequest } from "./operations.mjs";

async function readRequest() {
  let input = "";
  for await (const chunk of process.stdin) {
    input += chunk;
  }
  return JSON.parse(input);
}

function writeResponse(response) {
  process.stdout.write(JSON.stringify(response));
}

let boxd;
try {
  boxd = createBoxdClient();
  const request = await readRequest();
  writeResponse(await executeRequest(boxd, request));
} catch (error) {
  console.error(errorMessage(error));
  process.exitCode = 1;
} finally {
  if (boxd) {
    await boxd.close();
  }
}
