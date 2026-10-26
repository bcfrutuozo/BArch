-- debug.lua — depuração com nvim-dap + painel (dap-ui). Atalhos no estilo Visual Studio:
--   F5 iniciar/continuar · Shift+F5 parar · Ctrl+Shift+F5 reiniciar
--   F9 breakpoint · Space+B breakpoint condicional
--   F10 passar por cima · F11 entrar · Shift+F11 sair
--   Space+du abre/fecha o painel · Space+de avalia a expressão sob o cursor
-- Instale os depuradores com:  :MasonInstall netcoredbg codelldb
--
--   C#   compila a solução (dotnet build) e roda o projeto executável (OutputType Exe/WinExe);
--        com mais de um, pergunta qual.
--   C++  pergunta qual executável rodar (compile com -g, ex.: cmake -DCMAKE_BUILD_TYPE=Debug).

local dap = require("dap")
local dapui = require("dapui")

local function mason_bin(name)
    return vim.fs.joinpath(vim.fn.stdpath("data"), "mason", "bin", name)
end

-- espera a escolha do usuário sem travar (as configs do dap rodam numa corrotina)
local function pick(items, prompt, label)
    if #items == 0 then return nil end
    if #items == 1 then return items[1] end
    return require("dap.ui").pick_one(items, prompt, label or tostring)
end

-- ---------- C# (netcoredbg) ----------
dap.adapters.coreclr = {
    type = "executable",
    command = mason_bin("netcoredbg"),
    args = { "--interpreter=vscode" },
}

local function dotnet_root()
    return vim.fs.root(0, function(name) return name:match("%.slnx?$") ~= nil end)
        or vim.fs.root(0, function(name) return name:match("%.csproj$") ~= nil end)
        or vim.fn.getcwd()
end

-- projetos executáveis da solução → caminho da dll de Debug
local function dotnet_programs(root)
    local out = {}
    for _, proj in ipairs(vim.fs.find(function(name) return name:match("%.csproj$") end,
        { path = root, type = "file", limit = math.huge })) do
        local text = table.concat(vim.fn.readfile(proj), "\n")
        if text:match("<OutputType>%s*W?i?n?Exe%s*</OutputType>") then
            local dir = vim.fs.dirname(proj)
            local asm = text:match("<AssemblyName>%s*(.-)%s*</AssemblyName>")
                or vim.fn.fnamemodify(proj, ":t:r")
            local dlls = vim.fn.glob(dir .. "/bin/Debug/*/" .. asm .. ".dll", false, true)
            table.sort(dlls)    -- se houver mais de um framework, fica com o mais novo
            if #dlls > 0 then table.insert(out, dlls[#dlls]) end
        end
    end
    return out
end

dap.configurations.cs = {
    {
        type = "coreclr",
        name = "Build and Debug",
        request = "launch",
        program = function()
            local root = dotnet_root()
            vim.notify("dotnet build…", vim.log.levels.INFO)
            local co = coroutine.running()
            vim.system({ "dotnet", "build", "-c", "Debug" }, { cwd = root, text = true }, function(res)
                vim.schedule(function() coroutine.resume(co, res) end)
            end)
            local res = coroutine.yield()
            if res.code ~= 0 then
                vim.notify("Build failed:\n" .. (res.stdout or ""):sub(-2000), vim.log.levels.ERROR)
                return dap.ABORT
            end
            local program = pick(dotnet_programs(root), "Project to debug: ",
                function(p) return vim.fn.fnamemodify(p, ":t:r") end)
            if not program then
                vim.notify("No executable project found (OutputType Exe/WinExe)", vim.log.levels.ERROR)
                return dap.ABORT
            end
            return program
        end,
        cwd = function() return dotnet_root() end,
        stopAtEntry = false,
    },
    {
        type = "coreclr",
        name = "Attach to Process",
        request = "attach",
        processId = require("dap.utils").pick_process,
    },
}

-- ---------- C/C++ (codelldb) ----------
dap.adapters.codelldb = {
    type = "server",
    port = "${port}",
    executable = { command = mason_bin("codelldb"), args = { "--port", "${port}" } },
}

dap.configurations.cpp = {
    {
        type = "codelldb",
        name = "Debug Executable",
        request = "launch",
        program = function() return require("dap.utils").pick_file({ executables = true }) end,
        args = function()
            local a = vim.fn.input("Arguments: ")
            return a ~= "" and vim.split(a, " ", { trimempty = true }) or {}
        end,
        cwd = "${workspaceFolder}",
        stopOnEntry = false,
    },
    {
        type = "codelldb",
        name = "Attach to Process",
        request = "attach",
        pid = require("dap.utils").pick_process,
    },
}
dap.configurations.c = dap.configurations.cpp

-- ---------- painel ----------
dapui.setup()
dap.listeners.after.event_initialized["dapui"] = function() dapui.open() end
dap.listeners.before.event_terminated["dapui"] = function() dapui.close() end
dap.listeners.before.event_exited["dapui"] = function() dapui.close() end

-- ícones na margem
vim.fn.sign_define("DapBreakpoint", { text = "●", texthl = "DiagnosticError" })
vim.fn.sign_define("DapBreakpointCondition", { text = "◆", texthl = "DiagnosticWarn" })
vim.fn.sign_define("DapBreakpointRejected", { text = "○", texthl = "DiagnosticHint" })
vim.fn.sign_define("DapStopped", { text = "▶", texthl = "DiagnosticOk", linehl = "Visual" })

-- ---------- atalhos ----------
local map = function(keys, fn, desc) vim.keymap.set("n", keys, fn, { desc = desc }) end
map("<F5>", dap.continue, "Debug: Start/Continue")
map("<S-F5>", dap.terminate, "Debug: Stop")
map("<C-S-F5>", dap.restart, "Debug: Restart")
map("<F9>", dap.toggle_breakpoint, "Debug: Toggle Breakpoint")
map("<F10>", dap.step_over, "Debug: Step Over")
map("<F11>", dap.step_into, "Debug: Step Into")
map("<S-F11>", dap.step_out, "Debug: Step Out")
map("<leader>B", function() dap.set_breakpoint(vim.fn.input("Condition: ")) end, "Debug: Conditional Breakpoint")
map("<leader>du", dapui.toggle, "Debug: Toggle Panel")
map("<leader>de", function() dapui.eval() end, "Debug: Evaluate")
