-- keymaps.lua — atalhos gerais (a tecla líder é o Espaço).
-- Aperte Espaço e espere: o which-key mostra tudo o que está disponível.

local map = function(mode, keys, fn, desc) vim.keymap.set(mode, keys, fn, { desc = desc }) end
local fzf = require("fzf-lua")

-- grupos no which-key
require("which-key").add({
    { "<leader>c", group = "Code" },
    { "<leader>d", group = "Debug" },
    { "<leader>g", group = "Git" },
    { "<leader>m", group = "Build" },
})

-- arquivos e busca
map("n", "<leader>f", fzf.files, "Find Files")
map("n", "<leader>/", fzf.live_grep, "Search Text in Project")
map("n", "<leader>*", fzf.grep_cword, "Search Word Under Cursor")
map("n", "<leader>b", fzf.buffers, "Open Buffers")
map("n", "<leader>h", fzf.oldfiles, "Recent Files")
map("n", "<leader>x", fzf.diagnostics_workspace, "Errors in Project")
map("n", "<leader>R", fzf.resume, "Resume Last Search")
map("n", "<leader>?", fzf.keymaps, "Search Keymaps")

-- explorador (oil): "-" abre a pasta do arquivo atual; dentro dele, Enter abre e "-" sobe
map("n", "-", "<cmd>Oil<cr>", "Open Parent Folder")

-- erros
map("n", "<leader>e", vim.diagnostic.open_float, "Show Error Under Cursor")

-- compilar: :make usa o compilador do tipo de arquivo; os erros vão para a lista (Enter pula até eles)
vim.api.nvim_create_autocmd("FileType", {
    pattern = "cs",
    callback = function() vim.cmd.compiler("dotnet") end,
})
map("n", "<leader>mb", "<cmd>make | copen<cr>", "Build")
map("n", "<leader>mr", function()
    vim.cmd("botright 15split | terminal dotnet run --project " .. vim.fn.shellescape(
        vim.fs.root(0, function(n) return n:match("%.csproj$") ~= nil end) or "."))
end, "Run (dotnet)")
map("n", "]q", "<cmd>cnext<cr>", "Next Error in List")
map("n", "[q", "<cmd>cprev<cr>", "Previous Error in List")

-- git
map("n", "<leader>gs", fzf.git_status, "Git Status")
map("n", "<leader>gb", "<cmd>Gitsigns blame_line<cr>", "Blame Line")
map("n", "<leader>gp", "<cmd>Gitsigns preview_hunk<cr>", "Preview Change")

-- janelas: Ctrl+h/j/k/l move entre divisões
map("n", "<C-h>", "<C-w>h", "Window Left")
map("n", "<C-j>", "<C-w>j", "Window Down")
map("n", "<C-k>", "<C-w>k", "Window Up")
map("n", "<C-l>", "<C-w>l", "Window Right")

-- terminal: Esc Esc volta ao modo normal
map("t", "<Esc><Esc>", "<C-\\><C-n>", "Exit Terminal Mode")

-- Esc também limpa o destaque da busca
map("n", "<Esc>", "<cmd>nohlsearch<cr>", "Clear Search Highlight")

-- salvar com Ctrl+S (em qualquer modo)
map({ "n", "i", "x" }, "<C-s>", "<cmd>write<cr><esc>", "Save File")
