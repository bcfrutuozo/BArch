-- ~/.config/hypr/hyprland.lua
-- Ponto de entrada: só carrega os módulos. Nenhuma config direta aqui.
-- Cada require() roda em escopo próprio: erro em um arquivo não derruba os outros.

require("conf.settings")   -- o que o app de configurações gravou (settings.json); aplicado no fim
require("conf.env")        -- variáveis de ambiente
require("conf.monitors")   -- saídas, HDR, VRR
require("conf.look")       -- gaps, layout, animações, misc
require("themes.current")  -- cores, bordas, sombra, blur (tema ativo)
require("conf.input")      -- teclado, mouse, gestos
require("conf.autostart")  -- processos iniciados com a sessão
require("conf.binds")      -- atalhos
require("conf.rules")      -- regras de janela, layer e workspace

-- Por cima de tudo: settings.json (Hyprland Settings, `barch hypr`), opções, binds, regras...
pcall(function() BArch.settings.apply("all") end)
