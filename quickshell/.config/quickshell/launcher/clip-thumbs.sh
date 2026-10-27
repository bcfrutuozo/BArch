#!/usr/bin/env bash
# clip-thumbs.sh — miniaturas das imagens do histórico do clipboard (para o modo "c " do launcher).
# Decodifica cada imagem uma vez para <pasta>/<id>.<ext> e apaga as que saíram do histórico.
# Uso: clip-thumbs.sh <pasta>
dir="$1"; mkdir -p "$dir"
keep=" "
re='^\[\[ binary data .* (png|jpeg|jpg|bmp|webp|gif) '
while IFS= read -r line; do
  id=${line%%$'\t'*}; rest=${line#*$'\t'}
  [[ "$rest" =~ $re ]] || continue
  ext=${BASH_REMATCH[1]}; f="$dir/$id.$ext"; keep+="$id.$ext "
  [[ -s "$f" ]] || printf '%s' "$line" | cliphist decode > "$f" 2>/dev/null
done < <(cliphist list 2>/dev/null | head -n 300)
for f in "$dir"/*; do
  [[ -e "$f" ]] || continue
  [[ "$keep" == *" ${f##*/} "* ]] || rm -f "$f"
done
