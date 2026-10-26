-- lsp.lua — servidores de linguagem: autocompletar, erros em tempo real, ir para definição…
--   C#   Roslyn (o mesmo servidor do C# Dev Kit), via roslyn.nvim. Instale com :MasonInstall roslyn
--        Abra o nvim na pasta da solução (.sln/.slnx); com mais de uma, :Roslyn target escolhe.
--   C++  clangd (vem no pacote "clang" do Arch). Precisa saber como o projeto compila:
--        CMake  → cmake -B build -DCMAKE_EXPORT_COMPILE_COMMANDS=ON  (e um link para build/compile_commands.json)
--        Make   → bear -- make                                         (gera compile_commands.json)
--        Solto  → um compile_flags.txt na raiz, uma flag por linha (ex.: -std=c++23 e -Iinclude)

-- ---------- Mason (instalador) ----------
require("mason").setup({
    registries = {
        "github:mason-org/mason-registry",
        "github:Crashdummyy/mason-registry",   -- traz o "roslyn" na mesma versão do VS Code
    },
    ui = { border = "rounded" },
})

-- ---------- erros e avisos ----------
vim.diagnostic.config({
    severity_sort = true,
    virtual_text = { spacing = 2, prefix = "●" },
    float = { border = "rounded", source = true },
    underline = true,
    update_in_insert = false,
    signs = {
        text = {
            [vim.diagnostic.severity.ERROR] = "",
            [vim.diagnostic.severity.WARN] = "",
            [vim.diagnostic.severity.INFO] = "",
            [vim.diagnostic.severity.HINT] = "󰌵",
        },
    },
})

-- ---------- C# ----------
require("roslyn").setup({
    filewatching = "roslyn",     -- o Roslyn acompanha os arquivos (mais leve em soluções grandes)
    broad_search = true,         -- acha a solução mesmo abrindo um arquivo numa subpasta
})

vim.lsp.config("roslyn", {
    settings = {
        ["csharp|inlay_hints"] = {
            csharp_enable_inlay_hints_for_implicit_object_creation = true,
            csharp_enable_inlay_hints_for_implicit_variable_types = true,
            csharp_enable_inlay_hints_for_lambda_parameter_types = true,
            csharp_enable_inlay_hints_for_types = true,
            dotnet_enable_inlay_hints_for_parameters = true,
        },
        ["csharp|code_lens"] = {
            dotnet_enable_references_code_lens = true,
        },
        ["csharp|completion"] = {
            dotnet_show_completion_items_from_unimported_namespaces = true,   -- sugere e adiciona o "using"
            dotnet_show_name_completion_suggestions = true,
        },
        ["csharp|background_analysis"] = {
            dotnet_analyzer_diagnostics_scope = "openFiles",
            dotnet_compiler_diagnostics_scope = "fullSolution",               -- erros de compilação da solução toda
        },
    },
})

-- ---------- C/C++ ----------
vim.lsp.config("clangd", {
    cmd = {
        "clangd",
        "--background-index",              -- indexa o projeto todo em segundo plano
        "--clang-tidy",                    -- avisos extras de boas práticas
        "--header-insertion=iwyu",         -- adiciona #include ao completar
        "--completion-style=detailed",
        "--function-arg-placeholders",
        "--fallback-style=llvm",
    },
})
vim.lsp.enable("clangd")

-- ---------- atalhos (só nos buffers com servidor ativo) ----------
vim.api.nvim_create_autocmd("LspAttach", {
    callback = function(args)
        local buf = args.buf
        local fzf = require("fzf-lua")
        local map = function(keys, fn, desc, mode)
            vim.keymap.set(mode or "n", keys, fn, { buffer = buf, desc = desc })
        end

        map("gd", fzf.lsp_definitions, "Go to Definition")
        map("gD", vim.lsp.buf.declaration, "Go to Declaration")
        map("grr", fzf.lsp_references, "References")
        map("gri", fzf.lsp_implementations, "Implementations")
        map("gy", fzf.lsp_typedefs, "Type Definition")
        map("K", function() vim.lsp.buf.hover() end, "Hover Documentation")
        map("<C-k>", vim.lsp.buf.signature_help, "Signature Help", "i")

        map("<leader>r", vim.lsp.buf.rename, "Rename Symbol")
        map("<leader>a", vim.lsp.buf.code_action, "Code Actions", { "n", "x" })
        map("<leader>cf", function() vim.lsp.buf.format({ async = true }) end, "Format File")
        map("<leader>s", fzf.lsp_document_symbols, "Symbols in File")
        map("<leader>S", fzf.lsp_live_workspace_symbols, "Symbols in Project")
        map("<leader>ch", function()
            vim.lsp.inlay_hint.enable(not vim.lsp.inlay_hint.is_enabled({ bufnr = buf }), { bufnr = buf })
        end, "Toggle Inlay Hints")

        local client = vim.lsp.get_client_by_id(args.data.client_id)
        if client and client:supports_method("textDocument/documentHighlight") then
            -- destaca as outras ocorrências do símbolo sob o cursor
            local group = vim.api.nvim_create_augroup("lsp-highlight-" .. buf, { clear = true })
            vim.api.nvim_create_autocmd({ "CursorHold", "CursorHoldI" }, {
                group = group, buffer = buf, callback = vim.lsp.buf.document_highlight,
            })
            vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
                group = group, buffer = buf, callback = vim.lsp.buf.clear_references,
            })
        end
        if client and client.name == "clangd" then
            map("<leader>o", "<cmd>LspClangdSwitchSourceHeader<cr>", "Switch Header/Source")
        end
    end,
})
