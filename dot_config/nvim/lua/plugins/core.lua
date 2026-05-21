return {
  {
    "LazyVim/LazyVim",
    opts = {
      colorscheme = "tokyonight",
    },
  },

  {
    "folke/tokyonight.nvim",
    lazy = false,
    priority = 1000,
    opts = {
      style = "night", -- "storm" | "moon" | "night" | "day"
      transparent = true, -- built-in transparency
      styles = {
        sidebars = "transparent",
        floats = "transparent",
      },
    },
  },

  {
    "szymonwilczek/vim-be-better",
    config = function()
      -- Optional: Enable logging for debugging
      vim.g.vim_be_better_log_file = 1
    end,
  },

  {
    "ThePrimeagen/refactoring.nvim",
    dependencies = {
      "lewis6991/async.nvim",
    },
  },
}
