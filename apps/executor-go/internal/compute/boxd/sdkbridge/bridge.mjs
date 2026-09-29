import process from "node:process";
import { Boxd, NotFoundError } from "@boxd-sh/sdk";

async function readRequest() {
  let input = "";
  for await (const chunk of process.stdin) {
    input += chunk;
  }
  return JSON.parse(input);
}

function requireString(value, name) {
  if (typeof value !== "string" || value.length === 0) {
    throw new Error(`${name} is required`);
  }
  return value;
}

function requireArgv(value) {
  if (!Array.isArray(value) || value.length === 0 || value.some((item) => typeof item !== "string")) {
    throw new Error("argv must be a non-empty string array");
  }
  return value;
}

function writeResponse(response) {
  process.stdout.write(JSON.stringify(response));
}

function errorMessage(error) {
  if (error instanceof Error) {
    return error.stack || error.message;
  }
  return String(error);
}

const apiKey = process.env.BOXD_API_KEY;
if (!apiKey) {
  console.error("BOXD_API_KEY is required");
  process.exit(2);
}

const boxd = new Boxd({
  apiKey,
  timeout: 60_000,
  maxRetries: 1,
});

try {
  const request = await readRequest();

  switch (request.operation) {
    case "create": {
      const name = requireString(request.name, "name");
      const machine = await boxd.machines.create({
        name,
        isolated: request.isolated === true,
      });
      const ready = await boxd.machines.waitUntilReady(machine.id, {
        timeout: 90_000,
        pollInterval: 250,
      });
      writeResponse({
        machine: {
          id: ready.id,
          name: ready.name,
          status: ready.status,
        },
      });
      break;
    }

    case "get": {
      const name = requireString(request.name, "name");
      try {
        const machine = await boxd.machines.get(name);
        writeResponse({
          machine: {
            id: machine.id,
            name: machine.name,
            status: machine.status,
          },
        });
      } catch (error) {
        if (error instanceof NotFoundError) {
          writeResponse({ notFound: true });
          break;
        }
        throw error;
      }
      break;
    }

    case "fork": {
      const source = requireString(request.source, "source");
      const name = requireString(request.name, "name");
      const machine = await boxd.machines.fork(source, { name });
      const ready = await boxd.machines.waitUntilReady(machine.id, {
        timeout: 90_000,
        pollInterval: 250,
      });
      writeResponse({
        machine: {
          id: ready.id,
          name: ready.name,
          status: ready.status,
        },
      });
      break;
    }

    case "exec": {
      const machine = requireString(request.machine, "machine");
      const argv = requireArgv(request.argv);
      const result = await boxd.machines.exec(machine, {
        command: argv,
        timeout: 60_000,
      });
      writeResponse({
        stdout: result.stdout,
        stderr: result.stderr,
        exitCode: result.exitCode,
      });
      break;
    }

    case "remove": {
      const machine = requireString(request.machine, "machine");
      await boxd.machines.delete(machine);
      writeResponse({});
      break;
    }

    default:
      throw new Error(`unsupported operation: ${request.operation}`);
  }
} catch (error) {
  console.error(errorMessage(error));
  process.exitCode = 1;
} finally {
  await boxd.close();
}
