-- build.lua — compilar, rodar e testar sem sair do editor (C#/.NET e C++/CMake).
--
--   <leader>mb  Build   compila em segundo plano; os erros vão para a lista (Enter pula até eles)
--   <leader>mr  Run     roda o projeto num terminal embaixo
--   <leader>mt  Test    roda os testes num terminal embaixo
--   <leader>mc  Choose Executable  (C++: qual binário o Run executa)
--
-- O tipo de projeto vem da pasta do arquivo atual, subindo até achar:
--   .slnx/.sln/.csproj  → dotnet build / dotnet run --project / dotnet test
--   CMakeLists.txt      → cmake --build build/debug / o executável escolhido / ctest

local M = {}

local function find_up(pred)
    return vim.fs.root(0, function(name) return pred(name) end)
end

-- { kind, root, csproj? }
function M.project()
    local sln = find_up(function(n) return n:match("%.slnx?$") ~= nil end)
    local csproj = find_up(function(n) return n:match("%.csproj$") ~= nil end)
    if sln or csproj then
        return { kind = "dotnet", root = sln or csproj, csproj = csproj }
    end
    local cmake = vim.fs.root(0, "CMakeLists.txt")
    if cmake then
        -- o CMakeLists.txt mais de cima (projeto inteiro, não um subdiretório)
        local top = cmake
        local parent = vim.fs.dirname(top)
        while parent and parent ~= top and vim.uv.fs_stat(parent .. "/CMakeLists.txt") do
            top, parent = parent, vim.fs.dirname(parent)
        end
        return { kind = "cmake", root = top }
    end
    return nil
end

local efm = {
    dotnet = table.concat({
        "%f(%l\\,%c): %trror %m",
        "%f(%l\\,%c): %tarning %m",
        "%-G%.%#",
    }, ","),
    cmake = table.concat({
        "%f:%l:%c: %trror: %m",
        "%f:%l:%c: %tarning: %m",
        "%f:%l:%c: %m",
        "%-G%.%#",
    }, ","),
}

local running = nil

function M.build()
    local p = M.project()
    if not p then return vim.notify("No .NET or CMake project found above this file", vim.log.levels.WARN) end
    if running then return vim.notify("A build is already running", vim.log.levels.WARN) end
    vim.cmd("silent! wall")
    local cmd = p.kind == "dotnet"
        and { "dotnet", "build", "-nologo", "-clp:NoSummary;ForceNoAlign", "-v", "q" }
        or { "cmake", "--build", "build/debug", "--parallel" }
    local started = vim.uv.hrtime()
    vim.notify("Building " .. vim.fs.basename(p.root) .. "…")
    running = vim.system(cmd, { cwd = p.root, text = true }, function(res)
        running = nil
        vim.schedule(function()
            local lines = vim.split((res.stdout or "") .. "\n" .. (res.stderr or ""), "\n", { trimempty = true })
            -- o dotnet repete cada erro (por projeto); tira as linhas iguais
            local seen, uniq = {}, {}
            for _, l in ipairs(lines) do
                local key = l:gsub("%s*%[.-%]%s*$", "")
                if not seen[key] then seen[key] = true; table.insert(uniq, key) end
            end
            vim.fn.setqflist({}, " ", { title = "Build: " .. vim.fs.basename(p.root), lines = uniq, efm = efm[p.kind] })
            local errors, warnings = 0, 0
            for _, it in ipairs(vim.fn.getqflist()) do
                if it.valid == 1 then
                    if it.type == "e" then errors = errors + 1 elseif it.type == "w" then warnings = warnings + 1 end
                end
            end
            local secs = string.format("%.1fs", (vim.uv.hrtime() - started) / 1e9)
            if res.code == 0 then
                vim.notify(("Build succeeded in %s%s"):format(secs, warnings > 0 and (" · " .. warnings .. " warnings") or ""))
                if warnings == 0 then vim.cmd("cclose") end
            else
                vim.notify(("Build failed: %d errors, %d warnings (%s)"):format(errors, warnings, secs), vim.log.levels.ERROR)
                vim.cmd("botright copen 10")
            end
        end)
    end)
end

local function term(cmd, cwd)
    vim.cmd("botright 15split")
    vim.cmd.lcd(vim.fn.fnameescape(cwd))
    vim.cmd.terminal(cmd)
    vim.cmd.startinsert()
end

-- executável do C++ por projeto (lembrado durante a sessão)
local exes = {}

function M.choose_exe(p, after)
    p = p or M.project()
    if not p or p.kind ~= "cmake" then return end
    local found = vim.fs.find(function(name, path)
        local f = path .. "/" .. name
        local st = vim.uv.fs_stat(f)
        return st and st.type == "file" and vim.fn.executable(f) == 1
            and not path:match("CMakeFiles") and not name:match("%.so")
    end, { path = p.root .. "/build/debug", type = "file", limit = 50 })
    if #found == 0 then return vim.notify("No executables in build/debug yet — build first", vim.log.levels.WARN) end
    vim.ui.select(found, {
        prompt = "Executable to run",
        format_item = function(f) return f:sub(#p.root + 2) end,
    }, function(choice)
        if choice then exes[p.root] = choice; if after then after(choice) end end
    end)
end

function M.run()
    local p = M.project()
    if not p then return vim.notify("No .NET or CMake project found above this file", vim.log.levels.WARN) end
    if p.kind == "dotnet" then
        term("dotnet run --project " .. vim.fn.shellescape(p.csproj or p.root), p.root)
    elseif exes[p.root] then
        term(vim.fn.shellescape(exes[p.root]), p.root)
    else
        M.choose_exe(p, function(exe) term(vim.fn.shellescape(exe), p.root) end)
    end
end

function M.test()
    local p = M.project()
    if not p then return vim.notify("No .NET or CMake project found above this file", vim.log.levels.WARN) end
    if p.kind == "dotnet" then term("dotnet test", p.root)
    else term("ctest --test-dir build/debug --output-on-failure", p.root) end
end

local map = function(keys, fn, desc) vim.keymap.set("n", keys, fn, { desc = desc }) end
map("<leader>mb", M.build, "Build")
map("<leader>mr", M.run, "Run")
map("<leader>mt", M.test, "Test")
map("<leader>mc", function() M.choose_exe() end, "Choose Executable (C++)")

return M
