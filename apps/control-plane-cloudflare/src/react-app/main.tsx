import { StrictMode } from "react";
import { createRoot } from "react-dom/client";

import { App } from "./App";

async function bootstrap() {
  if (window.location.pathname !== "/") {
    await import("./styles.css");
  }

  createRoot(document.getElementById("root")!).render(
    <StrictMode>
      <App />
    </StrictMode>,
  );
}

void bootstrap();
