-- completion.lua — autocompletar (blink.cmp).
-- Teclas (estilo Visual Studio):
--   Tab          aceita a sugestão (ou pula para o próximo campo de um snippet)
--   ↑/↓ ou C-p/C-n  escolhe   ·   C-space  abre/mostra a documentação   ·   C-e  fecha
--   C-b/C-f      rola a documentação

require("blink.cmp").setup({
    keymap = { preset = "super-tab" },
    appearance = { nerd_font_variant = "mono" },
    completion = {
        documentation = { auto_show = true, auto_show_delay_ms = 300 },
        menu = { border = "rounded" },
        ghost_text = { enabled = true },    -- mostra o resto da sugestão em cinza na linha
    },
    signature = { enabled = true, window = { border = "rounded" } },  -- parâmetros ao digitar "("
    sources = { default = { "lsp", "path", "snippets", "buffer" } },
    fuzzy = { implementation = "prefer_rust_with_warning" },
})
