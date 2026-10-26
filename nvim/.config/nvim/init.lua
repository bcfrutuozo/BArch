-- init.lua — ponto de entrada do Neovim (0.12+).
-- Cada assunto fica num arquivo em lua/config/:
--   options     opções do editor
--   plugins     lista de plugins (gerenciador nativo vim.pack) e plugins pequenos
--   theme       cores do sistema (geradas pela barra) com troca claro/escuro automática
--   treesitter  destaque de sintaxe
--   lsp         servidores de linguagem: C# (Roslyn) e C/C++ (clangd)
--   completion  autocompletar (blink.cmp)
--   debug       depuração: C# (netcoredbg) e C/C++ (codelldb)
--   keymaps     atalhos gerais
-- Os atalhos de LSP ficam em lsp.lua e os de depuração em debug.lua.

vim.g.mapleader = " "
vim.g.maplocalleader = " "

require("config.options")
require("config.plugins")
require("config.theme")
require("config.treesitter")
require("config.lsp")
require("config.completion")
require("config.debug")
require("config.keymaps")
