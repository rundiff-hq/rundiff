import { Boxd, NotFoundError } from "@boxd-sh/sdk";

export function createBoxdClient() {
  const apiKey = process.env.BOXD_API_KEY;
  if (!apiKey) {
    throw new Error("BOXD_API_KEY is required");
  }

  return new Boxd({
    apiKey,
    timeout: 60_000,
    maxRetries: 1,
  });
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

export function errorMessage(error) {
  if (error instanceof Error) {
    return error.stack || error.message;
  }
  return String(error);
}

export async function executeRequest(boxd, request) {
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
      return {
        machine: {
          id: ready.id,
          name: ready.name,
          status: ready.status,
        },
      };
    }

    case "get": {
      const name = requireString(request.name, "name");
      try {
        const machine = await boxd.machines.get(name);
        return {
          machine: {
            id: machine.id,
            name: machine.name,
            status: machine.status,
          },
        };
      } catch (error) {
        if (error instanceof NotFoundError) {
          return { notFound: true };
        }
        throw error;
      }
    }

    case "fork": {
      const source = requireString(request.source, "source");
      const name = requireString(request.name, "name");
      const machine = await boxd.machines.fork(source, { name });
      const ready = await boxd.machines.waitUntilReady(machine.id, {
        timeout: 90_000,
        pollInterval: 250,
      });
      return {
        machine: {
          id: ready.id,
          name: ready.name,
          status: ready.status,
        },
      };
    }

    case "exec": {
      const machine = requireString(request.machine, "machine");
      const argv = requireArgv(request.argv);
      const result = await boxd.machines.exec(machine, {
        command: argv,
        timeout: 60_000,
      });
      return {
        stdout: result.stdout,
        stderr: result.stderr,
        exitCode: result.exitCode,
      };
    }

    case "remove": {
      const machine = requireString(request.machine, "machine");
      try {
        await boxd.machines.delete(machine);
      } catch (error) {
        if (!(error instanceof NotFoundError)) {
          throw error;
        }
      }
      return {};
    }

    default:
      throw new Error(`unsupported operation: ${request.operation}`);
  }
}
