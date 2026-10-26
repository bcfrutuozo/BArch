-- theme.lua — cores do sistema.
-- A barra (Quickshell) gera lua/system_palette.lua com as paletas clara e escura (base16).
-- O Neovim descobre se o terminal está claro ou escuro (o foot avisa quando muda) e
-- aplica a paleta certa; ao trocar o modo do sistema, os nvim abertos trocam junto.

local function apply()
    package.loaded.system_palette = nil
    local ok, palettes = pcall(require, "system_palette")
    if not ok or type(palettes) ~= "table" then
        vim.cmd.colorscheme("default")     -- sem a paleta da barra: tema padrão do Neovim
        return
    end
    local palette = palettes[vim.o.background] or palettes.dark
    require("mini.base16").setup({ palette = palette, use_cterm = true })
    vim.g.colors_name = "system"
end

apply()

vim.api.nvim_create_autocmd("OptionSet", {
    pattern = "background",
    callback = function() vim.schedule(apply) end,
})

-- :ThemeReload — reaplica depois de trocar de paleta na barra
vim.api.nvim_create_user_command("ThemeReload", apply, {})
