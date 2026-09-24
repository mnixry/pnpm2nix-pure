module.exports = {
  hooks: {
    updateConfig(config) {
      if (process.env.PNPM2NIX_PLUGIN_MARKER) {
        require("node:fs").writeFileSync(process.env.PNPM2NIX_PLUGIN_MARKER, "plugin executed\n");
      }
      return config;
    },
  },
};
