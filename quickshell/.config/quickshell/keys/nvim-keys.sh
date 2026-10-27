#!/usr/bin/env bash
# nvim-keys.sh — atalhos do Neovim (com descrição) em JSON, para a folha de atalhos (Super+/).
# Abre o Neovim sem tela com a sua config, lê os atalhos globais e sai.
# Os atalhos de LSP só existem com um arquivo aberto (são por buffer); a folha lista esses à parte.
command -v nvim >/dev/null || { echo '[]'; exit 0; }
out=$(timeout 15 nvim --headless -c 'lua
  local out = {}
  for _, m in ipairs({ "n", "x", "i", "t" }) do
    for _, k in ipairs(vim.api.nvim_get_keymap(m)) do
      if k.desc and k.desc ~= "" and not k.desc:match("^Nvim builtin") and not k.lhs:match("^<Plug>") then
        out[#out + 1] = { mode = m, lhs = k.lhs, desc = k.desc }
      end
    end
  end
  io.stdout:write("\n@@KEYS@@" .. vim.json.encode(out) .. "\n")' -c 'qa!' 2>/dev/null)
json=$(grep -o '@@KEYS@@.*' <<<"$out" | head -1)
echo "${json#@@KEYS@@}"
