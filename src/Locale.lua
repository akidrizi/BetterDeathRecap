-- Locale.lua — all user-facing strings live here.
--
-- English (enUS) is the authoritative base — every key must be defined here.
-- All other locale tables are metatabled against L_enUS, so any key that has
-- not been translated yet falls back to English automatically. No nil errors,
-- no "must duplicate every key" rule.
--
-- Adding a new string: add it to L_enUS only. Other locales show English until
-- a translator provides an override.
--
-- Conventions:
--   %s / %d are substituted by the caller (string.format / :format()).
--   Strings here are plain text — colour escapes (|cff…|r) are applied in the
--   calling code, not stored in the locale, so translators never touch markup.
--   Brand text ("BetterDeathRecap") and the slash tokens (/bdr …) are not
--   translated; they are identifiers, not prose.

local _, BDR = ...

-- ---------------------------------------------------------------------------
-- English (enUS / default) — every key must be defined here
-- ---------------------------------------------------------------------------
local L_enUS = {
    -- Startup / chat
    WELCOME          = "v%s loaded.  /bdr to open, /bdr test for a demo.",
    CMD_HELP         = "Commands:  /bdr · /bdr test · /bdr history · /bdr lock · /bdr unlock",
    LOCKED           = "Window locked.",
    UNLOCKED         = "Window unlocked — drag to move.",
    NO_HISTORY       = "No saved death yet. Try /bdr test for a demo.",
    NO_DEATH         = "No death recorded yet. Use /bdr test for a demo.",

    -- On-death button (product name — left untranslated by design)
    BTN_RECAP        = "Better Recap",

    -- /bdr debug — developer diagnostics (English only)
    DEBUG_NO_API     = "C_DeathRecap API not found on this client.",
    DEBUG_API        = "API — GetRecapEvents: %s · HasRecapEvents: %s · GetRecapMaxHealth: %s",
    DEBUG_EVENTS     = "Most recent recap id: %s · damage events read: %d",
    DEBUG_HINT       = "If events = 0 right after a death, paste the 'First event fields' line so the parser can be tuned.",

    -- Window buttons / section headers
    BTN_LOCK         = "Lock",
    BTN_UNLOCK       = "Unlock",
    BTN_HISTORY      = "History",
    SCALE_LABEL      = "Scale",        -- title-bar slider label; value shown in the thumb chip
    TIMELINE_HEADER  = "Hit timeline",
    SOURCES_HEADER   = "Damage sources",

    -- HP graph
    GRAPH_LABEL      = "HP · last %ds",   -- %d = window length in seconds
    HP_HEADER        = "HEALTH TIMELINE • LAST %dS",  -- graph section header (all caps; %dS = window; • = brand dot)
    AXIS_DEATH       = "death",
    HP_UNAVAILABLE   = "HP graph unavailable here",
    GRAPH_HINT       = "scroll to zoom",   -- top-right hint on the graph

    -- Combat event table (columns: Time · Event · Source · Damage · Remaining HP)
    TBL_TIME         = "Time",
    TBL_EVENT        = "Event",
    TBL_SOURCE       = "Source",
    TBL_DAMAGE       = "Damage",
    TBL_REMAINING    = "Remaining Health",
    TYPE_HIT         = "Hit",      -- graph hover tooltip: a damage hit
    TYPE_HEAL        = "Heal",     -- graph hover tooltip: a heal
    SCROLL_MORE      = "Scroll for more",
    TOTAL_DAMAGE     = "Total Damage",
    SRC_EXPAND       = "Click to expand damage sources",    -- Total Damage hover (collapsed)
    SRC_COLLAPSE     = "Click to collapse damage sources",  -- Total Damage hover (expanded)

    -- Killing-blow banner
    KILLED_BY        = "KILLED BY",

    -- Timeline / banner
    KILLING_BLOW     = "KILLING BLOW",
    KB_BADGE         = "KB",
    MELEE            = "Melee",
    ABSORBED         = "absorbed %s",     -- %s = formatted amount
    BANNER_UNKNOWN   = "Killed. Source unknown.",
    OVERKILL         = "(%s overkill)",   -- %s = formatted amount
    INSTANT_KILL     = "(instant kill)",  -- killing blow was an instant-death effect
    MORE_HITS        = "%d more hits · click to expand",
    COLLAPSE         = "collapse",
    TOTAL            = "total: %s",       -- %s = formatted amount
    TIP_SOURCE       = "Source",       -- graph tooltip: who dealt the hit
    TIP_SCHOOL       = "School",       -- graph tooltip: damage school
    TIP_HP_CHANGE    = "% Max HP",     -- graph tooltip: HP delta as % of max
    TIP_HIT_PCT      = "Hit %",        -- graph tooltip: this hit as % of max HP
    -- Graph hover: minimal line (yellow). %.3f = seconds before death, %d = HP%.
    TIP_BEFORE_DEATH = "%.3f sec before death at %d%% health.",
    TIP_KB_AT        = "Killing blow at %d%% health.",   -- minimal line for the killing blow

    -- Table-row hover tooltip (Blizzard-style: damage / spell / HP / time)
    TIP_OVERKILL     = "(%s Overkill)",          -- %s = formatted overkill amount
    TIP_BY           = "%s by %s",               -- spell by source
    TIP_HP_REMAINING = "%d%% health remaining",  -- %d = remaining HP percent
    TIP_HP_KB        = "Killing blow at %d%% health",
    TIP_TIME_BEFORE  = "%.3fs before death",     -- %.3f = seconds before death (ms)

    -- Options panel + minimap button
    OPT_MINIMAP_ICON = "Minimap Icon",
    MINIMAP_LEFT     = "Left-click: open the recap",
    MINIMAP_RIGHT    = "Right-click: options",

    -- Footer
    FOOTER_WINDOW    = "%ds window",      -- %d = window length in seconds
    FOOTER_SAMPLE    = "(sample — /bdr)",
    FOOTER_HINT      = "/bdr",

    -- Empty / fallbacks
    EMPTY            = "No recap data for this death.",
    UNKNOWN          = "Unknown",

    -- Environmental death sources
    ENV_DROWNING     = "Drowning",
    ENV_FALLING      = "Falling",
    ENV_FATIGUE      = "Fatigue",
    ENV_FIRE         = "Fire",
    ENV_LAVA         = "Lava",
    ENV_SLIME        = "Slime",
    ENV_UNKNOWN      = "Environment",
}

-- ---------------------------------------------------------------------------
-- German (deDE)
-- ---------------------------------------------------------------------------
local L_deDE = setmetatable({
    WELCOME          = "v%s geladen.  /bdr zum Öffnen, /bdr test für eine Demo.",
    CMD_HELP         = "Befehle:  /bdr · /bdr test · /bdr history · /bdr lock · /bdr unlock",
    LOCKED           = "Fenster gesperrt.",
    UNLOCKED         = "Fenster entsperrt — zum Verschieben ziehen.",
    NO_HISTORY       = "Noch kein gespeicherter Tod. Probiere /bdr test für eine Demo.",
    NO_DEATH         = "Noch kein Tod aufgezeichnet. Nutze /bdr test für eine Demo.",
    BTN_LOCK         = "Sperren",
    BTN_UNLOCK       = "Entsperren",
    BTN_HISTORY      = "Verlauf",
    TIMELINE_HEADER  = "Trefferverlauf",
    SOURCES_HEADER   = "Schadensquellen",
    GRAPH_LABEL      = "HP · letzte %ds",
    AXIS_DEATH       = "Tod",
    HP_UNAVAILABLE   = "HP-Diagramm hier nicht verfügbar",
    KILLING_BLOW     = "TÖDLICHER TREFFER",
    MELEE            = "Nahkampf",
    ABSORBED         = "%s absorbiert",
    BANNER_UNKNOWN   = "Getötet. Quelle unbekannt.",
    OVERKILL         = "(%s Overkill)",
    FOOTER_WINDOW    = "%ds Fenster",
    FOOTER_SAMPLE    = "(Beispiel — /bdr)",
    EMPTY            = "Keine Recap-Daten für diesen Tod.",
    UNKNOWN          = "Unbekannt",
    ENV_DROWNING     = "Ertrinken",
    ENV_FALLING      = "Sturz",
    ENV_FATIGUE      = "Erschöpfung",
    ENV_FIRE         = "Feuer",
    ENV_LAVA         = "Lava",
    ENV_SLIME        = "Schleim",
    ENV_UNKNOWN      = "Umgebung",
}, { __index = L_enUS })

-- ---------------------------------------------------------------------------
-- French (frFR)
-- ---------------------------------------------------------------------------
local L_frFR = setmetatable({
    WELCOME          = "v%s chargé.  /bdr pour ouvrir, /bdr test pour une démo.",
    CMD_HELP         = "Commandes :  /bdr · /bdr test · /bdr history · /bdr lock · /bdr unlock",
    LOCKED           = "Fenêtre verrouillée.",
    UNLOCKED         = "Fenêtre déverrouillée — glissez pour déplacer.",
    NO_HISTORY       = "Aucune mort enregistrée. Essayez /bdr test pour une démo.",
    NO_DEATH         = "Aucune mort enregistrée pour l'instant. Utilisez /bdr test pour une démo.",
    BTN_LOCK         = "Verrouiller",
    BTN_UNLOCK       = "Déverrouiller",
    BTN_HISTORY      = "Historique",
    TIMELINE_HEADER  = "Chronologie des coups",
    SOURCES_HEADER   = "Sources de dégâts",
    GRAPH_LABEL      = "PV · dernières %ds",
    AXIS_DEATH       = "mort",
    HP_UNAVAILABLE   = "Graphique de PV indisponible ici",
    KILLING_BLOW     = "COUP FATAL",
    MELEE            = "Corps à corps",
    ABSORBED         = "%s absorbé",
    BANNER_UNKNOWN   = "Tué. Source inconnue.",
    OVERKILL         = "(%s de surplus)",
    FOOTER_WINDOW    = "fenêtre de %ds",
    FOOTER_SAMPLE    = "(exemple — /bdr)",
    EMPTY            = "Aucune donnée de récap pour cette mort.",
    UNKNOWN          = "Inconnu",
    ENV_DROWNING     = "Noyade",
    ENV_FALLING      = "Chute",
    ENV_FATIGUE      = "Fatigue",
    ENV_FIRE         = "Feu",
    ENV_LAVA         = "Lave",
    ENV_SLIME        = "Vase",
    ENV_UNKNOWN      = "Environnement",
}, { __index = L_enUS })

-- ---------------------------------------------------------------------------
-- Spanish (esES / esMX)
-- ---------------------------------------------------------------------------
local L_esES = setmetatable({
    WELCOME          = "v%s cargado.  /bdr para abrir, /bdr test para una demo.",
    CMD_HELP         = "Comandos:  /bdr · /bdr test · /bdr history · /bdr lock · /bdr unlock",
    LOCKED           = "Ventana bloqueada.",
    UNLOCKED         = "Ventana desbloqueada — arrastra para mover.",
    NO_HISTORY       = "Aún no hay ninguna muerte guardada. Prueba /bdr test para una demo.",
    NO_DEATH         = "Aún no se ha registrado ninguna muerte. Usa /bdr test para una demo.",
    BTN_LOCK         = "Bloquear",
    BTN_UNLOCK       = "Desbloquear",
    BTN_HISTORY      = "Historial",
    TIMELINE_HEADER  = "Cronología de golpes",
    SOURCES_HEADER   = "Fuentes de daño",
    GRAPH_LABEL      = "PV · últimos %ds",
    AXIS_DEATH       = "muerte",
    HP_UNAVAILABLE   = "Gráfico de PV no disponible aquí",
    KILLING_BLOW     = "GOLPE MORTAL",
    MELEE            = "Cuerpo a cuerpo",
    ABSORBED         = "%s absorbido",
    BANNER_UNKNOWN   = "Muerto. Origen desconocido.",
    OVERKILL         = "(%s de exceso)",
    FOOTER_WINDOW    = "ventana de %ds",
    FOOTER_SAMPLE    = "(ejemplo — /bdr)",
    EMPTY            = "No hay datos de resumen para esta muerte.",
    UNKNOWN          = "Desconocido",
    ENV_DROWNING     = "Ahogamiento",
    ENV_FALLING      = "Caída",
    ENV_FATIGUE      = "Fatiga",
    ENV_FIRE         = "Fuego",
    ENV_LAVA         = "Lava",
    ENV_SLIME        = "Cieno",
    ENV_UNKNOWN      = "Entorno",
}, { __index = L_enUS })

-- ---------------------------------------------------------------------------
-- Russian (ruRU)
-- ---------------------------------------------------------------------------
local L_ruRU = setmetatable({
    WELCOME          = "v%s загружен.  /bdr — открыть, /bdr test — демо.",
    CMD_HELP         = "Команды:  /bdr · /bdr test · /bdr history · /bdr lock · /bdr unlock",
    LOCKED           = "Окно закреплено.",
    UNLOCKED         = "Окно откреплено — перетащите, чтобы переместить.",
    NO_HISTORY       = "Пока нет сохранённой смерти. Попробуйте /bdr test для демо.",
    NO_DEATH         = "Смерть ещё не записана. Используйте /bdr test для демо.",
    BTN_LOCK         = "Закрепить",
    BTN_UNLOCK       = "Открепить",
    BTN_HISTORY      = "История",
    TIMELINE_HEADER  = "Хронология ударов",
    SOURCES_HEADER   = "Источники урона",
    GRAPH_LABEL      = "HP · последние %ds",
    AXIS_DEATH       = "смерть",
    HP_UNAVAILABLE   = "График здоровья здесь недоступен",
    KILLING_BLOW     = "СМЕРТЕЛЬНЫЙ УДАР",
    MELEE            = "Ближний бой",
    ABSORBED         = "поглощено %s",
    BANNER_UNKNOWN   = "Убит. Источник неизвестен.",
    OVERKILL         = "(%s избыточно)",
    FOOTER_WINDOW    = "окно %ds",
    FOOTER_SAMPLE    = "(пример — /bdr)",
    EMPTY            = "Нет данных о гибели для этой смерти.",
    UNKNOWN          = "Неизвестно",
    ENV_DROWNING     = "Утопление",
    ENV_FALLING      = "Падение",
    ENV_FATIGUE      = "Усталость",
    ENV_FIRE         = "Огонь",
    ENV_LAVA         = "Лава",
    ENV_SLIME        = "Слизь",
    ENV_UNKNOWN      = "Окружение",
}, { __index = L_enUS })

-- ---------------------------------------------------------------------------
-- Portuguese Brazil (ptBR)
-- ---------------------------------------------------------------------------
local L_ptBR = setmetatable({
    WELCOME          = "v%s carregado.  /bdr para abrir, /bdr test para uma demo.",
    CMD_HELP         = "Comandos:  /bdr · /bdr test · /bdr history · /bdr lock · /bdr unlock",
    LOCKED           = "Janela bloqueada.",
    UNLOCKED         = "Janela desbloqueada — arraste para mover.",
    NO_HISTORY       = "Ainda não há morte salva. Tente /bdr test para uma demo.",
    NO_DEATH         = "Nenhuma morte registrada ainda. Use /bdr test para uma demo.",
    BTN_LOCK         = "Bloquear",
    BTN_UNLOCK       = "Desbloquear",
    BTN_HISTORY      = "Histórico",
    TIMELINE_HEADER  = "Linha do tempo dos golpes",
    SOURCES_HEADER   = "Fontes de dano",
    GRAPH_LABEL      = "PV · últimos %ds",
    AXIS_DEATH       = "morte",
    HP_UNAVAILABLE   = "Gráfico de PV indisponível aqui",
    KILLING_BLOW     = "GOLPE FATAL",
    MELEE            = "Corpo a corpo",
    ABSORBED         = "%s absorvido",
    BANNER_UNKNOWN   = "Morto. Origem desconhecida.",
    OVERKILL         = "(%s de excesso)",
    FOOTER_WINDOW    = "janela de %ds",
    FOOTER_SAMPLE    = "(exemplo — /bdr)",
    EMPTY            = "Sem dados de resumo para esta morte.",
    UNKNOWN          = "Desconhecido",
    ENV_DROWNING     = "Afogamento",
    ENV_FALLING      = "Queda",
    ENV_FATIGUE      = "Fadiga",
    ENV_FIRE         = "Fogo",
    ENV_LAVA         = "Lava",
    ENV_SLIME        = "Limo",
    ENV_UNKNOWN      = "Ambiente",
}, { __index = L_enUS })

-- ---------------------------------------------------------------------------
-- Italian (itIT)
-- ---------------------------------------------------------------------------
local L_itIT = setmetatable({
    WELCOME          = "v%s caricato.  /bdr per aprire, /bdr test per una demo.",
    CMD_HELP         = "Comandi:  /bdr · /bdr test · /bdr history · /bdr lock · /bdr unlock",
    LOCKED           = "Finestra bloccata.",
    UNLOCKED         = "Finestra sbloccata — trascina per spostare.",
    NO_HISTORY       = "Nessuna morte salvata. Prova /bdr test per una demo.",
    NO_DEATH         = "Nessuna morte registrata. Usa /bdr test per una demo.",
    BTN_LOCK         = "Blocca",
    BTN_UNLOCK       = "Sblocca",
    BTN_HISTORY      = "Cronologia",
    TIMELINE_HEADER  = "Cronologia dei colpi",
    SOURCES_HEADER   = "Fonti di danno",
    GRAPH_LABEL      = "PV · ultimi %ds",
    AXIS_DEATH       = "morte",
    HP_UNAVAILABLE   = "Grafico PV non disponibile qui",
    KILLING_BLOW     = "COLPO FATALE",
    MELEE            = "Corpo a corpo",
    ABSORBED         = "%s assorbito",
    BANNER_UNKNOWN   = "Ucciso. Fonte sconosciuta.",
    OVERKILL         = "(%s in eccesso)",
    FOOTER_WINDOW    = "finestra di %ds",
    FOOTER_SAMPLE    = "(esempio — /bdr)",
    EMPTY            = "Nessun dato di riepilogo per questa morte.",
    UNKNOWN          = "Sconosciuto",
    ENV_DROWNING     = "Annegamento",
    ENV_FALLING      = "Caduta",
    ENV_FATIGUE      = "Affaticamento",
    ENV_FIRE         = "Fuoco",
    ENV_LAVA         = "Lava",
    ENV_SLIME        = "Melma",
    ENV_UNKNOWN      = "Ambiente",
}, { __index = L_enUS })

-- ---------------------------------------------------------------------------
-- Route to the correct locale table; fall back to English.
-- ---------------------------------------------------------------------------
local locale = GetLocale()
if     locale == "deDE" then BDR.L = L_deDE
elseif locale == "frFR" then BDR.L = L_frFR
elseif locale == "esES" then BDR.L = L_esES
elseif locale == "esMX" then BDR.L = L_esES
elseif locale == "ruRU" then BDR.L = L_ruRU
elseif locale == "ptBR" then BDR.L = L_ptBR
elseif locale == "itIT" then BDR.L = L_itIT
else                         BDR.L = L_enUS
end
