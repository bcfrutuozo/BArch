-- plugins.lua — plugins pelo gerenciador nativo do Neovim 0.12 (vim.pack).
--   Atualizar tudo:  :lua vim.pack.update()   (revise e confirme com :w; descarte com :q)
--   As versões instaladas ficam travadas em ~/.config/nvim/nvim-pack-lock.json (vale versionar no BArch).

local gh = function(repo) return "https://github.com/" .. repo end

-- Ações depois de instalar/atualizar (antes do vim.pack.add, para valer já na primeira instalação)
vim.api.nvim_create_autocmd("PackChanged", {
    callback = function(ev)
        local name, kind = ev.data.spec.name, ev.data.kind
        if name == "nvim-treesitter" and (kind == "install" or kind == "update") then
            if not ev.data.active then vim.cmd.packadd("nvim-treesitter") end
            vim.schedule(function() vim.cmd("TSUpdate") end)
        end
    end,
})

vim.pack.add({
    -- base
    gh("nvim-mini/mini.nvim"),            -- ícones, tema base16, barra de status, pares, objetos de texto
    gh("folke/which-key.nvim"),           -- mostra os atalhos disponíveis enquanto você digita
    gh("ibhagwan/fzf-lua"),               -- busca de arquivos, texto, símbolos
    gh("stevearc/oil.nvim"),              -- explorador de arquivos editável como texto
    gh("lewis6991/gitsigns.nvim"),        -- alterações do git na margem

    -- linguagem
    gh("nvim-treesitter/nvim-treesitter"),
    gh("neovim/nvim-lspconfig"),          -- configurações prontas (clangd e outros)
    gh("mason-org/mason.nvim"),           -- instala servidores e depuradores
    gh("seblyng/roslyn.nvim"),            -- C# com o servidor Roslyn (o do C# Dev Kit)
    { src = gh("saghen/blink.cmp"), version = vim.version.range("1.*") },  -- autocompletar (com binário pronto)

    -- depuração
    gh("mfussenegger/nvim-dap"),
    gh("nvim-neotest/nvim-nio"),
    gh("rcarriga/nvim-dap-ui"),
})

-- ---------- plugins pequenos ----------

require("mini.icons").setup()
MiniIcons.mock_nvim_web_devicons()        -- para plugins que esperam o nvim-web-devicons

require("mini.statusline").setup()
require("mini.pairs").setup()             -- fecha (), {}, "" automaticamente
require("mini.ai").setup()                -- objetos de texto extras: ia/aa (argumentos), if/af (funções)…
require("mini.surround").setup()          -- sa/sd/sr: adicionar/apagar/trocar (), "", tags…

require("which-key").setup({ preset = "modern", delay = 400 })

require("fzf-lua").setup({
    "default-title",
    winopts = { height = 0.85, width = 0.85, preview = { layout = "vertical", vertical = "down:55%" } },
    files = { cwd_prompt = false },
})
require("fzf-lua").register_ui_select()   -- menus do Neovim (ações de código etc.) também no fzf

require("oil").setup({
    default_file_explorer = true,         -- "nvim ." abre o oil
    view_options = { show_hidden = true },
    skip_confirm_for_simple_edits = true,
})

require("gitsigns").setup()
