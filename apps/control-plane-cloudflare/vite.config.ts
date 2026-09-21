import { cloudflare } from "@cloudflare/vite-plugin";
import react from "@vitejs/plugin-react";
import { defineConfig } from "vite";

export default defineConfig({
  plugins: [
    react(),
    cloudflare({
      config: (config) => ({
        ...config,
        assets: {
          ...config.assets,
          run_worker_first: true,
        },
      }),
    }),
  ],
});
