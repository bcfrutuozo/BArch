#!/usr/bin/env bash
# weather.sh — clima atual e previsão pelo Open-Meteo (gratuito, sem chave), em JSON para o WeatherWidget.
# Uso: weather.sh "Cidade" [código do país]       ex.: weather.sh "Tatuí" BR
# As coordenadas da cidade são buscadas uma vez e guardadas em ~/.cache/quickshell/weather-location.json.
# Depende de: curl, jq.

city="${1:-Tatuí}"
country="${2:-BR}"
cache="${XDG_CACHE_HOME:-$HOME/.cache}/quickshell"
loc="$cache/weather-location.json"
mkdir -p "$cache"

fail() { jq -n --arg e "$1" '{error: $e}'; exit 0; }

# ---- coordenadas (cache) ----
if [[ ! -s "$loc" ]] || [[ "$(jq -r '.query' "$loc" 2>/dev/null)" != "$city|$country" ]]; then
  geo=$(curl -fsS --max-time 10 -G "https://geocoding-api.open-meteo.com/v1/search" \
          --data-urlencode "name=$city" -d count=1 -d language=en -d format=json \
          ${country:+-d countryCode="$country"}) || fail "No connection"
  jq -e '.results[0]' <<<"$geo" >/dev/null 2>&1 || fail "City not found: $city"
  jq --arg q "$city|$country" '.results[0] | {query: $q, name, admin1, lat: .latitude, lon: .longitude}' \
     <<<"$geo" > "$loc"
fi

lat=$(jq -r .lat "$loc"); lon=$(jq -r .lon "$loc")

# ---- previsão ----
data=$(curl -fsS --max-time 15 -G "https://api.open-meteo.com/v1/forecast" \
  -d latitude="$lat" -d longitude="$lon" -d timezone=auto \
  -d current=temperature_2m,apparent_temperature,relative_humidity_2m,weather_code,is_day,wind_speed_10m \
  -d hourly=temperature_2m,weather_code,precipitation_probability,is_day \
  -d daily=weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max,sunrise,sunset \
  -d forecast_days=6 -d forecast_hours=13) || fail "No connection"

jq --slurpfile place "$loc" '{
  place: ($place[0].name + (if $place[0].admin1 then ", " + $place[0].admin1 else "" end)),
  current: {
    temp: .current.temperature_2m,
    feels: .current.apparent_temperature,
    humidity: .current.relative_humidity_2m,
    wind: .current.wind_speed_10m,
    code: .current.weather_code,
    day: (.current.is_day == 1)
  },
  hourly: [range(0; (.hourly.time | length)) as $i | {
    time: .hourly.time[$i], temp: .hourly.temperature_2m[$i], code: .hourly.weather_code[$i],
    rain: .hourly.precipitation_probability[$i], day: (.hourly.is_day[$i] == 1)
  }],
  daily: [range(0; (.daily.time | length)) as $i | {
    date: .daily.time[$i], code: .daily.weather_code[$i],
    max: .daily.temperature_2m_max[$i], min: .daily.temperature_2m_min[$i],
    rain: .daily.precipitation_probability_max[$i],
    sunrise: .daily.sunrise[$i], sunset: .daily.sunset[$i]
  }]
}' <<<"$data" 2>/dev/null || fail "Unexpected response"
