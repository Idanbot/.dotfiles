-- lua/plugins/mini-ai-safety.lua
return {
  {
    "nvim-mini/mini.ai",
    opts = function(_, opts)
      opts = opts or {}
      opts.silent = true
      opts.disable = function(buf)
        local bt = vim.bo[buf].buftype
        local ft = vim.bo[buf].filetype or ""
        return bt ~= "" or ft:match("^snacks_")
      end
      return opts
    end,
  },
}
