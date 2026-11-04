"""Language names (Radarr/Sonarr) and the ISO 639-2 codes a track may carry, B and T forms both."""
from __future__ import annotations

ISO = {"English": {"eng"}, "Portuguese": {"por"}, "Portuguese (Brazil)": {"por"}, "German": {"ger", "deu"},
       "French": {"fre", "fra"}, "Spanish": {"spa"}, "Spanish (Latino)": {"spa"}, "Italian": {"ita"},
       "Japanese": {"jpn"}, "Korean": {"kor"}, "Chinese": {"chi", "zho"}, "Russian": {"rus"},
       "Swedish": {"swe"}, "Danish": {"dan"}, "Norwegian": {"nor", "nob"}, "Dutch": {"dut", "nld"},
       "Hindi": {"hin"}, "Polish": {"pol"}, "Turkish": {"tur"}, "Arabic": {"ara"}, "Finnish": {"fin"},
       "Greek": {"gre", "ell"}, "Hebrew": {"heb"}, "Czech": {"cze", "ces"}, "Thai": {"tha"},
       "Icelandic": {"ice", "isl"}, "Hungarian": {"hun"}, "Romanian": {"rum", "ron"}, "Ukrainian": {"ukr"},
       "Vietnamese": {"vie"}, "Indonesian": {"ind"}, "Tamil": {"tam"}, "Telugu": {"tel"}, "Persian": {"per", "fas"}}


def codes(name: str) -> set[str]:
    """The codes of a Radarr language name; empty when unknown (the caller decides what that means)."""
    return set(ISO.get(name or "", set()))
