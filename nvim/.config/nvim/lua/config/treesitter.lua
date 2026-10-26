-- treesitter.lua — destaque de sintaxe preciso (e indentação) pelo tree-sitter.
-- Precisa do tree-sitter-cli e de um compilador C (pacman: tree-sitter-cli, clang ou gcc).
-- Os parsers são instalados na primeira vez (em segundo plano); :TSUpdate atualiza.

local languages = {
    "c_sharp", "cpp", "c", "cmake", "make", "xml", "json", "yaml", "toml",
    "lua", "vim", "vimdoc", "bash", "markdown", "markdown_inline", "diff", "gitcommit",
}

local ok, ts = pcall(require, "nvim-treesitter")
if ok then ts.install(languages) end

vim.api.nvim_create_autocmd("FileType", {
    callback = function(args)
        -- só liga onde existe parser instalado
        if not pcall(vim.treesitter.start, args.buf) then return end
        vim.wo[0][0].foldexpr = "v:lua.vim.treesitter.foldexpr()"
        vim.wo[0][0].foldmethod = "expr"
        vim.wo[0][0].foldlevel = 99      -- abre tudo; zc/zo fecham e abrem blocos
        if ok then vim.bo[args.buf].indentexpr = "v:lua.require'nvim-treesitter'.indentexpr()" end
    end,
})
