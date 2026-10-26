-- options.lua — opções do editor.

local o = vim.opt

o.number = true
o.relativenumber = true       -- números relativos: facilita "5j", "12dd" etc.
o.cursorline = true
o.signcolumn = "yes"          -- coluna fixa para erros e breakpoints (o texto não pula)
o.scrolloff = 8
o.sidescrolloff = 8
o.wrap = false

o.mouse = "a"
o.clipboard = "unnamedplus"   -- y/p usam o clipboard do sistema (o mesmo do Ctrl+C/Ctrl+V)

o.ignorecase = true           -- busca sem diferenciar maiúsculas...
o.smartcase = true            -- ...a menos que você digite uma maiúscula
o.inccommand = "split"        -- prévia ao vivo do :%s/…/…/

o.expandtab = true            -- espaços em vez de tab (padrão do C#)
o.shiftwidth = 4
o.tabstop = 4
o.smartindent = true

o.splitright = true
o.splitbelow = true

o.undofile = true             -- desfazer continua funcionando depois de fechar o arquivo
o.swapfile = false
o.updatetime = 250            -- erros e destaque do símbolo aparecem mais rápido
o.timeoutlen = 400

o.list = true
o.listchars = { tab = "» ", trail = "·", nbsp = "␣" }
o.fillchars = { eob = " " }   -- sem "~" depois do fim do arquivo

o.confirm = true              -- pergunta antes de fechar com alterações não salvas
o.winborder = "rounded"       -- bordas arredondadas nas janelas flutuantes (hover, assinatura…)

-- Avalonia: .axaml é XML
vim.filetype.add({ extension = { axaml = "xml", xaml = "xml" } })

-- destaca rapidamente o texto copiado
vim.api.nvim_create_autocmd("TextYankPost", {
    callback = function() vim.hl.on_yank({ timeout = 150 }) end,
})
