"""Research task family for the real memory-on/off evaluation.

Two synthetic research projects.  Each task's workspace holds the original
source excerpts the researcher collected (``sources/``).  Prior-session memory
holds the analysis: adopted values for conflicting sources, a later
correction (supersession), a retraction (via ``llm-brain retract``), a
decision and an open intention.  Answers are written to ``answer.json`` and
graded deterministically; no model is involved in grading.
"""

KESTREL_SOURCES = {
    "sources/KB-S01.md": "# KB-S01: Independent cell lab report (Tallis Test Lab, 2025)\n\nSource ID: KB-S01\n\nLFP cells (32 Ah) retained 71% of rated capacity at -20 C after a 4 h soak (n=12 cells).\nLTO cells retained 89% of rated capacity under the same protocol (n=12 cells).\n",
    "sources/KB-S02.md": "# KB-S02: Vendor datasheet (Corvane Energy, LFP-32 series)\n\nSource ID: KB-S02\n\nThe datasheet states 85% capacity retention at -20 C for the LFP-32 cell. The test method is not described.\n",
    "sources/KB-S03.md": "# KB-S03: Kestrel pilot interim field report (2025-09)\n\nSource ID: KB-S03\n\nSix pilot buoys fitted with LTO packs operated for 14 months without a pack failure.\n",
    "sources/KB-S04.md": "# KB-S04: Journal article (Ostrova et al., 2025)\n\nSource ID: KB-S04\n\nSodium-ion pouch cells retained 88% of rated capacity at -20 C.\n",
    "sources/KB-S05.md": "# KB-S05: Pack cost survey 2025\n\nSource ID: KB-S05\n\nMedian pack cost per kWh: LFP 132 USD, LTO 410 USD, sodium-ion 118 USD.\n",
    "sources/KB-S06.md": "# KB-S06: Mooring enclosure engineering note\n\nSource ID: KB-S06\n\nThe buoy enclosure keeps the cells above -12 C in 90% of winter hours.\n",
    "README.md": "# Kestrel buoy power study\n\nCollected source excerpts are in sources/. Each file carries its source ID.\n",
}
KESTREL_ALLOWED = ["KB-S01", "KB-S02", "KB-S03", "KB-S04", "KB-S05", "KB-S06", "KB-S09", "KB-S10"]
KESTREL_MEMORY = [
    {"id": "kb-lfp-cold", "title": "LFP cold retention value adopted", "text": "LFP cold retention: the model uses 71% at -20 C from the independent lab report KB-S01. The vendor claim of 85% (KB-S02) conflicts and is not adopted: method undisclosed and not independent."},
    {"id": "kb-naion-88", "title": "Sodium-ion cold retention", "text": "Sodium-ion cells retain 88% capacity at -20 C (KB-S04).", "retract": "Source KB-S04 retracted by the journal (KB-S09)."},
    {"id": "kb-naion-retraction", "title": "KB-S04 sodium-ion paper retracted", "text": "KB-S04 (Ostrova et al.) was retracted by the journal on 2026-02-11; retraction notice KB-S09 cites duplicated images in the cold-test figures. There is no reliable sodium-ion cold-retention figure in our evidence."},
    {"id": "kb-lto-field-14", "title": "LTO pilot field duration", "text": "LTO pilot buoys ran 14 months without pack failure (KB-S03).", "observed_at": "2025-09-30T00:00:00Z"},
    {"id": "kb-lto-field-11", "title": "LTO pilot field duration (corrected)", "text": "Correction: pilot erratum KB-S10 (2026-01) corrects KB-S03. The LTO pilot buoys ran 11 months, not 14; the interim report double-counted the bench period.", "supersedes": "kb-lto-field-14", "observed_at": "2026-01-20T00:00:00Z"},
    {"id": "kb-decision-lto", "title": "Working chemistry recommendation", "text": "Working recommendation after the 2026-03 PI review: LTO for the Kestrel deployment because of its cold retention (89% in KB-S01) and cycle life, despite roughly 3x the LFP pack cost (KB-S05)."},
    {"id": "kb-enclosure", "title": "Enclosure temperature context", "text": "The enclosure keeps cells above -12 C most of the winter (KB-S06), so -20 C retention figures are a worst case."},
    {"id": "kb-stale-lto-quote", "title": "LTO supplier quote", "text": "A 2024 supplier email quoted LTO packs at 520 USD per kWh.", "observed_at": "2024-06-01T00:00:00Z"},
]
KESTREL_INTENTIONS = [
    {"action": "Any recommendation brief must list open question Q-03: the LTO supplier lead time is unconfirmed (quote pending).", "trigger": "keyword:brief"},
    {"action": "Any chemistry recommendation must list open question Q-03: the LTO supplier lead time is unconfirmed (quote pending).", "trigger": "keyword:recommendation"},
]

MARLOW_SOURCES = {
    "sources/MF-S01.md": "# MF-S01: Seine-net survey 2022 (Marlow Estuary Trust)\n\nSource ID: MF-S01\n\n1,240 juvenile bream were counted across 8 sites.\n",
    "sources/MF-S02.md": "# MF-S02: Seine-net survey 2024 (Marlow Estuary Trust)\n\nSource ID: MF-S02\n\n1,610 juvenile bream were counted across 8 sites. The crew also recorded 310 silver mullet.\n",
    "sources/MF-S03.md": "# MF-S03: Salinity logger dataset 2023-2025 (logger ML-2)\n\nSource ID: MF-S03\n\nMean salinity fell from 31.2 PSU (2023) to 27.4 PSU (2025).\n",
    "sources/MF-S04.md": "# MF-S04: Citizen-science app counts 2024\n\nSource ID: MF-S04\n\nApp users logged 4,900 bream sightings in 2024. Entries are unverified and may include duplicates.\n",
    "sources/MF-S05.md": "# MF-S05: Dredging permit record\n\nSource ID: MF-S05\n\nChannel dredging took place in March 2023 at sites 3 and 4.\n",
    "sources/MF-S06.md": "# MF-S06: Water temperature summary 2024\n\nSource ID: MF-S06\n\nMean summer water temperature was 19.8 C.\n",
    "README.md": "# Marlow estuary fish study\n\nCollected source excerpts are in sources/. Each file carries its source ID.\n",
}
MARLOW_ALLOWED = ["MF-S01", "MF-S02", "MF-S03", "MF-S04", "MF-S05", "MF-S06", "MF-S07", "MF-S08", "MF-S09"]
MARLOW_MEMORY = [
    {"id": "mf-baseline", "title": "Bream trend baseline decision", "text": "Decision at the 2026-02 team meeting: the bream trend baseline is the 2024 survey (MF-S02, 1,610 juveniles), not 2022 (MF-S01), because the 2022 crew used a finer net mesh at sites 5-8 (methods note MF-S07)."},
    {"id": "mf-citizen", "title": "Citizen-science counts usage", "text": "Citizen-science counts (MF-S04) run about 3x the seine counts; agreed to use them only as presence records, never for abundance."},
    {"id": "mf-salinity-decline", "title": "Salinity trend 2023-2025", "text": "Salinity declined by 3.8 PSU from 2023 to 2025 (MF-S03).", "retract": "Logger ML-2 calibration drift (MF-S09)."},
    {"id": "mf-salinity-withdrawn", "title": "Salinity trend withdrawn", "text": "Logger ML-2 had a calibration drift (manufacturer notice MF-S09, 2026-01). The MF-S03 salinity decline is withdrawn pending recalibration; do not report a salinity trend."},
    {"id": "mf-mullet-silver", "title": "Mullet in the 2024 survey", "text": "The 2024 survey also recorded 310 silver mullet (MF-S02).", "observed_at": "2024-12-01T00:00:00Z"},
    {"id": "mf-mullet-corrected", "title": "Mullet in the 2024 survey (re-identified)", "text": "Correction: the museum lab (MF-S08) re-identified the 310 mullet in the 2024 survey as yellow-eye mullet; there are no silver mullet records.", "supersedes": "mf-mullet-silver", "observed_at": "2026-02-15T00:00:00Z"},
]
MARLOW_INTENTIONS = [
    {"action": "Before citing any salinity figure, check whether the logger ML-2 recalibration (follow-up to MF-S09) has been published.", "trigger": "keyword:salinity"},
]


def kestrel(task):
    task.update(project_id="proj_kestrel", files=dict(KESTREL_SOURCES), memory=list(KESTREL_MEMORY), intentions=list(KESTREL_INTENTIONS), allowed_citations=KESTREL_ALLOWED)
    return task


def marlow(task):
    task.update(project_id="proj_marlow", files=dict(MARLOW_SOURCES), memory=list(MARLOW_MEMORY), intentions=list(MARLOW_INTENTIONS), allowed_citations=MARLOW_ALLOWED)
    return task


KESTREL_ONLY = ["KB-S09", "KB-S10", "Q-03", "lead time", "11 months", "retract", "erratum"]
MARLOW_ONLY = ["MF-S07", "MF-S08", "MF-S09", "yellow-eye", "calibration", "recalibrat", "mesh"]

TASKS = [
    kestrel({
        "id": "r01-lfp-cold-value",
        "kind": "memory",
        "knowledge": "conflicting-sources",
        "question": "For the Kestrel battery model, what LFP capacity retention at -20 C should we use, and which source supports it?",
        "schema": {"lfp_retention_percent": "number", "answer": "1-3 sentences", "citations": ["source IDs"]},
        "memory_only": KESTREL_ONLY,
        "checks": [
            {"field": "lfp_retention_percent", "equals": 71},
            {"citations_include": ["KB-S01"]},
        ],
        "reference": {"queries": ["LFP cold retention"], "needs": ["71%"],
                      "answer_on": {"lfp_retention_percent": 71, "answer": "Use 71% from the independent lab (KB-S01); the vendor 85% claim (KB-S02) is not adopted.", "citations": ["KB-S01", "KB-S02"]},
                      "answer_off": {"lfp_retention_percent": 85, "answer": "The datasheet gives 85%.", "citations": ["KB-S02"]}},
    }),
    kestrel({
        "id": "r02-sodium-retracted",
        "kind": "memory",
        "knowledge": "retraction",
        "question": "Can we rely on a sodium-ion capacity retention figure at -20 C from our evidence? If so, what is it?",
        "schema": {"reliable_figure_available": "boolean", "figure_percent": "number or null", "answer": "1-3 sentences", "citations": ["source IDs"]},
        "memory_only": KESTREL_ONLY,
        "checks": [
            {"field": "reliable_figure_available", "equals": False},
            {"field": "figure_percent", "is_null": True},
            {"citations_include": ["KB-S09"]},
            {"field": "answer", "regex": "retract"},
        ],
        "reference": {"queries": ["sodium-ion cold retention"], "needs": ["KB-S09"], "must_not_retrieve": ["retain 88%"],
                      "answer_on": {"reliable_figure_available": False, "figure_percent": None, "answer": "No: KB-S04 was retracted (notice KB-S09), so there is no reliable figure.", "citations": ["KB-S04", "KB-S09"]},
                      "answer_off": {"reliable_figure_available": True, "figure_percent": 88, "answer": "Yes, 88% per KB-S04.", "citations": ["KB-S04"]}},
    }),
    kestrel({
        "id": "r03-lto-field-corrected",
        "kind": "memory",
        "knowledge": "correction",
        "question": "How many months did the LTO pilot buoys run in the Kestrel field trial?",
        "schema": {"months": "number", "answer": "1-2 sentences", "citations": ["source IDs"]},
        "memory_only": KESTREL_ONLY,
        "checks": [
            {"field": "months", "equals": 11},
            {"citations_include": ["KB-S10"]},
        ],
        "reference": {"queries": ["LTO pilot field duration months"], "needs": ["KB-S10"], "must_not_retrieve": ["ran 14 months without"],
                      "answer_on": {"months": 11, "answer": "11 months per erratum KB-S10, correcting KB-S03.", "citations": ["KB-S10", "KB-S03"]},
                      "answer_off": {"months": 14, "answer": "14 months.", "citations": ["KB-S03"]}},
    }),
    kestrel({
        "id": "r04-recommendation-brief",
        "kind": "memory",
        "knowledge": "decision+intention",
        "question": "Write a short recommendation brief (at most 120 words) on which battery chemistry to use for the Kestrel deployment.",
        "schema": {"recommendation": "one of LFP, LTO, sodium-ion", "brief": "at most 120 words", "open_questions": ["strings"], "citations": ["source IDs"]},
        "memory_only": KESTREL_ONLY,
        "checks": [
            {"field": "recommendation", "regex": "^\\s*LTO\\s*$"},
            {"field": "open_questions", "regex": "lead[- ]?time|Q-03"},
            {"field": "brief", "not_regex": "14[ -]months|88 ?%"},
        ],
        "reference": {"queries": ["battery chemistry recommendation"], "needs": ["Q-03"],
                      "answer_on": {"recommendation": "LTO", "brief": "Recommend LTO: 89% retention at -20 C (KB-S01) and 11 months in the pilot (KB-S10), at about 3x LFP pack cost (KB-S05).", "open_questions": ["Q-03: LTO supplier lead time unconfirmed"], "citations": ["KB-S01", "KB-S05", "KB-S10"]},
                      "answer_off": {"recommendation": "LTO", "brief": "Recommend LTO: 89% retention (KB-S01) and 14 months in the pilot (KB-S03).", "open_questions": ["Is the cost acceptable?"], "citations": ["KB-S01", "KB-S03"]}},
    }),
    kestrel({
        "id": "r05-excluded-evidence",
        "kind": "memory",
        "knowledge": "retraction+conflict",
        "question": "Audit the Kestrel evidence base: which sources must not be used as support for any figure, and why?",
        "schema": {"excluded_sources": ["source IDs"], "answer": "1-4 sentences", "citations": ["source IDs"]},
        "memory_only": KESTREL_ONLY,
        "checks": [
            {"field": "excluded_sources", "regex": "KB-S04"},
            {"field": "excluded_sources", "not_regex": "KB-S01|KB-S05|KB-S06"},
            {"citations_include": ["KB-S09"]},
        ],
        "reference": {"queries": ["retracted sources not adopted"], "needs": ["KB-S09"],
                      "answer_on": {"excluded_sources": ["KB-S04", "KB-S02"], "answer": "KB-S04 is retracted (KB-S09); the vendor claim KB-S02 is not adopted.", "citations": ["KB-S04", "KB-S09", "KB-S02"]},
                      "answer_off": {"excluded_sources": ["KB-S02"], "answer": "The vendor datasheet has no method.", "citations": ["KB-S02"]}},
    }),
    kestrel({
        "id": "r06-harm-cost-current-source",
        "kind": "harm-control",
        "knowledge": "stale-memory-vs-current-source",
        "question": "According to the 2025 pack cost survey in our sources, what is the LTO pack cost per kWh?",
        "schema": {"lto_usd_per_kwh": "number", "citations": ["source IDs"]},
        "memory_only": [],
        "checks": [
            {"field": "lto_usd_per_kwh", "equals": 410},
            {"citations_include": ["KB-S05"]},
        ],
        "reference": {"queries": ["LTO pack cost"], "needs": [],
                      "answer_on": {"lto_usd_per_kwh": 410, "citations": ["KB-S05"]},
                      "answer_off": {"lto_usd_per_kwh": 410, "citations": ["KB-S05"]}},
    }),
    marlow({
        "id": "r07-bream-baseline",
        "kind": "memory",
        "knowledge": "decision",
        "question": "What is the juvenile bream abundance baseline for trend analysis in the Marlow study (year and count), and why that one?",
        "schema": {"baseline_year": "integer", "baseline_count": "integer", "reason": "1-2 sentences", "citations": ["source IDs"]},
        "memory_only": MARLOW_ONLY,
        "checks": [
            {"field": "baseline_year", "equals": 2024},
            {"field": "baseline_count", "equals": 1610},
            {"citations_include": ["MF-S02"]},
        ],
        "reference": {"queries": ["bream baseline trend"], "needs": ["MF-S07"],
                      "answer_on": {"baseline_year": 2024, "baseline_count": 1610, "reason": "2022 used a finer mesh at sites 5-8 (MF-S07).", "citations": ["MF-S02", "MF-S07"]},
                      "answer_off": {"baseline_year": 2022, "baseline_count": 1240, "reason": "Earliest survey.", "citations": ["MF-S01"]}},
    }),
    marlow({
        "id": "r08-mullet-reidentified",
        "kind": "memory",
        "knowledge": "correction",
        "question": "Which mullet species was recorded in the 2024 seine survey, and how many individuals?",
        "schema": {"species": "common name", "count": "integer", "answer": "1-2 sentences", "citations": ["source IDs"]},
        "memory_only": MARLOW_ONLY,
        "checks": [
            {"field": "species", "regex": "yellow[- ]?eye"},
            {"field": "species", "not_regex": "silver"},
            {"field": "count", "equals": 310},
            {"citations_include": ["MF-S08"]},
        ],
        "reference": {"queries": ["mullet 2024 survey species"], "needs": ["MF-S08"], "must_not_retrieve": ["also recorded 310 silver mullet"],
                      "answer_on": {"species": "yellow-eye mullet", "count": 310, "answer": "310 yellow-eye mullet, re-identified by MF-S08.", "citations": ["MF-S02", "MF-S08"]},
                      "answer_off": {"species": "silver mullet", "count": 310, "answer": "310 silver mullet.", "citations": ["MF-S02"]}},
    }),
    marlow({
        "id": "r09-salinity-withdrawn",
        "kind": "memory",
        "knowledge": "retraction+intention",
        "question": "Has salinity in the estuary declined over 2023-2025? Report the change we can stand behind and any follow-up needed before citing salinity.",
        "schema": {"can_report_trend": "boolean", "change_psu": "number or null", "answer": "1-3 sentences", "open_actions": ["strings"], "citations": ["source IDs"]},
        "memory_only": MARLOW_ONLY,
        "checks": [
            {"field": "can_report_trend", "equals": False},
            {"field": "change_psu", "is_null": True},
            {"citations_include": ["MF-S09"]},
            {"field": "open_actions", "regex": "recalibrat|calibration"},
        ],
        "reference": {"queries": ["salinity trend 2023-2025"], "needs": ["MF-S09"], "must_not_retrieve": ["declined by 3.8 PSU"],
                      "answer_on": {"can_report_trend": False, "change_psu": None, "answer": "No: the MF-S03 decline is withdrawn because of logger drift (MF-S09).", "open_actions": ["Check whether the ML-2 recalibration has been published"], "citations": ["MF-S03", "MF-S09"]},
                      "answer_off": {"can_report_trend": True, "change_psu": -3.8, "answer": "Yes, 31.2 to 27.4 PSU.", "open_actions": [], "citations": ["MF-S03"]}},
    }),
    marlow({
        "id": "r10-trust-brief",
        "kind": "memory",
        "knowledge": "decision+retraction",
        "question": "Write a short brief (at most 120 words) for the estuary trust on juvenile bream status and habitat conditions.",
        "schema": {"brief": "at most 120 words", "key_numbers": {"bream_baseline_2024": "integer"}, "citations": ["source IDs"]},
        "memory_only": MARLOW_ONLY,
        "checks": [
            {"field": "key_numbers.bream_baseline_2024", "equals": 1610},
            {"field": "brief", "not_regex": "3\\.8|27\\.4|silver"},
            {"citations_exclude": ["MF-S03"]},
        ],
        "reference": {"queries": ["bream status habitat"], "needs": ["MF-S09"],
                      "answer_on": {"brief": "Baseline 1,610 juvenile bream (2024, MF-S02). Salinity trend withdrawn pending logger recalibration (MF-S09). Summer water 19.8 C (MF-S06).", "key_numbers": {"bream_baseline_2024": 1610}, "citations": ["MF-S02", "MF-S06", "MF-S09"]},
                      "answer_off": {"brief": "Bream rose from 1,240 to 1,610; salinity fell 3.8 PSU (MF-S03).", "key_numbers": {"bream_baseline_2024": 1610}, "citations": ["MF-S01", "MF-S02", "MF-S03"]}},
    }),
    marlow({
        "id": "r11-citizen-counts",
        "kind": "memory",
        "knowledge": "conflicting-sources",
        "question": "Can the citizen-science counts be used to estimate bream abundance? What are they allowed to be used for?",
        "schema": {"use_for_abundance": "boolean", "allowed_use": "short phrase", "citations": ["source IDs"]},
        "memory_only": MARLOW_ONLY,
        "checks": [
            {"field": "use_for_abundance", "equals": False},
            {"field": "allowed_use", "regex": "presence"},
            {"citations_include": ["MF-S04"]},
        ],
        "reference": {"queries": ["citizen science counts usage"], "needs": ["presence"],
                      "answer_on": {"use_for_abundance": False, "allowed_use": "presence records only", "citations": ["MF-S04"]},
                      "answer_off": {"use_for_abundance": False, "allowed_use": "qualitative context", "citations": ["MF-S04"]}},
    }),
    marlow({
        "id": "r12-control-dredging",
        "kind": "control",
        "knowledge": "none",
        "question": "When and at which sites did channel dredging take place?",
        "schema": {"when": "month and year", "sites": ["integers"], "citations": ["source IDs"]},
        "memory_only": [],
        "checks": [
            {"field": "when", "regex": "March.*2023|2023-03"},
            {"field": "sites", "regex": "3"},
            {"field": "sites", "regex": "4"},
            {"citations_include": ["MF-S05"]},
        ],
        "reference": {"queries": ["dredging"], "needs": [],
                      "answer_on": {"when": "March 2023", "sites": [3, 4], "citations": ["MF-S05"]},
                      "answer_off": {"when": "March 2023", "sites": [3, 4], "citations": ["MF-S05"]}},
    }),
]

for _task in TASKS:
    _task["family"] = "research"
